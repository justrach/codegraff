# 0037. Experiment worktree pool is opt-in

Status: accepted 2026-08-26

## Context

#629: default isolation is `shared_cwd`, so "run 3 approaches" stays on one
agent. Per-spawn `isolation: worktree` pays `git worktree add` mid-turn.

This record lives on `release/v0.0.279` after the v0.0.279 tag. It is **not**
on `main` until a later cut.

## Decision

`--experiment N` / `/experiment N` mints N trees under
`.graff/worktrees/exp-{id}/` **before** the first child. Each spawn claims
the next seat and sets `agent_cwd`. The root stays on the caller tree.
Default sessions are unchanged. Pool trees are not auto-deleted.

## Consequences

Seats are FIFO. A fourth child after `--experiment 3` uses normal isolation.
Dependent pipeline stages still need #295. Docker snapshots stay #554.
