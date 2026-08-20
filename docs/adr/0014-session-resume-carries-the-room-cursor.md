# 0014. Session resume carries the room cursor, not a replay

Status: accepted 2026-08-20

## Context

ADR 0004 made peer speech pull: a one-line `[peer]` wake in history, bodies in
a process-local inbox. That is cheap *inside one process*. `/resume` starts a
new process. The worktree/device JSONL offsets (`g_inbox_off`, `g_device_off`)
and the parked ring reset to zero, so the first drain is treated as a late
join and re-injects the last 10 room lines. Compact already knew those wakes
are not the human; resume did not.

Codex persists a thread and reuses `prompt_cache_key` across compact and
resume (`codex-rs` remote compact snapshots). OpenCode pages session parts
from a cursor and keeps side-channel state out of the next request; its
`promptCacheKey` is the session id. Claude Code's SendMessage inbox is a file
per agent — resume pulls, it does not replay the room into the conversation.

A peer-only wake also counted as a user turn (`hasMeaningfulState`,
`sessionTitle`, `firstUserTitle`), so overheard chatter could mint or name a
session.

## Decision

- `.session.json` stores `chan_off`, `device_off`, and `peer_inbox`. Save
  strips `[peer]` / `[presence]` injects from `messages`. Resume restores the
  cursor and mailbox, then injects at most one wake if something is still
  unread.
- A legacy file with no cursor fields seeks both rooms to the tail (same as
  `-p`). One-shots stay at the tail and do not restore the inbox.
- Peer injects are not a human turn for title or "meaningful state."

## Consequences

- `/resume` of a talking session continues the room; it does not pay the
  backlog again or title itself `[peer] 1 unread…`.
- Unread bodies survive a crash only because they are now on the session
  file. The JSONL rooms remain the log; the session file is the cursor.
- Revisit if the inbox must be shared across two processes on the same
  session name (today one process owns a session file).
