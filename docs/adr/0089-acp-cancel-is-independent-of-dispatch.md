# 0089. ACP cancel is independent of turn dispatch

Status: accepted 2026-09-08

## Context

`graff acp` read stdin only between turns. `session/cancel` sat unread while
`session/prompt` blocked, so Stop waited for the active turn. The GUI
swallowed cancel failures and drained the follow-up queue. #791.

## Decision

A dedicated stdin reader applies `session/cancel` immediately (same
`cancel_source` / `esc_cancel` path). Prompt dispatch no longer owns the
read loop. Stop surfaces cancel errors and holds the queue. Steer is a
distinct action: cancel the live turn and continue the same session with
the next prompt.

## Consequences

Stop interrupts an in-flight child ACP turn. Queued follow-ups stay parked
until the user sends again. Steer is interrupt-and-continue, not Stop.
