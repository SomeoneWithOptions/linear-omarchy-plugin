#!/bin/bash

# Removes the Linear bar plugin and everything it put on this machine: the
# plugin folder, the bar entry and its settings, the keybind, the config, the
# resolved-id cache and the API key in both the keyring and the file fallback.
#
# Usage:
#   ./uninstall.sh          ask before each removal
#   ./uninstall.sh --yes    remove everything without asking

set -euo pipefail

readonly PLUGINS_DIR="$HOME/.config/omarchy/plugins"
readonly SHELL_CONFIG="$HOME/.config/omarchy/shell.json"
readonly BINDINGS="$HOME/.config/hypr/bindings.lua"
readonly BIND_BEGIN="-- >>> linear-omarchy-plugin (managed keybind) >>>"
readonly BIND_END="-- <<< linear-omarchy-plugin <<<"
readonly KEYRING_SERVICE="linear-omarchy"
readonly KEYRING_ACCOUNT="api"

readonly CONFIG_DIR="$HOME/.config/omarchy/linear"
readonly STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/linear
readonly TOKEN_FILE=${LINEAR_OMARCHY_TOKEN_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/omarchy/linear/token}
readonly DATA_DIR=$(dirname "$TOKEN_FILE")

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The id survives the relocation below, where the manifest is no longer next to
# the script.
PLUGIN_ID=${LINEAR_UNINSTALL_ID:-$(jq -r '.id // empty' "$SRC/manifest.json" 2>/dev/null || true)}
PLUGIN_ID=${PLUGIN_ID:-andres.linear}
TARGET="$PLUGINS_DIR/$PLUGIN_ID"
ASSUME_YES=0
step_no=0

die() {
  printf '\n\033[31m✗\033[0m %s\n' "$1" >&2
  exit 1
}

step() {
  step_no=$((step_no + 1))
  printf '\n\033[1m%d. %s\033[0m\n' "$step_no" "$1"
}

info() { printf '   %s\n' "$1"; }
ok() { printf '   \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$1"; }
skipped() { printf '   \033[2m·\033[0m %s\n' "$1"; }

confirm() { # $1 = question, $2 = default (y/n)
  local answer default=${2:-y}
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || die "Not a terminal and no --yes; refusing to guess"
  if command -v gum >/dev/null 2>&1; then
    if [[ $default == y ]]; then
      gum confirm "$1" && return 0 || return 1
    fi
    gum confirm --default=false "$1" && return 0 || return 1
  fi
  read -rp "   $1 [$( [[ $default == y ]] && echo 'Y/n' || echo 'y/N')] " answer </dev/tty
  answer=${answer:-$default}
  [[ ${answer,,} == y* ]]
}

# ------------------------------------------------------------------- keybind

remove_keybind() {
  step "Keybind"

  if [[ ! -f $BINDINGS ]]; then
    skipped "No $BINDINGS"
    return
  fi

  local touched=0 block_left=0 hand_written=""

  if grep -qF -- "$BIND_BEGIN" "$BINDINGS"; then
    if confirm "Remove the managed keybind block from bindings.lua?"; then
      cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
      # Swallows the blank line the block was appended after too, so an
      # install/uninstall cycle leaves bindings.lua as it found it.
      awk -v begin="$BIND_BEGIN" -v end="$BIND_END" '
        $0 == begin { skip = 1; held = 0; next }
        $0 == end { skip = 0; next }
        skip { next }
        /^[[:space:]]*$/ { if (held) print blank; blank = $0; held = 1; next }
        { if (held) { print blank; held = 0 } print }
        END { if (held) print blank }
      ' "$BINDINGS" >"$BINDINGS.tmp"
      mv "$BINDINGS.tmp" "$BINDINGS"
      ok "Managed block removed (backup: $BINDINGS.bak.*)"
      touched=1
    else
      skipped "Left the managed block in place"
      block_left=1
    fi
  fi

  # A binding added by hand is the user's own text, so name the lines and only
  # touch them on a yes. Skipped while the managed block is still in the file,
  # because its own o.bind line would match too.
  if ((block_left == 0)); then
    hand_written=$(grep -nF -- "$PLUGIN_ID" "$BINDINGS" || true)
  fi

  if [[ -n $hand_written ]]; then
    warn "bindings.lua still mentions $PLUGIN_ID:"
    printf '%s\n' "$hand_written" | sed 's/^/     /'
    if confirm "Delete those lines?" n; then
      cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
      grep -vF -- "$PLUGIN_ID" "$BINDINGS" >"$BINDINGS.tmp"
      mv "$BINDINGS.tmp" "$BINDINGS"
      ok "Lines deleted; any comment above them is left for you to read"
      touched=1
    else
      skipped "Left them in place"
    fi
  fi

  if ((touched)); then
    hyprctl reload >/dev/null 2>&1 || warn "hyprctl reload failed; is Hyprland running?"
    local errors
    errors=$(hyprctl configerrors 2>/dev/null || true)
    if [[ -n $errors && $errors != *"no errors"* ]]; then
      warn "Hyprland reported config errors:"
      printf '%s\n' "$errors" | sed 's/^/     /'
    fi
  elif ((block_left == 0)); then
    skipped "No keybind to remove"
  fi
}

# -------------------------------------------------------------------- plugin

# `omarchy plugin remove` drops the bar entry (settings included) and deletes
# the folder. It only works while the plugin is still installed, so the direct
# shell.json prune below is the fallback for a half-removed install.
remove_plugin() {
  step "Plugin"

  if [[ -e $TARGET || -L $TARGET ]]; then
    if confirm "Remove the plugin from $TARGET?"; then
      omarchy plugin remove "$PLUGIN_ID" --yes || warn "omarchy plugin remove failed"
      ok "Plugin removed"
    else
      skipped "Plugin left installed"
      return
    fi
  else
    skipped "Nothing installed at $TARGET"
  fi

  # A folder that was copied rather than cloned is moved aside, not deleted.
  local backups=()
  mapfile -t backups < <(find "$PLUGINS_DIR" -maxdepth 1 -name ".${PLUGIN_ID}.bak.*" 2>/dev/null || true)
  if ((${#backups[@]})); then
    info "Backup folders left by omarchy plugin remove:"
    printf '     %s\n' "${backups[@]}"
    if confirm "Delete them too?"; then
      rm -rf "${backups[@]}"
      ok "Backups deleted"
    else
      skipped "Backups kept"
    fi
  fi
}

prune_shell_config() {
  step "Bar entry"

  if [[ ! -f $SHELL_CONFIG ]]; then
    skipped "No $SHELL_CONFIG"
    return
  fi

  if ! grep -qF -- "\"$PLUGIN_ID\"" "$SHELL_CONFIG"; then
    ok "shell.json no longer mentions $PLUGIN_ID"
    return
  fi

  warn "shell.json still carries an entry for $PLUGIN_ID"
  confirm "Strip it out?" || {
    skipped "Entry kept"
    return
  }

  cp "$SHELL_CONFIG" "$SHELL_CONFIG.bak.$(date +%s)"
  jq --arg id "$PLUGIN_ID" '
    (.bar.layout // {}) |= with_entries(.value |= map(select((.id // "") != $id)))
    | (if has("plugins") then .plugins |= map(select((.id // "") != $id)) else . end)
    | (if has("disabledPlugins") then .disabledPlugins |= map(select(. != $id)) else . end)
    | (if has("cloneSourceRestores") then .cloneSourceRestores |= map(select(. != $id)) else . end)
  ' "$SHELL_CONFIG" >"$SHELL_CONFIG.tmp" || {
    rm -f "$SHELL_CONFIG.tmp"
    die "Could not rewrite $SHELL_CONFIG"
  }
  mv "$SHELL_CONFIG.tmp" "$SHELL_CONFIG"
  ok "Bar entry and widget settings removed (backup: $SHELL_CONFIG.bak.*)"
}

# ------------------------------------------------------------ config and key

remove_config() {
  step "Config and cache"

  local paths=()
  [[ -d $CONFIG_DIR ]] && paths+=("$CONFIG_DIR")
  [[ -d $STATE_DIR ]] && paths+=("$STATE_DIR")

  if ((${#paths[@]} == 0)); then
    skipped "Nothing to remove"
    return
  fi

  printf '     %s\n' "${paths[@]}"
  if confirm "Delete the config, its backups and the resolved-id cache?"; then
    rm -rf "${paths[@]}"
    ok "Removed"
  else
    skipped "Kept"
  fi
}

# The key is the one thing here that is a secret, so it goes from both places it
# can live, and the file is overwritten before it is unlinked.
remove_key() {
  step "API key"

  local removed=0

  if command -v secret-tool >/dev/null 2>&1; then
    if secret-tool lookup service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" >/dev/null 2>&1; then
      if confirm "Delete the Linear API key from the login keyring?"; then
        secret-tool clear service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" ||
          warn "secret-tool clear failed; delete it by hand in Seahorse"
        ok "Keyring entry cleared"
        removed=1
      else
        skipped "Keyring entry kept"
      fi
    fi
  fi

  if [[ -f $TOKEN_FILE ]]; then
    if confirm "Delete the key file at $TOKEN_FILE?"; then
      command -v shred >/dev/null 2>&1 && shred -u "$TOKEN_FILE" 2>/dev/null || rm -f "$TOKEN_FILE"
      ok "Key file deleted"
      removed=1
    else
      skipped "Key file kept"
    fi
  fi

  # Only prune the parent when this plugin is the sole tenant.
  if [[ -d $DATA_DIR ]] && [[ -z $(ls -A "$DATA_DIR") ]]; then
    rmdir "$DATA_DIR" 2>/dev/null || true
  fi

  ((removed)) || skipped "No stored key found"
}

restart_shell() {
  step "Restarting the shell"
  omarchy restart shell >/dev/null 2>&1 || warn "omarchy restart shell failed"
  ok "Shell restarted"
}

# ---------------------------------------------------------------------- driver

case ${1-} in
-h | --help)
  sed -n '3,9p' "$0" | sed 's/^# \?//'
  exit 0
  ;;
--yes | -y) ASSUME_YES=1 ;;
"") ;;
*) die "Unknown option: $1" ;;
esac

# The script may be sitting inside the folder it is about to delete, and bash
# reads a script in chunks as it runs, so run from a copy in that case.
if [[ ${LINEAR_UNINSTALL_RELOCATED-} != 1 && $SRC == "$TARGET" ]]; then
  relocated=$(mktemp -t omarchy-linear-uninstall.XXXXXX.sh)
  cat "$SRC/$(basename -- "${BASH_SOURCE[0]}")" >"$relocated"
  chmod +x "$relocated"
  LINEAR_UNINSTALL_RELOCATED=1 LINEAR_UNINSTALL_ID="$PLUGIN_ID" exec "$relocated" "$@"
fi

# The copy has been read in full by the time the shell exits, so it can clean
# itself up then.
if [[ ${LINEAR_UNINSTALL_RELOCATED-} == 1 ]]; then
  trap 'rm -f -- "${BASH_SOURCE[0]}"' EXIT
fi

# The working directory may be inside the folder about to be deleted, and every
# path from here on is absolute.
cd /

printf '\n\033[1mRemoving Linear from the Omarchy bar\033[0m\n'
info "Plugin:   $TARGET"
info "Config:   $CONFIG_DIR"
info "Cache:    $STATE_DIR"
info "Key:      login keyring ($KEYRING_SERVICE/$KEYRING_ACCOUNT), $TOKEN_FILE"
info "Keybind:  $BINDINGS"

if ((ASSUME_YES == 0)); then
  confirm "Remove all of it?" || die "Nothing was changed"
fi

remove_keybind
remove_plugin
prune_shell_config
remove_config
remove_key
restart_shell

printf '\n\033[1mDone.\033[0m Backups of any file that was edited sit next to it as *.bak.*\n\n'
