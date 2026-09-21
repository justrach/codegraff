---
name: workspace
description: Switch this graff session among git worktrees without restarting. Use when several checkouts exist and file tools must follow a different tree.
---

# workspace

One session, many trees. The actuator is the `workspace` tool (or `/workspace`
for you). This skill is the playbook. Loading it does not move the cwd.

## Why a tool

`read_file`, `edit_file`, and `write_file` resolve against the process cwd (or
a subagent's isolated `agent_cwd`). `bash` inherits that cwd too. A `cd` inside
one bash call dies with the shell — the next file tool is still in the old
tree. `graff -w` isolates a session at **startup**. A second live session in the
same checkout auto-isolates. Mid-session switch is `workspace action=use`.
A new independent task is `workspace action=create`.

## Pull, do not dump

1. `workspace action=list` (or `/workspace`) — one line per tree. Star is here.
2. `workspace action=use path=<folder or unique fragment>` — chdir this
   session. Example: `path=cursor-peer-pull-554f` matches a Claude worktree
   named that, or `path=cursor/peer-pull-554f` matches the branch.
3. `workspace action=create name=<slug>` — mint a fresh branch and worktree
   from the remote base, then enter it. Optional `base` is a branch or commit
   (default `origin/main` after fetch). Independent work gets its own tree;
   same-branch collaboration stays in one workspace (`isolation: shared_cwd`).
4. If the match is ambiguous, name more of the path. Do not guess.

Do not paste every worktree path into the next user turn. The list result is
enough. Do not `git worktree list` via bash when this tool exists.

## What moves, what does not

Moves: process cwd, the prompt's cwd badge, presence identity (peer rooms
follow the new folder), tool-output spill.

Does not move: conversation history, the standing goal, loaded tool schemas,
subagents already running (they keep their assigned tree). Project files
(`CLAUDE.md`, `.harness/`) stay the ones composed at session start until
`/clear` or a restart. After a switch, prefer paths relative to the new cwd.

## Do not

- Spawn a new graff per worktree when a switch will do.
- Process-wide chdir from a subagent (the tool refuses).
- Treat this as `graff worktree merge` — that lands a `-w` scratch tab.
- Invent a font or OSC sequence; the tree is a directory, not a theme.
