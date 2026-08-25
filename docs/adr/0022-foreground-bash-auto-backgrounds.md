# 0022. Foreground bash auto-backgrounds after 120s, it is not killed

Status: accepted 2026-08-25

## Context

[#93](https://github.com/justrach/codegraff/issues/93) gave *subagent* bash a
120s kill because those children have no TTY. The root was left unbounded:
"a human is watching and may want a long build." #607 added a dim
`· bash still running ·` pulse so a long command did not *look* hung.

[#620](https://github.com/justrach/codegraff/issues/620) measured the leftover:
a durability drill sat in that pulse for 83 minutes. The model never woke.
Esc killed the process group; the model retried the same foreground hang.

[xai-org/grok-build](https://github.com/xai-org/grok-build) `BashTool` waits
120s (`timeout` default), then *promotes* a still-running command to a
background task (`auto_background_on_timeout`) and returns a job id plus
partial output. A real compile keeps running. The model gets the turn back.

## Decision

- Root foreground `bash` waits up to 120s (or `timeout` ms, capped at 10h).
- If the child is still running, it is moved onto the existing job registry.
  The model receives a job id. `bash_output` / `bash_kill` / `/jobs` work as
  they do for `run_in_background: true`. The process is not killed.
- Subagent `bash` still *kills* at 120s (#93). Children have no job UI.
- Esc during the foreground wait still kills the process group. The cancelled
  result tells the model to restart with `run_in_background: true`.
- ADR 0010 is unchanged: `bash_output(wait_ms>0)` waits for exit, not a poll.

## Consequences

A 20-minute compile or a forgotten server no longer bricks the turn. The
heartbeat (#607) still fires during the 120s wait. Root bash output that
finishes inside the wait is interleaved stdout+stderr (the job buffer),
not the old split `[stderr]` block — same shape as `bash_output`.
