# 0119. Computer tools receive caller-owned turn context

Status: accepted 2026-09-15

## Context

The computer-use MCP adapter requires session and turn correlation metadata
before browser selection. Plain tool arguments cannot supply that request
context, so the initial browser entry fails even when the tool is loaded.

## Decision

Each agent owns opaque session and turn identifiers. Begin a new turn ID at
`runTurn`, retain the session ID for that agent, and copy the context through
`ToolCtx` into MCP dispatch. The IDs are independent of account information,
saved-session names and model arguments. Concurrent callers do not mutate a
shared registry-level context.

Attach the required `x-codex-turn-metadata` request field only for the
`cua_repl` and `node_repl` adapters. Keep ordinary MCP requests unchanged.
The adapter's authentication, permissions and action review remain intact.

## Consequences

Browser selection can initialize through the installed adapter. The
`computer-tool-turn-context` behavior regression checks real MCP dispatch,
stability within a turn, and rotation on the next user turn. Unit coverage
also verifies that model arguments cannot replace host metadata and that
unrelated servers receive none of it.
