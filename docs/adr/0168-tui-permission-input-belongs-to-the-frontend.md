# 0168. TUI permission input belongs to the frontend

Status: accepted 2026-09-23

## Context

The fullscreen TUI runs the existing turn engine through its in-process ACP
adapter (ADR 0041). Normal turns previously enabled unattended approval because
the engine's approval prompt read stdin, which the fullscreen input loop owns.
A normal-mode label therefore could not offer an interactive tool decision.

## Decision

The engine gate accepts an optional typed permission handler carrying the call
ID, tool name, and description. The gate continues to decide whether consent is
required; the frontend supplies only an allow-once or deny decision. Plan-mode
write restrictions, publication checks, and special privacy consent gates still
run before this handler. Explicit always-approve mode keeps its existing policy.

The in-process TUI adapter binds this handler for its turn. Requests travel in a
bounded job-owned mailbox, with monotonically increasing request IDs. Responses
must match the active request and are accepted once. No request borrows the
turn arena, and retiring a request invalidates stale replies. Overlapping or
oversized requests fail closed. The adapter checks cancellation while waiting.

The fullscreen input loop renders the request and handles explicit y/n decisions.
Bracketed paste cannot approve; Escape cancels the active turn. This replaces
ADR 0041's assumption that all TUI turns need unattended approval. It does not
introduce a subprocess or claim ACP wire-level request_permission support.

## Consequences

Normal TUI turns can ask without reading stdin or blocking rendering. Approval
is per call and is not persisted. Scripted legacy callers retain their existing
unattended policy. General ask_user input, engine-owned pickers, and complete
command/query transport remain separate work; this is not completion of the
engine/frontend separation epic.

Regression coverage exercises the real gate, threaded response/cancellation,
stale and duplicate replies, and the terminal simulator's render/input path.
