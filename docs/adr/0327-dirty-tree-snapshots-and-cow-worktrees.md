# 0327. Content-addressed dirty workspace snapshots and CoW/hook-safe subagent worktrees

Status: accepted 2026-11-09

## Context

Subagent and workflow isolation hit three practical failure modes on real repositories (`7321ec3b`, `29941b47`, `19d7e48d`):

1. `edit_contract` compared `git status --porcelain` before and after a worker phase; if a file was already modified (`M path`) in the working tree before the worker ran, further edits to that same file left `git status --porcelain` unchanged, causing `edit_contract` to miss the worker's edit.
2. `git worktree add/status/remove` inside `.graff/worktrees/` could trigger repository git hooks, spawn background `fsmonitor` daemons, block on Git LFS smudge filters, or fail ownership checks across container/UID boundaries.
3. Fresh subagent worktrees started without gitignored build/dependency caches (`.zig-cache`, `zig-cache`, `node_modules`), forcing cold rebuilds in every worker tree.

## Decision

- `workspace_tree_snap.fingerprint` appends a content-addressed digest (`#dirty-hash`) of dirty tracked/untracked files to the `git status --porcelain` snapshot so `edit_contract` detects additional edits to already-dirty files.
- `agent_worktree.safe_git_config_args` prefixes worktree git invocations with `-c safe.directory=* -c core.hooksPath=/dev/null -c core.fsmonitor=false -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false`.
- `agent_worktree.seedWarmCaches` clones gitignored `.zig-cache`, `zig-cache`, and `node_modules` directories from the parent checkout into the new worktree using zero-copy Copy-on-Write (`clonefile(2)` on macOS APFS, `cp --reflink=always -R` on Linux Btrfs/XFS). When the filesystem does not support reflinks (e.g., Linux ext4 or Windows NTFS), `cloneCowTree` cleans up any partial destination and returns `false` without falling back to a slow deep copy. `cleanWarmCaches` deletes seeded cache directories before `git worktree remove` on clean trees.

## Consequences

Subagents in isolated worktrees inherit warm build caches in milliseconds on CoW filesystems, never hang on hooks/fsmonitor/LFS, and `edit_contract` accurately attributes edits even on dirty trees.
