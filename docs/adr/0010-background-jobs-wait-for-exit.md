# 0010. Background jobs wait for exit, not a 30s model poll

Status: accepted 2026-08-19

## Context

Trajectory `69cb38abee9714e3` (2026-08-19, `gpt-5.6-sol` / Codex / high)
waited on `gh run watch` by calling `bash_output(wait_ms=30000)` in a
loop. 199 of 203 of those calls were followed immediately by another
API hop. Turn 1 spent 24.5 minutes inside `bash_output` and 32 minutes
in the model — 328 calls, then `UnknownHostName`.

`wait_ms` was capped at 30s and returned on *new output or exit*.
`gh run watch` is chatty, so even a longer cap would still bounce.

[xai-org/grok-build](https://github.com/xai-org/grok-build) waits for
**completion** inside `get_command_or_subagent_output(timeout_ms)` (10h
ceiling) and wakes once on exit. It does not put the model in the wait.

## Decision

- `bash_output` / `agent_output` with `wait_ms = 0` is a snapshot.
- `wait_ms > 0` blocks until the job/agent **exits** (or Esc), not
  until the next byte of output.
- The old 1–30000 poll values are promoted to the 10-hour cap so a
  model that still writes `wait_ms=30000` waits for done.
- An explicit `wait_ms > 30000` is honored, clamped to 10 hours.
- Do not poll in a loop. One wait covers exit.

## Consequences

A 20-minute CI watch is one tool call, not ~40 model completions.
A snapshot (`wait_ms` omitted/0) still returns immediately. A model
that wanted "wake me every 30s of silence" can no longer do that
through `wait_ms=30000`; that was the measured failure mode.
Idle auto-wake (grok-build's `maybe_drain_notifications`) is a
follow-up: the in-turn wait is the tax we measured.
