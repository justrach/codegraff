# 0048. Resume branches have independent durable identity

Status: accepted 2026-08-30

## Context

Issue #689 reproduced silent loss when two processes resumed one session name.
The advisory writer lock serialized individual whole-file replacements, but it
could not turn two descendants into independent tips. It also exposed that the
fullscreen ACP-backed TUI rendered an empty conversation after startup resume
and bypassed the root final-save path.

Provider-native tool/reasoning blocks and compaction boundaries make merging two
message arrays unsafe. A process-lifetime source lock would avoid corruption by
rejecting the second user, but would not provide the requested branch behavior.

## Decision

`--resume SOURCE --branch DESTINATION` and
`/resume SOURCE --branch DESTINATION` clone SOURCE once into a new durable
identity. DESTINATION must be new and distinct from SOURCE; creation uses an
exclusive filesystem claim so two processes cannot both win a previously
unused name. Future turns, transcripts, checkpoints, compaction, and shutdown
saves target only DESTINATION; the session header records `parent: SOURCE` and
the branch receives a fresh persisted cache/session UUID.

The fullscreen TUI, TTY `graff repl`, scripted `graff repl`, and ACP startup all
consume the same restored provider-native history. The fullscreen frontend also
projects that history into visible rows and syncs its engine-owned conversation
back to the root before final save.

A branch copies ADR 0014's peer cursor and unread inbox snapshot exactly once as
part of the session snapshot. Parent and child then persist their cursors
independently; neither replays the room and neither shares mutable inbox state.
Git worktree isolation remains a separate choice.

## Consequences

Concurrent continuations need distinct destination names, which keeps conflicts
explicit and makes reopening deterministic. Existing `/resume SOURCE` remains a
same-tip continuation for compatibility and is not safe as a branching command.
There is no automatic merge; future merge/cherry-pick work must understand
provider-native history rather than appending JSON arrays.
