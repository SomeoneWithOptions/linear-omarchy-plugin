-- Linear bar plugin configuration.
-- Copy to ~/.config/omarchy/linear/config.lua, or generate it with:
--   omarchy-linear-setup use "Personal" "Work"
--
-- Names are the source of truth. The plugin caches the matching UUIDs under
-- ~/.local/state/omarchy/linear/ids.json and re-resolves them whenever a name
-- here changes, so renaming a project in Linear can't leave a stale target.
return {
  team = "Personal",
  project = "Work",

  -- Pin the UUIDs to skip name resolution entirely (one less API call):
  -- team_id = "…",
  -- project_id = "…",

  -- Default priority for new issues: 0 none, 1 urgent, 2 high, 3 normal, 4 low.
  -- priority = 3,
}
