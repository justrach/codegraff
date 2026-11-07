# 0297: SDK managed replay reuses the existing relay

Status: Accepted (experimental client and local collector integration)

The fetch-only SDK uses the existing account remote-control protocol rather than
creating a second TypeScript agent engine or treating synced transcripts as
execution checkpoints. Native devices retain provider selection, tool execution,
completed conversation checkpoints and event tapes. This relay transport hosts
its client in a Worker; execution remains native on the registered device. The
separate Worker-native Zig/Wasm chat-step experiment is a distinct transport,
not a duplicate engine to reimplement here.

A submit receipt means queued acceptance. Replay is cursor-based and GET failures
may retry; a prompt POST is never implicitly retried because lost responses are
ambiguous and the current engine message-id ledger is bounded/in-memory. Caller
storage owns receipts and atomically committed cursors/effects. One writer per
session is required; receipts are not fencing tokens. Device/disk loss and
exactly-once external effects remain outside this guarantee.

Telemetry is an explicit observer, not an execution dependency. A restricted
OTLP profile carries only random correlation IDs, fixed lifecycle names, numeric
usage/counts, timing and status. It never exports prompt/tool/error bodies or
account/session/model labels. Export queues and deadlines are bounded, with
visible drop counts. Account-authenticated storage is separate from anonymous
product telemetry; installing the SDK cannot imply that a collector was deployed.

Reusing the relay avoids introducing another scheduler/checkpoint format. The
Worker-native sandbox experiment retains cleanup ownership, not resumable
conversation checkpoints; neither it nor this client implies a crash-safe
exactly-once command journal. A shared optional OTLP exporter can observe either
transport without changing its execution or durability semantics.
