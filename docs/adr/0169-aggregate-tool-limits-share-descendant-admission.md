# 0169. Aggregate tool limits share descendant admission

Status: accepted 2026-09-23

## Context

The existing `--max-tool-calls` control limits root tool calls per turn.
Nested work and code-mode host calls could continue dispatching after that
local allowance. A separate invocation ceiling must reserve before effects,
including parallel calls, without silently changing the existing control.

## Decision

`--max-run-tool-calls N` sets an optional shared invocation-wide tool ceiling.
Zero denies every tool dispatch; omission preserves interactive behavior.
Root meta tools and external dispatch (including descendant and MCP calls)
reserve from the same atomic counter. Code-mode sleep/query host functions
also reserve. Failed dispatches retain their reservation. Once a reservation
is refused, later model admissions stop with `ToolBudgetExhausted`.

The refusal and trace record `exhausted`, dimension `tool_calls`, used and
limit. Existing in-flight work is allowed to finish; this is admission
control, not a promise to undo or preempt admitted effects. Model-backed
code-mode queries also acquire the existing shared model-call permit.

## Consequences

This closes aggregate tool-admission and code-mode model-call bypasses, but
does not claim full governed-run budgets: token, spend, attempt, deadline,
active-work cancellation and persisted governed defaults remain separate.
`run_budget.zig` tests atomic fan-out and blocked real file dispatch;
`scripts/test-run-tool-budget.py` runs an endlessly requesting local mock
against the real harness and proves termination at the configured ceiling.
