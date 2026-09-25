# linear-omarchy-plugin

Create Linear issues from the [Omarchy](https://omarchy.org) bar. Click the icon
(or hit `SUPER+SHIFT+L`), type a title, press Enter. A notification reports the
issue identifier; clicking it opens the ticket.

Requires Omarchy 4.x (the `omarchy-shell` Quickshell bar), plus `lua`, `curl`,
and `jq`.

## Install

One command, no clone — the installer fetches the plugin itself:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SomeoneWithOptions/linear-omarchy-plugin/main/install.sh)
```

`curl … | bash` works as well; the questions are read from `/dev/tty` rather
than stdin, so a piped script does not eat the answers. Read it before you run
it, as with any installer that comes down a pipe.

From a clone instead, which is the same script:

```bash
git clone https://github.com/SomeoneWithOptions/linear-omarchy-plugin.git
cd linear-omarchy-plugin
./install.sh
```

The difference is only where the plugin files come from. Run on its own the
script clones the repo through `omarchy plugin add`, so the install stays
git-managed and `omarchy plugin update andres.linear` keeps working. Run from a
clone it offers that same clone or a copy of your working tree — take the copy
when you are developing against it.

The installer asks for every preference rather than assuming one: bar section,
whether to link the commands into `~/.local/bin`, API key, which team and
project to file into, the default priority and assignee, the panel corner,
frame styling, and the keybind. Teams and projects are read from your own
Linear account and picked from a list, so the target cannot be a name Linear
does not have. Changes are applied step by step, so cancelling preserves
completed steps and a rerun continues from that state. It backs up
`bindings.lua` before touching it, then restarts the shell and verifies the key
and target.

`omarchy-linear-setup` and `omarchy-linear-issue-create` are symlinked into
`~/.local/bin`, so they follow `omarchy plugin update` without relinking. A file
already there under either name is left alone. If `~/.local/bin` is not on your
`PATH` the installer says so and prints the line to add; it does not edit your
shell's rc files. The bar itself still calls the helper by its plugin path.

It is safe to run again. Every step reads what is already on the machine — the
bar entry in `shell.json`, the key in the keyring, the config, the managed
block in `bindings.lua` — reports it and asks only about what is missing.
Answers that are already settled are left alone unless you say otherwise, so a
rerun neither reshuffles your bar nor spends an API call re-resolving a target
that has not changed. Nothing is rewritten when the new content would be
identical, and the shell is only restarted when something actually changed.

```bash
./install.sh --reconfigure    # ask about the settled steps again
./install.sh --yes            # unattended defaults; repair incomplete plugin files
```

Unattended curl install, suitable for a dotfiles bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/SomeoneWithOptions/linear-omarchy-plugin/main/install.sh | bash -s -- --yes
```

`--yes` never reads from the terminal. It takes safe defaults, leaves completed
choices alone, and repairs an incomplete plugin copy. It will not invent a
Linear API key or choose a team/project from an account-specific list. Missing
account setup is reported and skipped; finish it later with
`omarchy-linear-setup key` and
`omarchy-linear-setup use --team "Team" --project "Project"`.
Use `--reconfigure` to change an answer you have already given.

### By hand

```bash
omarchy plugin add https://github.com/SomeoneWithOptions/linear-omarchy-plugin.git
omarchy plugin enable andres.linear --section right

mkdir -p ~/.local/bin
ln -s ~/.config/omarchy/plugins/andres.linear/bin/omarchy-linear-setup ~/.local/bin/
ln -s ~/.config/omarchy/plugins/andres.linear/bin/omarchy-linear-issue-create ~/.local/bin/

omarchy-linear-setup key
omarchy-linear-setup list
omarchy-linear-setup use --team "Personal" --project "Work" --priority 3
```

Add the keybind to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + L", "New Linear issue", "omarchy-shell andres.linear toggle")
```

## Uninstall

```bash
~/.config/omarchy/plugins/andres.linear/uninstall.sh          # ask before each removal
~/.config/omarchy/plugins/andres.linear/uninstall.sh --yes    # remove everything without asking
```

Or over curl, which needs no local copy either:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SomeoneWithOptions/linear-omarchy-plugin/main/uninstall.sh)
```

This takes the whole footprint off the machine: the plugin folder, the command
links in `~/.local/bin` (only links that point into the plugin folder), the bar
entry and its widget settings in `shell.json`, the managed keybind block, the
config and its backups, the resolved-id cache, and the API key from both the
login keyring and the file fallback. A key file is overwritten with `shred`
before it is unlinked. Any file it edits is backed up next to itself first.

A keybind you added by hand is quoted back to you and only removed on a yes.

## API key

Create a **personal API key** in Linear under Settings → Security & access → API
keys, with both `read` and `write` scopes. `read` is required: the plugin
resolves your team and project names to UUIDs, which Linear only exposes over
the API.

The key is stored in the login keyring, which is unlocked by PAM at login and
encrypted at rest:

```bash
secret-tool store --label='Linear API key' service linear-omarchy account api
```

If you have no keyring (headless, for instance), setup stores the key in
`~/.local/share/omarchy/linear/token` with mode `600`. The helper accepts only
mode `600` or `400`, so loosened permissions fail loudly instead of silently
downgrading security.

An environment variable is deliberately not supported. Hyprland's session
environment is inherited by every child process — every terminal, your browser,
the shell itself — and any process running as you can read it out of
`/proc/<pid>/environ`. It also leaks into crash dumps and `env` output. The
helper reads the key at call time only, and passes it to `curl` over stdin as a
config file so it never appears in the process table either.

## Configuration

`~/.config/omarchy/linear/config.lua`:

```lua
return {
  team = "Personal",
  project = "Work",

  -- Optional: pin UUIDs to skip name resolution.
  -- team_id = "…",
  -- project_id = "…",

  -- Optional default priority: 0 none, 1 urgent, 2 high, 3 normal, 4 low.
  -- priority = 3,

  -- Optional assignee: "me" (the API key's user) or a user's email.
  -- assignee = "me",
  -- assignee_id = "…",
}
```

Linear's API only accepts an assignee as a user UUID. The plugin resolves
`"me"` to the key's own user and anything else by email — the one user field
Linear keeps unique; display names are not — and caches the UUID alongside the
team and project. Set it with `omarchy-linear-setup use --team "Team"
--project "Project" --assignee me` (or `--assignee someone@example.com`).

Names are the source of truth. Resolved UUIDs are cached in
`~/.local/state/omarchy/linear/ids.json`, keyed by those names, so renaming a
project in Linear re-resolves rather than filing into the wrong place.

Bar placement and section live in `~/.config/omarchy/shell.json`, which is the
shell's own schema — `omarchy bar move andres.linear --section right --index 5`.

## Panel styling

The panel opens in a screen corner rather than under its bar icon, so the capture
field is in the same place whatever the bar layout is. It sits in the top-left
corner by default; pick another with `panelPosition`:

```bash
omarchy bar set andres.linear panelPosition bottom-right
```

Valid values are `top-left`, `top-right`, `bottom-left` and `bottom-right`.
Anything else falls back to `top-left`.

By default the panel grows out of the desktop frame: it drops the borders on the
edges it is attached to, squares off those corners, and draws concave fillets
where it leaves the frame. The decorations mirror with the position — a top
panel overlaps the bar and grows down out of the strip, a bottom one sits flush
on the screen's bottom edge and grows up out of the corner nook, and both bridge
to whichever side edge they are pinned against. For a plain bordered card with
every corner rounded instead:

```bash
omarchy bar set andres.linear frameStyle false
```

The frame look needs a top bar; with the bar on another edge the panel falls
back to the plain card. Note that `omarchy bar set` writes values into
`shell.json` as strings, so the widget reads `"false"` as false as well as a
real `false`.

## Hacking

Plugin QML is loaded from `~/.config/omarchy/plugins/andres.linear/`, so develop
against a copy there and sync your checkout into it:

```bash
rsync -a --delete --exclude .git --exclude README.md ./ ~/.config/omarchy/plugins/andres.linear/
omarchy restart shell
```

Two things cost time if you don't know them:

- **Don't symlink the plugin directory to your checkout.** The shell discovers
  it and `omarchy plugin validate` rejects it, but edits behind the symlink never
  reach the shell — the widget silently renders nothing.
- The shell logs `Local plugin changed, reloading` when files change, but a
  changed QML component is not always picked up. `omarchy restart shell` is the
  reliable way to see an edit.

## Layout

| Path | Role |
|------|------|
| `manifest.json` | Plugin manifest (`kind: bar-widget`) |
| `Panel.qml` | Bar button and the popup: one title field, Enter creates, Esc cancels |
| `LinearIcon.qml` | The Linear mark, drawn from primitives so it stays crisp at any font scale |
| `FramePanel.qml` | Popup surface, pinned to a screen corner |
| `FrameJoin.qml` | The concave fillet where the panel meets the frame and the screen edge |
| `bin/omarchy-linear-issue-create` | Reads config and key, calls the API, sends the notification |
| `bin/omarchy-linear-setup` | Stores the key, lists teams and projects, writes `config.lua` |
| `install.sh` | Interactive setup: deps, placement, key, target, panel, keybind. Rerunnable |
| `uninstall.sh` | Removes the plugin, its config, its keybind and the stored key |

`Panel.qml` never touches the network. It hands the title to
`omarchy-linear-issue-create` detached, so the popup closes on the keystroke and
the shell never blocks on the Linear API. That helper owns both the success and
the failure notification, which is also why it works standalone:

```bash
omarchy-linear-issue-create "Fix the login redirect"
```

## License

MIT
