# 0147. Finish is not cleanup fan-out; parked peer mail waits for idle

Status: accepted 2026-09-21

## Context

A child that finished a worktree could keep running to "clean up", and
other agents then spawned to fix what that cleanup created (#1135).
Parked peer mail also injected a user-role wake at every root step
boundary, which aborted tools on an in-flight REPL/TUI/ACP turn (#1136).
Idle auto-turn (#1001, #1007) was meant for idle sessions; mid-turn
preemption was already out of scope (#430, ADR 0134).

## Decision

- Isolation is one workspace, one branch, one worktree.
- Finish is not archive. Dirty or unique-commit trees stay; an empty
  clean tree may be removed. Do not spawn a child to clean up a finished
  tree, and do not delete a tree and recreate the work with a fix-it child.
- Live background fan-out is refused at the concurrency cap, not queued
  without bound.
- `deliverInbound` parks inbound during a root turn. Paint and the
  one-line `[peer]` wake wait until idle. Same latch on REPL, TUI, and
  `graff acp`. A wake is never the newest authoritative user turn
  while tools continue, and `attempt_completion` does not auto-run a
  peer wake (#1137). The same unread generation is exposed at most once.

## Consequences

A kept-tree note must not read as an invitation to spawn. Peer mail still
starts an idle turn. In-flight tools are not preempted by a parked wake.
