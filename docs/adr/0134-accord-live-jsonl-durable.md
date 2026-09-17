# 0134. JSONL is the durable peer room; Accord Unix is opt-in live

Status: accepted 2026-09-17

## Context

Co-resident sessions persist speech in `presence_chan` JSONL (pid/start/goal/ts,
resume cursor, two PIDs). Accord ACD1 is a 4-byte Unix-0600 frame. In-process
Mailbox is a shape demo and cannot be the room.

## Decision

JSONL stays the durable log. `postMessage` / `readNewMessages` remain the seam.
`GRAFF_ACCORD=1` may also send the same JSONL line over Unix 0600 (`GRAFF_ACCORD_SOCK`
or `{chan}.sock`). Default off. A live miss never fails the durable write.
Do not replace the room with Mailbox.

## Consequences

Idle TUI sessions auto-start a turn on new parked peer mail (#1001), one
batch at a time; `action=inbox` resets the latch. Flipping GRAFF_ACCORD
does not change history pull (ADR 0004).
