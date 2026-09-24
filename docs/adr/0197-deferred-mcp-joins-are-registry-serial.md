# 0197. Deferred MCP joins are serial within a registry

Status: accepted 2026-09-24

## Context

ADR 0035 starts optional MCP connections before the first model call, and
ADR 0104 joins only finished connections at later request boundaries. A parent
and background child share one registry. When both request at once, they can
observe the same completed startup future and each try to consume it. That
can double-await the future or read its freed queue entry.

## Decision

Use the registry mutex for every deferred queue mutation and join. Public
entry points take the lock; private helpers perform joins while it is held.
Tool-call lookup uses the same lock, and catalog readers copy the published
tool slice while holding it. Keep model requests nonblocking with respect to
unfinished handshakes. Emit notices after releasing the lock.

## Consequences

Parent and child requests consume each finished connection once. Joining a
completed handshake briefly serializes registry users. Explicit inspection
and teardown can still wait for unfinished handshakes as before.
