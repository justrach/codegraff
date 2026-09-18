# 0117. Goal status survives compaction without reauthorizing work

Status: accepted 2026-09-15

## Context

The compaction snapshot retained a goal's objective but omitted its status
and whether it was a task or standing policy. With no checklist it instructed
the model to plan the work even when the goal was paused or complete.
Separately, prefix matching interpreted `/goals` as `/goal s` in the line REPL.

## Decision

Keep objective, lifecycle status, and task-versus-standing kind together in
the harness-owned compaction snapshot. Inactive goals explicitly require a
new user request before work resumes; their retained checklist is reference,
not authorization. Preserve the existing checklist cap and change-only
steering rule from ADR 0005. Do not change goal state during compaction.

Match `/goal` at a command boundary, accepting whitespace-delimited arguments.
`/goals` is read-only status on both terminal command surfaces and is advertised
in the shared command catalog. It never creates or replaces an objective, even
when followed by text. Graff still has one current goal per session.

## Consequences

Pause and completion remain meaningful after context rewriting. The status
alias cannot accidentally supersede work. This does not add a multi-goal queue
or alter completion verification, run budgets, or standing-policy semantics.

Regression coverage lives in `goal_persist_tests.zig`,
`commands_session_test.zig`, and the TUI command-dispatch tests. Offline tier-2
cases `goal-paused-survives-compaction` and
`goal-complete-survives-compaction` inspect the actual request after compaction.
