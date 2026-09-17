# 0134. JSONL is the durable peer room; Accord Unix is live by default

Status: accepted 2026-09-17

## Context

Co-resident sessions persist speech in `presence_chan` JSONL (pid/start/goal/ts,
resume cursor, two PIDs). Accord ACD1 is a 4-byte Unix-0600 frame. In-process
Mailbox is a shape demo and cannot be the room.

## Decision

JSONL stays the durable log. `postMessage` / `readNewMessages` remain the seam.
On Unix, each announced session keeps a standing Accord duplex on
`{pid}-{start}.accord.sock` (0600). `postMessage` still appends JSONL, then
sends the same line as `msg` on that link (progress/stop reuse the session).
`GRAFF_ACCORD=0` opts out. Windows stays JSONL-only. A live miss never fails
the durable write. Do not replace the room with Mailbox.

## Consequences

Idle TUI, line-REPL, and `graff acp` sessions auto-start a turn on new parked
peer mail (#1001, #1007), one batch at a time; `action=inbox` resets the latch.
An in-flight prompt is not preempted (#430). `GRAFF_ACCORD=0` does not
change history pull (ADR 0004).
