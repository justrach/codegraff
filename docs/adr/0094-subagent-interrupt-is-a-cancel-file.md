# 0094. Sub-agent interrupt is a cancel file, not session/cancel

Status: accepted

## Context

The GUI inspects children through a dedicated observer process (ADR 0082).
That observer cannot set the live `Agent.esc_cancel` flag, and `session/cancel`
would stop the parent turn. There is still no cheap mid-request abort of an
in-flight child (see `agentJobsReap`).

## Decision

`graff/agents` action `cancel` writes `{id}.cancel` in the parent's activity
directory after the same parent/workspace checks as `activity`. The child
honors the file at start, on the next activity emit, and at `finish` — even
if the model later returns a report, the snapshot is failed/`Interrupted.`.

The GUI Stop control uses this action. It does not send a peer message.

## Consequences

Stop is cross-process and parent-safe. An in-flight HTTP body may finish
before the next emit; the published status is still interrupted.
