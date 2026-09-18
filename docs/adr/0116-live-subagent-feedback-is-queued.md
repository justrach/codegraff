# 0116. Live subagent feedback is queued at model-step boundaries

Status: accepted 2026-09-15

## Context

Background children already have numeric handles, private context, and a
bounded run budget. The parent needs to correct a child while it works.
Peer-session messaging does not address that child's in-process history.
The broader retained-worker proposal also requires durable history and
identity migration; those are unnecessary for feedback to a live job.

## Decision

Expose root-only `agent_message(id, message)` using the existing background
registry. Queue owned UTF-8 text under a per-child mutex; acknowledge enqueue
without waiting for delivery. Bound individual messages to 16 KiB, pending
bytes to 64 KiB, and pending count to 32.

At a child model-step boundary, append the entire pending batch to its live
history as tagged user messages, preserving FIFO order. Allocation failure
must leave the batch pending without partially appending it. The current tool
or request continues without interruption. Completing a child atomically
closes an empty inbox; accepted pending feedback instead requires another
step. Error and cancellation exits close admission and report undelivered
feedback in the child result. Reap frees the inbox after the pump joins.

Keep existing model selection, reasoning, cancellation, and budget behavior.
Reject completed or unknown handles and child-originated calls. No restart,
retained transcript, alias, cross-process delivery, or budget reset is implied.
The status ledger from ADR 0068 remains status, not live-worker reattachment.

## Consequences

Acknowledgement means queued, not applied. Existing limits may end a child
before it acts on feedback. This bounded feature does not complete the
[retained-worker design](../subagent-steering-design.md).

Unit tests cover ownership, bounds, allocation failure, completion admission,
and dispatch. Offline lifecycle evals `subagent-feedback-during-tool` and
`subagent-feedback-during-final` verify tool completion ordering and the final
response race through the real harness. See [usage](../subagent-feedback.md).
