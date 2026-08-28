# 0035. First model call does not wait for deferred MCP

Status: accepted 2026-08-26

## Context

Interactive `--yolo` (including `graff acp`) starts MCP handshakes in the
background so the prompt can paint. The first `request()` still called
`joinPending`, so a silent stdio probe (default 5s) or a 15s handshake cap
blocked every native tool on the first turn. The chips looked late; the
model had not even been called.

## Decision

`joinBeforeRequest` skips the wait once. Native tools run on the first
turn. MCP catalogs merge on the next request, `/mcp`, or teardown. A dim
notice says so when a TUI sink is attached.

Companion auto-connect (`codedb-pro --mcp`) is the same wait. Interactive
`--yolo` queues it onto `pending_starts` instead of `addServer` on the
main thread. `codedb-pro probe` is capped (2s), never `timeout 0`. A
`defer_join` fan-out that cannot `io.concurrent` skips that server
rather than falling back to inline `io.async`.

Interactive boots print a dim receipt after `plugins:` (`mcp: N server(s)
in background`, `companion: codedb-pro (background)`) and name any boot
phase ≥80ms, so a hang is visible without `GRAFF_BOOT_DEBUG`.

## Consequences

A one-shot first turn that *only* has MCP tools will not see them until
the second request. `/mcp` still blocks. Revisit if a session is MCP-only
and the first prompt must use those tools. A licensed companion's eager
pin and system-prompt note wait until the handshake joins; first paint
uses native tools.
