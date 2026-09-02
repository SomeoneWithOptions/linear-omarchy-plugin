# linear-omarchy-plugin

Create Linear issues from the [Omarchy](https://omarchy.org) bar. Click the icon
(or hit `SUPER+SHIFT+L`), type a title, press Enter. A notification reports the
issue identifier; clicking it opens the ticket.

Requires Omarchy 4.x (the `omarchy-shell` Quickshell bar), plus `lua`, `curl`,
and `jq`.

## Install

```bash
omarchy plugin add https://github.com/SomeoneWithOptions/linear-omarchy-plugin.git
omarchy plugin enable andres.linear --section right
```

Then store the API key and pick a target:

```bash
~/.config/omarchy/plugins/andres.linear/bin/omarchy-linear-setup key
~/.config/omarchy/plugins/andres.linear/bin/omarchy-linear-setup list
~/.config/omarchy/plugins/andres.linear/bin/omarchy-linear-setup use "Personal" "Work"
```

Add the keybind to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + L", "New Linear issue", "omarchy-shell andres.linear toggle")
```

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

If you have no keyring (headless, for instance), the plugin falls back to
`~/.local/share/omarchy/linear/token`. That file **must** be mode `600` or `400`
— the helper refuses to read it otherwise, so a loosened mode fails loudly
instead of silently downgrading your security.

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
}
```

Names are the source of truth. Resolved UUIDs are cached in
`~/.local/state/omarchy/linear/ids.json`, keyed by those names, so renaming a
project in Linear re-resolves rather than filing into the wrong place.

Bar placement and section live in `~/.config/omarchy/shell.json`, which is the
shell's own schema — `omarchy bar move andres.linear --section right --index 5`.

## Layout

| Path | Role |
|------|------|
| `manifest.json` | Plugin manifest (`kind: bar-widget`) |
| `Panel.qml` | Bar button and the popup: one title field, Enter creates, Esc cancels |
| `LinearIcon.qml` | The Linear mark, drawn from primitives so it stays crisp at any font scale |
| `bin/omarchy-linear-issue-create` | Reads config and key, calls the API, sends the notification |
| `bin/omarchy-linear-setup` | Stores the key, lists teams and projects, writes `config.lua` |

`Panel.qml` never touches the network. It hands the title to
`omarchy-linear-issue-create` detached, so the popup closes on the keystroke and
the shell never blocks on the Linear API. That helper owns both the success and
the failure notification, which is also why it works standalone:

```bash
bin/omarchy-linear-issue-create "Fix the login redirect"
```

## License

MIT
