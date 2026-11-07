# 0283. New task worktrees honor `.agents/prepare` and `.agents/linked`

Status: accepted 2026-10-14

## Context

ADR 0153 gave task worktrees a setup step: copy gitignored include files from
the main checkout and run `scripts.setup` from `.graff/workspace.toml`. That
format is graff's own, so a repository prepared for agents in general (whose
setup lives in the shared `.agents/` directory, next to `.agents/skills`) got
no setup in a graff worktree. Copies also go stale: a `.env` edited in the main
checkout after the worktree was made is not the one the worktree reads.

## Decision

When graff mints a task worktree (`graff worktree create`, auto-isolation, an
ACP `-w` workspace):

- `.agents/linked` lists repository-relative literal paths, one per line (`#`
  comments, a leading `/` allowed). Each entry that is gitignored in the main
  checkout, exists there, and is absent in the new checkout becomes a symlink
  to the main checkout's copy. Tracked paths, `..`, globs and missing paths are
  skipped, and nothing is moved or deleted. Linking runs before the ADR 0153
  copy, so a linked path is a symlink, not a copy. Windows links nothing
  (symlinks need privileges); the `.env*` copy still applies there.
- `.agents/prepare`, committed in the checkout, runs from the checkout root as
  the setup script when `.graff/workspace.toml` names no `scripts.setup`. It
  is executed directly when executable, else through `sh`, with the same
  environment, deadline and report as `scripts.setup`.

`graff worktree create` reports the linked count beside the copied count.

## Consequences

A repository set up once for agents works in graff worktrees with no
graff-specific file, and shared local files stay current in every worktree.
`.graff/workspace.toml` keeps precedence, so existing setups are unchanged.
A prepare script should stay fast and safe to repeat: it runs for every new
worktree. Revisit if worktrees need per-checkout copies of a linked file
(today that means leaving it out of `.agents/linked`).
