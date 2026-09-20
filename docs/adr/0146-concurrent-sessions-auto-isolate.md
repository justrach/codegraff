# 0146. Concurrent sessions auto-isolate into a Git worktree

Status: accepted 2026-09-20

## Context

Two root sessions (REPL, TUI, or `graff acp` desktop chats) in one checkout
share `.git/index`. Parallel `git add` / `commit` / `status` then fail on
`index.lock`. `-w` already isolated a session, but only when the user asked.
Presence warned and gated; it did not move the second session.

Task workspaces are one branch and one checkout (#1119). Agents that share a
branch stay in one workspace; independent work gets a new tree. Finish is not
archive (#1124).

## Decision

- If another live session already owns this Git checkout, the new session
  mints `.graff/worktrees/<slug>` on `worktree-<slug>` and enters it. Shared
  object DB and the one claim ledger per common dir stay as they are.
- `-w`, lean/`-p` oneshots (ADR 0024), and non-git folders do not auto-isolate.
- `workspace` `create` and `graff worktree create` are the explicit mint.
- `session/new` reports the checkout `cwd` so GUI chats bind to that tree.
- Isolation is opt-in (`isolation: worktree`) for dependent child stages.

## Consequences

The second concurrent agent never contends on the first agent's `index.lock`.
A first session still owns the folder it started in. Archive, merge-back, and
setup scripts stay #1124 / #1123.
