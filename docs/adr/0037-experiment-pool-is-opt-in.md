# 0037. Experiment worktree pool is opt-in

Status: accepted 2026-08-26

## Context

#629: default isolation is `shared_cwd`, so "run 3 approaches" stays on one
agent. Per-spawn `isolation: worktree` pays `git worktree add` mid-turn.

On `main` as of the 279 continuation.

## Decision

`--experiment N` / `/experiment N` mints N trees under
`.graff/worktrees/exp-{id}/` **before** the first child. Each spawn claims
the next seat and sets `agent_cwd`. The root stays on the caller tree and
is told it **must** spawn (system-prompt mandate), not edit. Default
sessions are unchanged. Pool trees are not auto-deleted: finish reports
path, branch, keep-reason, and diffstat. `graff worktree list` tags them
`(experiment pool)`.

## Consequences

Seats are FIFO. A fourth child after `--experiment 3` uses normal isolation.
Dependent pipeline stages still need #295. Docker snapshots stay #554.
