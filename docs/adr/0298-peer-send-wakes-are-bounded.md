# 0298. A `graff peer send` wake is bounded; the durable post is the delivery

Status: accepted 2026-10-22

## Context

`graff peer send` appends the message to the JSONL room (ADR 0134), then wakes
each eligible live session over its Accord socket. The wake ran one
`accord.Session` per recipient, in turn, with no deadline. A recipient whose
socket the kernel accepted but that never answered blocked `Session.start`
on the preface read forever; one that answered and then stopped reading
blocked `Session.send` once the frame outgrew the socket buffer. The command
never returned, and the agent turn that ran it stayed working (#1718).

## Decision

- The CLI wake (`peer_wake.zig`) runs the client half of the Accord
  handshake itself (preface out, preface in, one `msg` frame) on nonblocking
  sockets, every recipient at once in one `poll` loop, under one shared
  deadline (`peer_wake.default_deadline_ms`, 2 s). No reader thread is
  started, so teardown is a `close` and cannot wait on a blocked read.
- A recipient that refuses, fails, or has not taken the frame by the deadline
  is counted as missed. The send still succeeds: the room post is the
  delivery, and the command prints how many were not reachable live.

## Consequences

One stalled recipient costs at most the deadline, and N of them cost the
same single deadline, not N. A healthy recipient listed after stalled ones is
still woken. The in-process `presence_accord` fan-out keeps its standing
sessions and is not changed here.
