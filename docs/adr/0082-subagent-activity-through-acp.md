# 0082. Sub-agent inspection uses a separate ACP activity feed

Status: accepted

## Context

Sub-agents run as worker threads. Their streamed progress previously had no
frontend sink, so opening the Agents panel could show peer sessions but not the
work happening inside them. Sharing the parent's output writer would mix child
text into its transcript and tie background activity to one prompt's lifetime.

## Decision

Each child gets an independent engine event sink. It records emitted reasoning
text, response text, tool calls and results, followed by completion or failure.
It never reserves parent transcript sequence numbers. Stream delivery checks
for an injected sink independently of an output writer.

The local presence registry holds atomic, owner-readable snapshots under the
parent's PID and process-start identity. The read-only `graff/agents` actions
`children` and `activity` revalidate the parent and workspace scope on every
request. Activity returns standard ACP session-update envelopes keyed to the
child identifier. Inspection neither consumes inboxes nor sends instructions.

The GUI opens a focused child selector after selecting a parent Graff. It reuses
the existing transcript and collapsed tool disclosures. Late responses from a
previous selection are discarded. Polling pauses when the window is hidden and
stops for completed children. Messaging remains an explicit separate action.

## Consequences

This is recent activity for a live parent, not a durable child session API.
Snapshots retain at most 96 events, each with at most 2 KiB of text, and a 32 KiB
final response. Delta publication is throttled; tool transitions and completion
publish immediately. Only the newest 64 completed children are retained alongside
working children. Parent retirement or dead-presence cleanup removes its feed.
Truncation is shown explicitly. Older binaries report no available feed.

Activity stays local and is excluded from profiler feedback. Worker threads
share their parent's resource measurements; per-child RSS is not claimed.
The view displays only progress the agent emitted, not hidden reasoning.
