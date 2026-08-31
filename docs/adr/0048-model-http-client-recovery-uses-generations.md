# 0048. Model HTTP client recovery uses leased generations

Status: accepted 2026-08-31

## Context

Issue #691 captured launch-scoped `TlsInitializationFailed` storms: once
`std.http.Client.request` failed during TLS construction, six retries and every
later TUI turn reused the same client and failed until process restart. The
existing #177 connection poison cannot help because no `Request` exists yet.
The launch client is also shared with concurrent root, compaction, title,
recap, and subagent traffic, so deinitializing it in place would race users.

## Decision

Model HTTP constructors lease an active launch-level client generation. A
request-construction `TlsInitializationFailed` retires that generation and
publishes a prewarmed replacement under one mutex. Existing requests keep the
retired generation alive through reference-counted leases; later retries and
turns resolve the original launch pointer to the replacement. Owned retired
generations are deinitialized only after their final lease releases.

The original launch client is never reclaimed by the generation manager:
unrelated launch consumers still holding its pointer remain safe until normal
shutdown. All managed constructors wait for initial CA prewarm readiness, and
CA-prewarm plus request-construction failures leave distinct trace evidence.
Post-construction send/read failures retain #177's per-connection poison.

## Consequences

A recovered network can serve later root, synthetic, compaction, and child
model trajectories without replacing the process or durable session. Recovery
adds one mutex operation per model HTTP request and temporarily retains an old
client while requests from that generation are still in flight. WebSocket
transport remains independently managed; this record governs HTTP model calls.
