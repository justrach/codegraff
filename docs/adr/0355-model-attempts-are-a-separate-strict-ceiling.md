# 0355. Request attempts are a separate, strict ceiling

Status: accepted 2026-11-27

## Context

`--max-model-calls` admits logical calls. `request()` takes one permit, and
the transport retries of that call run under it, as `RunBudget.acquire`
documents and ADR 0169 left open ("attempt" budgets remain separate). The
flag's schema text listed "retries" among what it covers, which reads as
transport retries. It meant workflow retries. With `--max-model-calls 1`, a
5xx on the only admitted call was retried under the same permit, so the
one-shot sent its body twice (#1932). The issue asked for the distinction to
be documented and for a strict ceiling, so that a one-shot can fail closed.

Counting retries inside `--max-model-calls` instead would change an existing
contract. `run_task` children (ADR 0286), the landing reserve (#390) and the
review gates all budget logical calls. A single transient flake would then
use up one of their calls.

## Decision

- `--max-model-calls N` keeps its meaning: logical calls. Its help and schema
  text now say that transport retries of an admitted call share the permit.
- `--max-model-attempts N` (default 0 = unlimited) caps provider requests
  sent, across the whole invocation. Every send draws one attempt: the first
  send and every transport retry, stream reconnect, re-anchor and
  WebSocket-to-SSE fallback. Direct compaction POSTs and `llm_query` draw one
  too, as do children, titles and judges, which share the same `RunBudget`.
  One gate does this, `Attempts.admit` in `agent_request_budget.zig`, right
  before the bytes go out. There is no special case for each retry path.
- When no attempt is left, nothing is sent. The request ends with
  `RunBudgetExhausted`, the existing budget-exhausted outcome (one-shot exit
  3, ACP `max_turn_requests`, child `model-call-budget`). The error text names
  the flag and carries the last provider error, which is the give-up copy an
  exhausted retry ladder would have printed. A retry that cannot be sent is
  refused before its backoff and its "retrying" notice.

## Consequences

A supervisor can bound what is sent, not only how many answers it asked for.
The strict ceiling also fails closed in cases the logical one does not: a
WebSocket attempt that died before its body was sent still counts. Unlimited
(0) only counts, so the default behaviour is unchanged. Guarded by the
Tier-2 cases `max-model-calls-caps-transport-attempts-1932` (the strict cap
sends exactly one request and reports the 5xx) and
`max-model-calls-retries-under-its-permit-1932` (the logical cap still
retries), and by the `run_budget.zig` test for `attemptAllowed`.
