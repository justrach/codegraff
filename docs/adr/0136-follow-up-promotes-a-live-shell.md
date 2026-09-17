# 0136. A follow-up promotes a live shell; it does not kill it

Status: accepted 2026-09-16

## Context

Foreground `shell` waits up to 120s (lean `-p`: 15s) before auto-background
(ADR 0026, ADR 0055). Typing during that wait queued a steer, but the wait
kept blocking, and a force-steer/Esc path killed the child. Talking to the
model meant destroying the command.

Astra `response.steer` only applies while a GPT-6 stream is live, not during
a tool wait. Jobs still ignore stdin (ADR 0134): this is not a PTY.

## Decision

If a follow-up is queued, `waitForeground` returns a running job id and
leaves the process alive. Force-steer already queued that line, so it
promotes too. A real Esc (no follow-up) still kills the tree.

The tool result tells the model the command is backgrounded because of the
follow-up. The queued line remains the next user turn.

## Consequences

You can talk while a long command runs. The model sees a job id, not a
cancel. Double-Enter force-steer no longer murders a `sleep` you wanted
kept. Esc without a queued line is still a kill.
