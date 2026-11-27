# 0359. Count logical calls and disable resends separately

Status: accepted 2026-11-27

## Context

A run can acquire one logical model-call permit and still send more than one
provider request. Network retry, stream reconnection, credential recovery, and
provider error recovery all happen inside the request that already owns the
permit. Embedders need to be able to stop automatic resends for workloads where
each submission matters.

## Decision

`--max-model-calls` counts logical calls and keeps its existing retry policy.
`--no-model-resends` disables engine-managed resends and recovery that would
submit another request inside the same call. HTTP protocol negotiation can still
select HTTP/1.1 before an HTTP/2 send. An expired held WebSocket can still
rebuild unsent input. A failed WebSocket attempt ends the call. A later call
may use SSE if the failure established that the endpoint cannot upgrade.
The optional WebSocket warmup is disabled in this mode. Model-serving children
of the HTTP and MCP servers inherit the launch policy.

Standalone server compaction acquires the same logical permit before sending.
Both server compaction routes that share the model endpoint's origin propagate
terminal resolver failure to the active turn. This prevents preflight
compaction from exhausting the transport budget and then immediately starting
a fresh request with the same unreachable origin. Overflow and other
compaction recovery still use their existing policies.

## Consequences

Pair `--max-model-calls 1` with `--no-model-resends` to bound logical calls and
automatic resends together. The flag applies inside the engine request loop.
Service discovery, credential acquisition, distinct model calls, and retries
performed by the provider or an external driver have their own boundaries.

The first terminal resolver failure during preflight keeps the prompt and
history, records the transport failure, and lets an explicit later turn retry
the provider.
