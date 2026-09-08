# 0088. Failed children return partial evidence

Status: accepted

## Context

A child can read files or produce findings before its next model request fails.
The failure return previously preserved the error and worktree location but
omitted that evidence. A parent could not summarize useful partial work, and
workflow failure excerpts retained only the cause.

## Decision

Keep the result marked as an error and append bounded, explicitly incomplete
evidence from assistant text, tool results, and the interrupted response.
Exclude user instructions and reasoning blocks. Prefer recent history, cap each
excerpt and the total evidence, and disclose truncation. Workflow synthesis
retains a small evidence excerpt alongside its existing failure-cause excerpt.
The parent must distinguish reported findings, observed tool results, and work
still requiring verification. No additional model call is needed for recovery.

## Consequences

Failure still controls retry and completion status. Partial output is not proof
of a successful task. Evidence is limited to retained history and the current
interrupted response; it is not a complete audit trail. Empty recovery returns
only the original failure. A scripted budget-exhaustion case proves that an
actual failed child returns its earlier file-read result to the parent.
