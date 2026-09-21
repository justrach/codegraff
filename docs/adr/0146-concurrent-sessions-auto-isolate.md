# 0146. Concurrent sessions auto-isolate into a Git worktree

Status: accepted 2026-09-20

## Context

Two root sessions (REPL, TUI, or `graff acp` desktop chats) in one checkout
share `.git/index`. Parallel `git add` / `commit` / `status` then fail on
`index.lock`. `-w` already isolated a session, but only when the user asked.
Presence warned and gated; it did not move the second session.

Task workspaces are one branch and one checkout. Independent / fan-out work
must not share a tree; same-branch collaboration stays in one workspace.
Finish is not archive.

## Decision

- One workspace ↔ one branch ↔ one Git worktree. Trees share the object DB
  (`git worktree add`); they are never a second clone.
- If another live session already owns this Git checkout, the new session
  mints `.graff/worktrees/<slug>` on `worktree-<slug>` and enters it. Shared
  object DB and the one claim ledger per common dir stay as they are.
- `-w`, lean/`-p` oneshots (ADR 0024), and non-git folders do not auto-isolate.
- `workspace` `create` and `graff worktree create` mint from the remote base
  (`origin/HEAD` / `origin/main` after fetch; an explicit `base` wins).
- Independent / fan-out children default to `isolation: worktree` and bind
  tools to `agent_cwd` (no process-wide chdir). `shared_cwd` is only for
  same-branch collaboration (review + fix, pipeline stages, an explicit field).
- `git worktree add` failure is an isolation failure unless
  `isolation_fallback` / `GRAFF_ISOLATION_FALLBACK=1`.
- Finish / `graff worktree archive` keep dirty or unique-commit trees. Archive
  removes only a clean checkout whose commits exist elsewhere.
- `session/new` reports the checkout `cwd` so GUI chats bind to that tree.

## Consequences

The second concurrent agent never contends on the first agent's `index.lock`.
A first session still owns the folder it started in. Experiment-pool pre-mint
(ADR 0037) still skips mid-turn `worktree add` when seats are reserved.
Setup/run/archive scripts and `.worktreeinclude` copy are ADR 0153. Stale-tree
reaping stays #1118. Desktop review/merge-back stays #1124.
