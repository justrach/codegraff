# 0153. Task workspaces copy gitignored files and run project scripts

Status: accepted 2026-09-21

## Context

Raw `git worktree add` checks out tracked files only. Coding-agent workspaces
need the rest of a local project: `.env.local`, a one-time `pnpm install`, a
dev server, and teardown that is not "the agent finished a turn."

Conductor documents this as `.worktreeinclude` / Files to copy, plus
`scripts.setup` / `scripts.run` / `scripts.archive` in
`.conductor/settings.toml`. Finish is still not archive (ADR 0147): dirty or
unique-commit trees stay.

## Decision

- After `graff worktree create` / `workspace action=create` / auto-isolate,
  copy gitignored files from the **main checkout** that match `.worktreeinclude`
  (else `file_include_globs` in `.graff/workspace.toml` or
  `.conductor/settings.toml`, else `.env*`). Tracked files are already there.
  Untracked files that Git does not ignore are not copied.
- Then run `scripts.setup` from `.graff/workspace.toml`, falling back to
  `.conductor/settings.toml`. Setup failure keeps the workspace.
- `graff worktree run <name>` runs `scripts.run` from that checkout.
- `graff worktree archive` runs `scripts.archive` only when the tree is
  actually going to be removed.
- Scripts see `GRAFF_WORKSPACE_*` and Conductor aliases
  (`CONDUCTOR_WORKSPACE_NAME`, `CONDUCTOR_WORKSPACE_PATH`, `CONDUCTOR_ROOT_PATH`,
  `CONDUCTOR_PORT`) so an existing Conductor project file works.

## Consequences

A Conductor-configured repo is usable as a graff task workspace without a
second clone. Desktop review/merge-back UX stays #1124. Stale-tree reaping
stays #1118. Finish still does not archive.
