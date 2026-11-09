# 0326. Deterministic Phase-1 tool-result pruning before LLM compaction and crash-tail tool repair

Status: accepted 2026-11-09

## Context

When a long tool loop crossed `compactAt`, `autoCompact` immediately invoked a full LLM summarization request (or server compaction) even when most of the context bloat came from a few large `>= 4 KiB` inline tool outputs in older turns (`5db4339e`, [arXiv:2609.20804](https://arxiv.org/abs/2609.20804)). Separately, when a turn crashed or was interrupted mid-batch with multiple parallel tool calls, `history_wire` synthesized identical generic error stubs for both the tool call that was actively executing and sibling tool calls that had not started yet, leading models to assume unstarted side-effecting calls had already partially run.

## Decision

- At the `compactAt` boundary, `compact_prune.pruneOldToolResults` runs a deterministic Phase-1 pass before `autoCompact` makes any LLM call: inline tool outputs `>= 4 KiB` outside the protected recent tail (including the newest model turn's unread results per ADR 0272) are replaced in place with their `tool_handle.shapeHint` plus head/tail previews. If the pruned transcript drops below `compactAt`, the LLM summary request is skipped entirely.
- When repairing dangling tool-call batches on load or recovery, `history_wire` marks the interrupted in-flight call as `TOOL_OUTCOME_UNKNOWN` and subsequent unstarted calls in the batch as `TOOL_NOT_STARTED`.
- `tool_repeat` hashes JSON object arguments in canonical sorted key order so semantically identical tool calls with reordered JSON keys are detected by stuck-loop guards.

## Consequences

Tool-heavy runs reclaim context deterministically without paying for an LLM summary turn when old tool outputs account for the overflow, and post-crash recovery distinguishes uncertain side effects (`TOOL_OUTCOME_UNKNOWN`) from calls that never started (`TOOL_NOT_STARTED`).
