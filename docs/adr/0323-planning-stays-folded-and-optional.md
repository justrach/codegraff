# 0323. Planning stays folded and optional; no mandatory turn-1 plan gate

Status: accepted 2026-11-10

## Context

Recent harness-design literature ([arXiv:2609.20804](https://arxiv.org/abs/2609.20804), *An Empirical Study of Harness Design for Coding Agents*) evaluates a mandatory planning scaffold (`+plan`): exposing `update_plan` eagerly, injecting a turn-1 `<system-reminder>` requiring a plan before any workspace action on tasks of 3+ steps, and re-injecting the stored plan on every subsequent turn. In that study's sequential ReAct loop, `+plan` improved resolve rate on a 30B model (by preventing premature pre-edit termination) and reduced median turns on 120B–550B models (by curbing redundant post-edit verification).

We tested whether `graff` should adopt a mandatory turn-1 `todo_write` planning gate (`+plan`) vs. `graff`'s existing design (`-plan`: `todo_write` folded behind `load_tool_schemas` in `src/native_fold.zig`, `src/prompt_text.zig` instructing *"Work directly for small sequential steps"*, parallel tool batching, and single-pass verification guidance) on a 3-file bug-fix and unit-test verification task over ACP across two frontier models (`gpt-6.1-sol` and `grok-4.7`):

| Model | Mode | Unit Tests | Wall Time | API Turns | Workspace Tool Sequence | Post-Edit Redundant Verifications |
| :--- | :--- | :---: | :---: | :---: | :--- | :---: |
| `gpt-6.1-sol` | `-plan` (default) | Pass | **21.44 s** | **4** | `4x read_file` -> `3x edit_file` -> `1x bash` | 0 |
| `gpt-6.1-sol` | `+plan` (mandatory turn-1 `todo_write`) | Pass | **50.51 s** (+135%) | **9** | Same 8 workspace calls + 5 schema/plan turns | 0 |
| `grok-4.7` | `-plan` (default) | Pass | **11.83 s** | **4** | `4x read_file` -> `3x edit_file` -> `1x bash` | 0 |
| `grok-4.7` | `+plan` (mandatory turn-1 `todo_write`) | Pass | **21.40 s** (+81%) | **5** | Same 8 workspace calls + plan overhead | 0 |

Why `graff` sees the opposite latency/turn trade-off from `arXiv:2609.20804`:

1. **Parallel tool batching already collapses the trajectory.** Both frontier models read all 4 files in parallel on Turn 1, apply all 3 edits in parallel on Turn 2, run the test suite once on Turn 3, and finish on Turn 4. Forcing a turn-1 `todo_write` call serializes the start of the run and adds step-by-step bookkeeping turns (+81% to +135% wall time) without changing a single workspace tool call.
2. **Post-edit verification is already bounded.** `graff`'s base prompt (`src/prompt_text.zig::work_note` and `src/prompt_astra.zig`) already instructs models not to repeat passed checks unless new edits or failures occur, so `-plan` already had **0** redundant post-edit verification calls.
3. **Diff-gated standing state beats per-turn plan re-injection.** Re-injecting a mutating `<system-reminder>` plan into every turn's prompt invalidates prefix caching unless diff-gated; `src/goal_flow.zig::LoopListGate` and `compactionSnapshot` already preserve checklists across autonomous continuations and compactions without per-turn prompt churn.

## Decision

- Do **not** add a turn-1 `<system-reminder>` forcing `todo_write` before workspace actions, and do **not** unfold `todo_write` into the eager root catalog.
- Keep `todo_write` and `todo_read` folded in `src/native_fold.zig`, gated off in non-interactive `-p` runs (`src/prompts.zig::detectCaps`, ADR 0232), and optional for multi-step implementation work (`src/prompt_text.zig::todo_note`: *"Work directly for small sequential steps"*).
- Keep checklist persistence, omitted-completed preservation (`src/goal_todo.zig::clearEpochForReplaceEx`), and diff-gated continuation/compaction restatement (`src/goal_flow.zig`) for `/goal` and genuinely long multi-phase runs.

## Consequences

Bounded multi-file tasks complete in 4 API turns without paying a 1.8x–2.4x latency and round-trip tax for checklist ceremony. Anyone proposing a mandatory turn-1 planning reminder or eager `todo_write` exposure must show a net win on both resolve rate and wall-clock time over `graff`'s parallel-batched baseline.
