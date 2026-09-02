#!/bin/bash

# Interactive installer for the Linear bar plugin.
#
# Walks through dependencies, plugin placement, the API key, the issue target,
# panel styling and the keybind, asking for every preference rather than
# assuming one. Everything it writes outside the plugin folder is undone by
# uninstall.sh.
#
# Usage:
#   ./install.sh                                    from a clone
#   bash <(curl -fsSL <raw-url>/install.sh)         without one
#
# Run on its own it clones the plugin from git first, so the script is the only
# file needed. Questions are read from /dev/tty, so `curl … | bash` works too.

set -euo pipefail

readonly REPO_URL="https://github.com/SomeoneWithOptions/linear-omarchy-plugin.git"
readonly PLUGINS_DIR="$HOME/.config/omarchy/plugins"
readonly BINDINGS="$HOME/.config/hypr/bindings.lua"
readonly BIND_BEGIN="-- >>> linear-omarchy-plugin (managed keybind) >>>"
readonly BIND_END="-- <<< linear-omarchy-plugin <<<"
readonly KEYRING_SERVICE="linear-omarchy"
readonly KEYRING_ACCOUNT="api"
readonly TOKEN_FILE=${LINEAR_OMARCHY_TOKEN_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/omarchy/linear/token}

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# No manifest next to the script means it was fetched on its own rather than
# run from a checkout, so the plugin has to come from git.
BOOTSTRAP=1
[[ -f $SRC/manifest.json ]] && BOOTSTRAP=0

PLUGIN_ID=$(jq -r '.id // empty' "$SRC/manifest.json" 2>/dev/null || true)
PLUGIN_ID=${PLUGIN_ID:-andres.linear}
TARGET="$PLUGINS_DIR/$PLUGIN_ID"
SETUP="$TARGET/bin/omarchy-linear-setup"

step_no=0

# ------------------------------------------------------------------- plumbing

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

# gum is part of a stock Omarchy install and gives the prompts the same look as
# the rest of the CLI, but the installer stays usable without it.
have_gum() { command -v gum >/dev/null 2>&1; }

confirm() { # $1 = question, $2 = default (y/n)
  local answer default=${2:-y}
  if have_gum; then
    if [[ $default == y ]]; then
      gum confirm "$1" && return 0 || return 1
    fi
    gum confirm --default=false "$1" && return 0 || return 1
  fi
  read -rp "   $1 [$( [[ $default == y ]] && echo 'Y/n' || echo 'y/N')] " answer </dev/tty
  answer=${answer:-$default}
  [[ ${answer,,} == y* ]]
}

# Reads options on stdin, one per line, and prints the chosen one.
choose() { # $1 = header, $2 = preselected option
  local header=$1 selected=${2-} options=() reply i=1
  mapfile -t options
  if have_gum; then
    # An option can contain spaces, so --selected goes in as its own word
    # rather than through an unquoted expansion.
    local args=(--header="$header")
    [[ -z $selected ]] || args+=(--selected "$selected")
    printf '%s\n' "${options[@]}" | gum choose "${args[@]}"
    return
  fi
  printf '   %s\n' "$header" >&2
  for i in "${!options[@]}"; do
    printf '     %d) %s\n' "$((i + 1))" "${options[i]}" >&2
  done
  read -rp "   Number [1]: " reply </dev/tty
  reply=${reply:-1}
  [[ $reply =~ ^[0-9]+$ && $reply -ge 1 && $reply -le ${#options[@]} ]] ||
    die "Not one of the options: $reply"
  printf '%s\n' "${options[$((reply - 1))]}"
}

ask() { # $1 = prompt, $2 = default value
  local reply
  if have_gum; then
    gum input --header="$1" --value="${2-}"
    return
  fi
  read -rp "   $1 [${2-}]: " reply </dev/tty
  printf '%s\n' "${reply:-${2-}}"
}

# --------------------------------------------------------------- 1. the system

# stdin may well be the script itself (curl | bash), so what matters is that a
# terminal exists to ask the questions on, not that stdin is one.
require_terminal() {
  [[ -r /dev/tty && -w /dev/tty ]] ||
    die "The installer asks questions, so it needs a terminal."
}

check_deps() {
  step "Dependencies"

  local -A packages=(
    [omarchy]=omarchy
    [omarchy-shell]=omarchy
    [jq]=jq
    [curl]=curl
    [lua]=lua
    [git]=git
  )
  local missing=() install=()
  local bin package

  for bin in omarchy omarchy-shell jq curl lua git; do
    command -v "$bin" >/dev/null 2>&1 && continue
    missing+=("$bin")
    package=${packages[$bin]}
    [[ " ${install[*]} " == *" $package "* ]] || install+=("$package")
  done

  if ((${#missing[@]})); then
    warn "Missing: ${missing[*]}"
    [[ " ${missing[*]} " == *" omarchy "* ]] &&
      die "This is an Omarchy plugin and needs Omarchy 4.x. See https://omarchy.org"
    if confirm "Install ${install[*]} with omarchy pkg add?"; then
      omarchy pkg add "${install[@]}" || die "Package install failed"
    else
      die "Cannot continue without: ${missing[*]}"
    fi
  fi

  # The key belongs in the login keyring; a 0600 file is the fallback, not the
  # plan, so say so once here rather than silently degrading later.
  if command -v secret-tool >/dev/null 2>&1; then
    ok "Dependencies present, keyring available"
  else
    warn "secret-tool (libsecret) is missing, so the key would land in $TOKEN_FILE"
    if confirm "Install libsecret for keyring storage?"; then
      omarchy pkg add libsecret || die "Package install failed"
      ok "Keyring available"
    else
      warn "Continuing with the file fallback"
    fi
  fi
}

# ------------------------------------------------------------- 2. plugin files

# Three cases: the installer is already running from the installed plugin, the
# plugin is git-managed (so `omarchy plugin update` keeps working), or the files
# have to be copied out of this checkout.
place_plugin() {
  step "Plugin files"

  if ((BOOTSTRAP)); then
    place_from_git
    return
  fi

  if [[ $SRC == "$TARGET" ]]; then
    ok "Running from $TARGET"
    return
  fi

  local origin=""
  origin=$(git -C "$SRC" remote get-url origin 2>/dev/null || true)

  if [[ -e $TARGET || -L $TARGET ]]; then
    info "$PLUGIN_ID is already installed in $TARGET"
    if confirm "Overwrite it with the files in $SRC?" n; then
      copy_plugin
    else
      ok "Keeping the installed copy"
    fi
    return
  fi

  local method="Copy this checkout into the plugins folder"
  if [[ -n $origin ]]; then
    method=$(choose "How should the plugin be installed?" "Clone from git ($origin)" <<CHOICES
Clone from git ($origin)
Copy this checkout into the plugins folder
CHOICES
)
  fi
  [[ -n $method ]] || die "Cancelled"

  if [[ $method == Clone* ]]; then
    # --yes skips the plugin-add prompts; the placement and enable questions
    # come later so they are asked in one place.
    # A clone can fail for reasons that have nothing to do with the plugin —
    # BatchMode ssh with a passphrase-protected key, no network — and the files
    # are right here, so offer the copy instead of stopping.
    if omarchy plugin add "$origin" --yes; then
      ok "Cloned into $TARGET"
    else
      warn "Could not clone $origin"
      confirm "Copy this checkout instead?" || die "Cancelled"
      copy_plugin
    fi
  else
    copy_plugin
  fi
}

# The script arrived on its own, so the plugin comes from git and stays
# git-managed — which is also what makes `omarchy plugin update` work later.
place_from_git() {
  if [[ -e $TARGET || -L $TARGET ]]; then
    info "$PLUGIN_ID is already installed in $TARGET"
    if confirm "Pull the latest version with omarchy plugin update?"; then
      omarchy plugin update "$PLUGIN_ID" --yes || warn "omarchy plugin update failed"
    else
      ok "Keeping the installed copy"
    fi
    return
  fi

  info "Cloning $REPO_URL"
  omarchy plugin add "$REPO_URL" --yes || die "omarchy plugin add failed"
  ok "Cloned into $TARGET"
}

copy_plugin() {
  local staging="$PLUGINS_DIR/.linear-install.$$"
  mkdir -p "$PLUGINS_DIR"
  rm -rf "$staging"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude .git --exclude .github "$SRC/" "$staging/"
  else
    cp -a "$SRC/" "$staging"
    rm -rf "$staging/.git" "$staging/.github"
  fi

  omarchy plugin validate "$staging" || {
    rm -rf "$staging"
    die "The copied plugin fails omarchy plugin validate"
  }

  if [[ -e $TARGET || -L $TARGET ]]; then
    rm -rf "$TARGET.replaced.$$"
    mv "$TARGET" "$TARGET.replaced.$$"
  fi
  mv "$staging" "$TARGET"
  rm -rf "$TARGET.replaced.$$"

  chmod +x "$TARGET"/bin/* 2>/dev/null || true
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
  ok "Copied into $TARGET"
}

# --------------------------------------------------------------- 3. bar widget

enable_widget() {
  step "Bar placement"

  local default_section section
  default_section=$(jq -r '.barWidget.defaultSection // "right"' "$TARGET/manifest.json")

  section=$(choose "Which bar section should the Linear icon sit in?" "$default_section" <<CHOICES
left
center
right
CHOICES
)
  [[ -n $section ]] || die "Cancelled"

  # The shell has to know the plugin exists before it can be enabled, and a
  # fresh copy is only picked up on the next rescan.
  local attempt
  for ((attempt = 0; attempt < 40; attempt++)); do
    omarchy plugin list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null && break
    sleep 0.05
  done

  omarchy plugin enable "$PLUGIN_ID" --section "$section" || die "Could not enable $PLUGIN_ID"
  ok "Enabled in the $section section"
}

# ------------------------------------------------------------------ 4. api key

store_key() {
  step "Linear API key"

  local existing=""
  if command -v secret-tool >/dev/null 2>&1; then
    existing=$(secret-tool lookup service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" 2>/dev/null || true)
  fi
  [[ -z $existing && -f $TOKEN_FILE ]] && existing="file"

  if [[ -n $existing ]]; then
    ok "A key is already stored"
    confirm "Replace it?" n || return 0
  else
    info "Create a personal API key in Linear: Settings → Security & access →"
    info "API keys, with both read and write scopes. read is required so team"
    info "and project names can be resolved to UUIDs."
  fi

  "$SETUP" key || die "Could not store the key"
}

# ------------------------------------------------------------- 5. issue target

# The team and project lists come from the account itself, so the target is
# picked rather than typed and cannot be a name Linear does not have.
pick_target() {
  step "Issue target"

  local teams team projects project priority
  info "Reading your teams from Linear…"
  teams=$("$SETUP" list --json) || die "Could not list teams; check the API key"
  [[ $(jq 'length' <<<"$teams") -gt 0 ]] || die "This account has no teams"

  team=$(jq -r '.[].name' <<<"$teams" | choose "Which team files the issues?")
  [[ -n $team ]] || die "Cancelled"

  projects=$(jq -r --arg team "$team" '.[] | select(.name == $team) | .projects.nodes[].name' <<<"$teams")
  [[ -n $projects ]] ||
    die "Team \"$team\" has no projects. Create one in Linear, then rerun the installer."

  project=$(printf '%s\n' "$projects" | choose "Which project in $team?")
  [[ -n $project ]] || die "Cancelled"

  priority=$(choose "Default priority for new issues?" "Leave unset (Linear's default)" <<CHOICES
Leave unset (Linear's default)
No priority
Urgent
High
Normal
Low
CHOICES
)
  [[ -n $priority ]] || die "Cancelled"

  local args=(use "$team" "$project")
  case $priority in
  "No priority") args+=(--priority 0) ;;
  Urgent) args+=(--priority 1) ;;
  High) args+=(--priority 2) ;;
  Normal) args+=(--priority 3) ;;
  Low) args+=(--priority 4) ;;
  esac

  "$SETUP" "${args[@]}" || die "Could not write the config"
  ok "Target: $team › $project"
}

# ---------------------------------------------------------------- 6. the panel

configure_panel() {
  step "Panel style"

  local position frame
  position=$(choose "Which screen corner should the capture field open in?" \
    "$(jq -r '.barWidget.defaults.panelPosition // "top-left"' "$TARGET/manifest.json")" <<CHOICES
top-left
top-right
bottom-left
bottom-right
CHOICES
)
  [[ -n $position ]] || die "Cancelled"

  info "Frame styling grows the panel out of the desktop frame: no borders on the"
  info "edges it is attached to, and concave fillets where it leaves the frame."
  info "It needs a top bar; off gives a plain bordered card instead."
  if confirm "Use frame styling?"; then frame=true; else frame=false; fi

  omarchy bar set "$PLUGIN_ID" panelPosition "$position" || die "Could not set panelPosition"
  # --json so the value lands as a real boolean rather than the string "false".
  omarchy bar set "$PLUGIN_ID" frameStyle "$frame" --json || die "Could not set frameStyle"
  ok "Panel opens $position, frame styling $frame"
}

# ------------------------------------------------------------------ 7. keybind

configure_keybind() {
  step "Keybind"

  local chord conflict existing=""

  if [[ -f $BINDINGS ]] && grep -qF -- "$BIND_BEGIN" "$BINDINGS"; then
    existing=$(awk -v begin="$BIND_BEGIN" -v end="$BIND_END" '
      $0 == begin { inside = 1; next }
      $0 == end { inside = 0 }
      inside
    ' "$BINDINGS" | grep -o 'o.bind("[^"]*"' | head -1 | cut -d'"' -f2)
    ok "Managed keybind already present${existing:+: $existing}"
    confirm "Change it?" n || return 0
  elif [[ -f $BINDINGS ]] && grep -qF -- "$PLUGIN_ID" "$BINDINGS"; then
    warn "bindings.lua already mentions $PLUGIN_ID outside the managed block:"
    grep -nF -- "$PLUGIN_ID" "$BINDINGS" | sed 's/^/     /'
    confirm "Add a managed keybind anyway?" n || return 0
  else
    confirm "Add a keybind that opens the capture field?" || {
      info "Skipped. The bar icon still opens it."
      return 0
    }
  fi

  chord=$(ask "Key combination" "SUPER + SHIFT + L")
  chord=$(printf '%s' "$chord" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [[ -n $chord ]] || die "No key combination given"

  # Hyprland takes the last binding for a chord, so an existing one still
  # works — it just stops doing what the user expects. Say what it was.
  conflict=$(omarchy menu keybindings --print 2>/dev/null |
    awk -F'→' -v chord="$(printf '%s' "$chord" | tr -d ' +' | tr '[:lower:]' '[:upper:]')" '
      { key = $1; gsub(/[ \t+]/, "", key); if (toupper(key) == chord) print $2 }' |
    sed 's/^[[:space:]]*//' | head -1)
  # A conflict that is only the managed block being replaced is not one.
  [[ -n $existing && $existing == "$chord" ]] && conflict=""

  if [[ -n $conflict ]]; then
    warn "$chord is already bound to: $conflict"
    confirm "Override it?" n || {
      info "Skipped the keybind."
      return 0
    }
  fi

  mkdir -p "$(dirname "$BINDINGS")"
  [[ -f $BINDINGS ]] || printf -- '-- Personal bindings layered over Omarchy defaults.\n' >"$BINDINGS"
  cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"

  remove_managed_block

  # printf rather than a heredoc: the Lua needs its double quotes, and a
  # conditional line inside a heredoc loses them.
  {
    printf '\n%s\n' "$BIND_BEGIN"
    [[ -z $conflict ]] || printf 'hl.unbind("%s")\n' "$chord"
    printf 'o.bind("%s", "New Linear issue", "omarchy-shell %s toggle")\n' "$chord" "$PLUGIN_ID"
    printf '%s\n' "$BIND_END"
  } >>"$BINDINGS"

  hyprctl reload >/dev/null 2>&1 || warn "hyprctl reload failed; is Hyprland running?"
  local errors
  errors=$(hyprctl configerrors 2>/dev/null || true)
  if [[ -n $errors && $errors != *"no errors"* ]]; then
    warn "Hyprland reported config errors:"
    printf '%s\n' "$errors" | sed 's/^/     /'
  else
    ok "$chord opens the capture field (backup: $BINDINGS.bak.*)"
  fi
}

remove_managed_block() {
  [[ -f $BINDINGS ]] || return 0
  grep -qF -- "$BIND_BEGIN" "$BINDINGS" || return 0
  # Also swallows the blank line the block was appended after, so repeated
  # install/uninstall cycles do not stack up empty lines.
  awk -v begin="$BIND_BEGIN" -v end="$BIND_END" '
    $0 == begin { skip = 1; held = 0; next }
    $0 == end { skip = 0; next }
    skip { next }
    /^[[:space:]]*$/ { if (held) print blank; blank = $0; held = 1; next }
    { if (held) { print blank; held = 0 } print }
    END { if (held) print blank }
  ' "$BINDINGS" >"$BINDINGS.tmp"
  mv "$BINDINGS.tmp" "$BINDINGS"
}

# ------------------------------------------------------------------ 8. wrap up

restart_shell() {
  step "Restarting the shell"
  # A changed QML component is not reliably hot-reloaded, so a restart is the
  # only way to be sure the widget the user just configured is the one running.
  omarchy restart shell >/dev/null 2>&1 || warn "omarchy restart shell failed"
  ok "Shell restarted"
}

verify() {
  step "Verifying"
  local account target
  if account=$("$SETUP" check 2>&1); then
    ok "$account"
  else
    warn "$account"
  fi
  if target=$("$TARGET/bin/omarchy-linear-issue-create" --target 2>&1); then
    ok "Filing into $target"
  else
    warn "$target"
  fi
}

summary() {
  printf '\n\033[1mDone.\033[0m Click the Linear icon in the bar to file an issue.\n'
  printf 'Change the target later with: %s use "Team" "Project"\n' "$SETUP"
  local uninstaller="$SRC/uninstall.sh"
  ((BOOTSTRAP)) && uninstaller="$TARGET/uninstall.sh"
  printf 'Remove everything, key included, with: %s\n\n' "$uninstaller"
}

# ---------------------------------------------------------------------- driver

case ${1-} in
-h | --help)
  sed -n '3,15p' "$0" | sed 's/^# \?//'
  exit 0
  ;;
"") ;;
*) die "Unknown option: $1" ;;
esac

printf '\n\033[1mLinear for the Omarchy bar\033[0m\n'
printf 'Nothing is written until each question is answered.\n'

require_terminal
check_deps
place_plugin
[[ -x $SETUP ]] || die "Missing $SETUP after install"
enable_widget
store_key
pick_target
configure_panel
configure_keybind
restart_shell
verify
summary
