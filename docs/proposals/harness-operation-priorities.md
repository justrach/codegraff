# Harness operation priorities

Status: proposed, 2026-09-23. This ranks implementation candidates, not measured
performance or accepted architecture changes. Existing ADRs remain authoritative.

## Ranking

Rank combines correctness benefit, likely reduction in wasted work, implementation
risk, and overlap with existing features. Expected benefits require verification;
none establish lower latency, token use, or cost by themselves.

| Priority | Candidate | What is better and why | Effort / risk | Acceptance evidence |
|---|---|---|---|---|
| 1 | Durable operation recovery | Persist dispatch intent and terminal outcome separately. A crash must not silently replay a mutation or present unfinished work as success. | Medium–high; recovery and schema migration affect correctness. | Crash injection before dispatch, during execution, and after completion; no duplicate mutation; ambiguous outcomes remain explicit. |
| 2 | Context budget report | Show retained, omitted, truncated, and summarized content with reasons. Makes avoidable context growth diagnosable without changing prompts first. | Medium; keep reporting outside the model prefix and protect content. | Accounting reconciles with assembled requests; output contains metadata only; reporting adds no model calls or prompt tokens. |
| 3 | Explicit pending operations for RLM | Let independent work continue while an owned operation is pending, with cancellation and one terminal delivery. Potential latency benefit, but dependency ordering dominates. | High; changes execution and result-delivery contracts. | Ordered mutation/read tests, cancellation and restart tests, duplicate-delivery tests, and paired latency/token/cost evaluation with unchanged correctness graders. |
| 4 | Bind operations to existing workspace ownership | Record the workspace selected at admission and retain it while a writer is live. Extends existing lifecycle rules instead of adding a second workspace manager. | Medium; useful alongside priority 1. | Switching workspaces cannot redirect an admitted job; archive refuses live writers; resume preserves the original workspace. |
| Defer | Fork entire conversations | Convenient branching, but duplicated context and detached operation ownership need explicit semantics. No demonstrated advantage over focused child briefs here. | High regression risk relative to current benefit. | Reconsider only with a concrete workflow and evidence that existing child briefs are insufficient. |
| Avoid by default | Periodic model heartbeats for pending tools | Repeated wakeups can consume requests without new information. Prefer state-change notifications and existing blocking waits. | Low implementation effort, potentially recurring cost. | Any exception must show progress or recovery benefit beyond completion events, with wakeup cost included. |

Implementation order: audit existing persistence and add crash tests first; add
only the missing operation state. Context reporting can proceed independently.
Workspace binding belongs in the operation contract before cross-turn RLM jobs
are enabled. Do not promise exactly-once external side effects: a process can die
after an effect occurs but before its completion is durably recorded.

## Implemented safeguards

- [ADR 0179](../adr/0179-durable-shell-handles.md) closes shell-handle reuse
  after restart: reserve durable identities before dispatch, and reject stale
  output/kill requests. This does not yet provide terminal receipts or reattach
  surviving operations. The offline crash and reservation regressions run in
  `scripts/eval-tier1.sh --only shell`.
- [ADR 0178](../adr/0178-batched-edits-preflight-before-commit.md) prevents an
  invalid later edit span from leaving earlier spans written. Valid batches
  use one staged replacement and exact verification. This is a correctness
  safeguard; lower model latency or token usage remains unproven.

## Source comparison

Source review is pinned to Unreal Agent revision
[`b7c9bf1`](https://github.com/unreallabsai/unreal-agent/tree/b7c9bf1c5c2fa4127255c07727a7c8413e23944a).
This is a code review, not a benchmark or execution audit.

- **Operation lifecycle is the strongest transferable design.** The
  [coordinator](https://github.com/unreallabsai/unreal-agent/blob/b7c9bf1c5c2fa4127255c07727a7c8413e23944a/harness/coordinator/loop.go)
  tracks tool calls and operations separately, persists scheduled state before
  dispatch, consumes operation updates, and supports optional heartbeat wakes.
  Borrow the durable boundary and explicit states, not every wakeup policy.
- **Its context report is not a finished capability.** The
  [context builder](https://github.com/unreallabsai/unreal-agent/blob/b7c9bf1c5c2fa4127255c07727a7c8413e23944a/harness/contextbuilder/builder.go)
  returns an empty report and supplies temporary running-tool outputs. Neither
  proves a compaction audit nor establishes that placeholder results are safe
  for Codegraff's existing wire contracts.
- **Its workspace selection is narrower than Codegraff's lifecycle.** The
  [runner](https://github.com/unreallabsai/unreal-agent/blob/b7c9bf1c5c2fa4127255c07727a7c8413e23944a/cmd/internal/agentrunner/run.go)
  selects a working directory and configuration. That alone is not a Git
  worktree manager or a filesystem security boundary. Preserve Codegraff's
  setup/archive scripts, ownership checks, and dependent-chain isolation.

## Existing constraints

- [ADR 0023](../adr/0023-codex-subagent-is-sidecar-not-v8.md): focused child
  work, without parent-history forks.
- [ADR 0153](../adr/0153-task-workspaces-copy-and-scripts.md),
  [ADR 0164](../adr/0164-task-workspace-archive-needs-current-evidence.md), and
  [ADR 0167](../adr/0167-workflow-isolation-belongs-to-dependent-chains.md):
  workspace setup, ownership, retention, and chain isolation already exist.
- [ADR 0174](../adr/0174-completion-requires-terminal-tool-results.md): pending
  work cannot be presented as completion.
- [ADR 0175](../adr/0175-rlm-preserves-dependent-tool-order.md): RLM preserves
  dependencies and stops on pending, failed, or cancelled results.
- [ADR 0177](../adr/0177-owned-async-tool-execution.md): current direct async
  jobs join before the next request; cross-turn jobs require a separate design.

Promote each candidate separately. Reliability fixes need failure-injection
evidence; performance claims need repeated, counterbalanced comparisons with
fixed tasks, graders, routes, and binaries. Retain failures and unknown usage;
report correctness alongside wall time, input/output tokens, actual cache hits,
and cost. Record accepted behavioral decisions in an ADR after validation.
