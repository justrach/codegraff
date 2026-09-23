# 0155. Resume re-enters a linked-worktree save

Status: accepted 2026-09-22

## Context

ADR 0059 listed cwd then `~/.graff/sessions` and restored history into the
**current** cwd — file tools stayed put. That avoided a silent jump into
`$HOME`. ADR 0146 then auto-isolated a second concurrent session into
`.graff/worktrees/<slug>`. Those conversations save under the linked tree.
`/resume` from the main checkout either missed them or replayed the
transcript onto the wrong branch.

## Decision

- `/sessions` and the resume picker also list `.graff/sessions` in this
  repository's git worktrees. Cwd still wins on the same base name; home
  saves come last.
- On `/resume`, `--resume`, and the TUI/desktop picker, if the save's
  workspace still exists and is not `$HOME`, enter it (same `chdir` as
  `workspace use`) so `read_file` / `edit_file` / `bash` follow the
  conversation.
- If the tree is gone, restore history here and say so.
- Home-origin saves stay history-only (ADR 0059).

## Consequences

A conversation that ran in an isolated tree resumes in that tree. `$HOME`
chats opened from a repo still do not steal the process cwd. Stale
worktrees need `/workspace use` only when git no longer lists them.
