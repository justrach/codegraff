# 0203. Other agents join the device rooms through `graff peer`

Status: accepted 2026-09-26

## Context

The worktree and device rooms (ADR 0004, 0134) only had graff sessions in
them. Other coding agents on the same machine (Claude Code, Codex, scripts)
could not list, address, or hear graff sessions, and graff could not address
them. Every such agent can run a shell command, so a command is the smallest
common interface.

Two read-path costs also grew with room age: every drain read the whole room
file (and returned nothing once a room passed 256 KiB), and joining at the
tail read up to 16 MiB just to learn the file length.

## Decision

- `graff peer list | send | inbox` works on the same JSONL rooms and presence
  records graff sessions use. There is no second format.
- An external agent's record is owned by the nearest non-shell ancestor
  process, so it lives and is reaped with the agent. Records are named
  `{pid}-{start}-{name}.ext.json`, so one process can host several named
  agents. `activity` is `external`.
- Delivery follows `peer_target`: every unaddressed worktree line, and only
  device lines addressed to the agent. A read cursor per agent sits beside
  the records. A first read joins at the tail.
- A DM is held (exit 3) when the recipient wrote to the sender after the
  sender's last read. The held messages are shown and marked read, so the
  next send goes through; `--anyway` skips the check.
- A send wakes only the graff sessions that hear it, over their Accord
  socket. Oversize lines are replaced by a small marker, because a wake needs
  only the frame kind.
- `inbox --wake` prints one line when there is mail, for agent hooks.
- Drains read only the bytes after their offset, at most 1 MiB per drain. An
  unterminated line longer than that is skipped. Tail joins use `stat`.

## Consequences

External agents appear in `peer_message action=list` and can be addressed by
name. A graff session in the same worktree as an external agent now gets the
shared-tree checkpoint for it, which is the intended collision warning.
Windows is not supported yet (no parent-process walk). Cross-device rooms are
a separate decision.
