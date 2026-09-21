# 0153. Task workspaces copy gitignored files and run project scripts

Status: accepted 2026-09-21

## Context

Raw `git worktree add` checks out tracked files only. A task workspace needs
the rest of a local project: `.env.local`, a one-time install, a dev server,
and teardown that is not "the agent finished a turn." Finish is still not
archive (ADR 0147): dirty or unique-commit trees stay.

## Decision

- After `graff worktree create` / `workspace action=create` / auto-isolate,
  copy gitignored files from the **main checkout** that match `.worktreeinclude`
  (else `include` in `.graff/workspace.toml`, else `.env*`). Tracked files are
  already there. Untracked files that Git does not ignore are not copied.
- Then run `scripts.setup` from `.graff/workspace.toml`. Setup failure keeps
  the workspace.
- `graff worktree run <name>` runs `scripts.run` from that checkout.
- `graff worktree archive` runs `scripts.archive` only when the tree is
  actually going to be removed.
- Scripts see `GRAFF_WORKSPACE_NAME`, `GRAFF_WORKSPACE_PATH`, `GRAFF_ROOT_PATH`,
  and `GRAFF_WORKSPACE_PORT`. Graff does not read another product's settings
  file or export another product's environment names.

## Consequences

A repo opts in with `.graff/workspace.toml` and optional `.worktreeinclude`.
Desktop review/merge-back UX stays #1124. Stale-tree reaping stays #1118.
Finish still does not archive.
