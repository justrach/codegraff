# Plugin management

`graff plugins` and `/plugins` in the REPL or ACP share the same commands:

- `list`: show enabled foreign bundles and configured disabled IDs.
- `load <name-or-id>`: inspect a discovered bundle without executing hooks.
- `disable <id>` / `enable <id>`: opt a plugin out or back in. Foreign IDs are
  `origin/name` (for example `claude/reviewer`); registered directories use
  `registered/name`. Native runtime plugins use their explicit runtime ID.
- `register <directory>` or `install <directory>`: register an existing local
  directory in place. The canonical path is recorded; no package manager,
  network install, file copy, secret copy, or executable launch occurs.
- `remove <directory>` or `unregister <directory>`: forget a registration,
  without deleting its directory. An absolute recorded path can be removed
  even after the source directory has disappeared.
- `reload`: queue discovery invalidation for the next safe user/catalog boundary.

Paths with spaces are accepted as the remainder of the slash command, or as
quoted CLI arguments. Unknown commands print usage instead of silently listing.

## Workspace settings

Management is workspace-local, in the trusted harness-owned
`.harness/settings.json`:

```json
{
  "plugins": {
    "disabled": ["claude/reviewer", "my-native-plugin"],
    "directories": ["/absolute/local/bundle"]
  }
}
```

Updates atomically replace the settings document with private permissions and
preserve unrelated fields, including `plugins` extension fields and native
`runtime_plugins` declarations. Malformed management configuration fails closed;
commands do not repair or replace invalid configuration implicitly. Registration
and disabling in one workspace do not affect another. A settings path escaping
the workspace through a symlink is rejected.

These are explicit user commands, not model tools. The existing harness policy
file write protection remains mandatory: a model cannot enable itself, register
code, grant runtime trust, or widen policy by writing settings. Enabling a plugin
never overrides a configured `plugin.use` deny. Foreign discovery checks both the
manifest name and its `origin/name` ID; a denied bundle contributes no skills,
agents, commands, or MCP definitions.

## Foreign bundles versus native runtime plugins

ADR 0007 still applies. Imported Claude/Cursor/Codex/Grok manifests are read in
place for supported metadata. Their hooks are **never executed**; their `bin/`
directories are never added to PATH. Registration alone is not native runtime
opt-in. A native runtime needs a separate explicit `runtime_plugins` declaration
with its own ID, command, event allowlist, and `trusted: true`. Management's
disabled IDs apply to that ID too, without changing or granting its trust.
Native subprocess events and UI/action JSON belong to the native extension
runtime, not the foreign package importer.

## Frontend boundary API

`plugin_management.load(io, arena, project)` returns a workspace `State` with
`disabled`, `directories`, and `enabled(id)`. Runtime consumers must consult
`State.enabled(runtime_plugin.id)` in addition to runtime trust and hard policy.
`isEnabled(io, arena, id)` provides a current-workspace boolean convenience;
`isEnabledAt(io, arena, project, id)` takes an explicit workspace. Both return
false on management configuration errors.
The explicit mutation functions are `setEnabled`, `register`, and `remove`.

Mutations and `requestReload()` only mark a pending refresh. At a safe user-turn
or explicit catalog boundary, the shared frontend calls `reloadAtBoundary()`;
its `true` result means discovery was invalidated and that frontend catalogs may
be rebuilt. Do not mutate an in-flight model prefix or implicitly execute native
startup code while refreshing a foreign catalog. New CLI processes naturally
read their own fresh discovery state. Policy revocation also filters cached
foreign discovery results independently of the refresh request.
