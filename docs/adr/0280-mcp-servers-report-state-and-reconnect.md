# 0280. MCP servers report their state and reconnect on request

Status: accepted 2026-10-11

## Context

MCP servers connect in the background (ADR 0230), and local ones start on
first use from a cached catalog (`mcp_lazy.zig`). When one did not work,
nothing said why and nothing could fix it short of a new session:

- The catalog cache was keyed by command line alone. Plugin servers often
  share one launcher command and differ only in `cwd`, so each advertised
  the others' tools until a live re-list overwrote the entry. Calls then
  failed until something re-listed.
- A per-server `env` replaced the child's whole environment, so an entry
  that set one token lost `PATH` and `HOME`, and an `npx` server exited at
  once.
- Entries their own file switched off (`"enabled": false`,
  `"disabled": true`) were started anyway.
- `/mcp` folded every server that was not connected into "not connected —
  /mcp trust", including ones that failed, were optional, or were off.
- A desktop client starts a new graff per run, so a mid-session reconnect
  alone does not help it. It needs to see each server's state and refresh a
  server's catalog between runs.

## Decision

- **One status row per configured server** (`mcp_status.zig`): source,
  transport, a secret-free origin, enabled, state (`ready`, `on_demand`,
  `connecting`, `failed`, `needs_login`, `off`, `opt_in`, `not_started`,
  `unknown`), the failure's text and error name, the server's own last
  stderr line after a failed reconnect, and its tools. `graff mcp status
  --json` builds it from config, cache and stored sign-ins without starting
  anything. The in-session `/mcp` builds it from the registry.
- **Reconnect is a real handshake.** `graff mcp reconnect <name>|--all`
  drops the cached catalog, starts the server fresh, stores what it lists,
  and stops it. `/mcp reconnect <name>` replaces the server in a session's
  registry at the same index and brings back tools withdrawn after a close.
- **On/off is the user's, kept apart from the configs**:
  `~/.codegraff/mcp-state.json` (`graff mcp enable|disable`). `disabled`
  wins everywhere. `enabled` opts in an optional server and overrides an
  entry's own off switch. An entry its file switched off stays off otherwise.
- **The cache key includes `cwd` and a hash of `env`**, and per-server `env`
  overlays graff's own environment.
- **A transient start failure is retried once** (`mcp_start.zig`), and every
  failure is recorded by name so `/mcp` can say why. The last failure of each
  server is also kept in `~/.codegraff/mcp-failures.json` (keyed like the
  cache) until a real start succeeds, so `graff mcp status` reports a server
  that broke in an earlier session without starting it. A server restored
  dormant from the cache clears nothing.

## Consequences

Clients (the desktop app's MCP servers page and the fullscreen client's
`/mcp`) read one JSON shape and act through four commands. Existing caches
re-list once for entries with a `cwd` or `env`, because their key changed. A
failed reconnect starts the server a second time for up to three seconds to
read its stderr. That only happens when a person asked for the reconnect.
