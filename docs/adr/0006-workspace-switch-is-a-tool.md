# 0006. Mid-session workspace switch is a tool, not a skill-only protocol

Status: accepted 2026-08-18

## Context

A session can sit next to several git worktrees (Claude `.claude/worktrees/`,
`graff -w` tabs, `git worktree add`). Users asked to change which tree file
tools see without restarting, and whether a loadable skill (like `jspace`)
would be enough.

`read_file` / `edit_file` / `bash` bind to process cwd, or to a subagent's
isolated `agent_cwd`. A bash `cd` does not move the next native file call.
`graff -w` only enters a tree at startup. A skill body cannot chdir.

## Decision

- A folded native tool `workspace` (`list` / `use`) plus `/workspace` actually
  chdir the **root** session, update `g_cwd_display`, rebind presence, and
  retarget tool-output spill.
- Subagents are refused: their cwd is per-agent on purpose so siblings do not
  share a process-wide chdir.
- A bundled `workspace` skill is the on-demand playbook (when to list/use).
  Loading the skill does not move the cwd.
- Do not dump every worktree path into history; list is a tool result.

## Consequences

- Project instructions composed at startup stay until `/clear` or restart.
- `-w` auto-commit unhooks on switch (`g_worktree_branch` clears).
- Revisit if file tools grow an explicit root path that makes chdir unnecessary.
