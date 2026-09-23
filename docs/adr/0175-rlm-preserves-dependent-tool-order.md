# 0175. RLM preserves dependent tool order

Status: accepted 2026-09-23

## Context

Speculating every literal host call lets verification race ahead of an edit.
A failed edit can then leave later side effects behind. Nested host calls also
need to retain errors, cancellation, and pending status in the outer result.

## Decision

Only a leading sequence of explicitly read-only host calls may overlap or start
while source streams. The first other statement closes that speculation window
for the rest of the script, including subsequent streamed chunks. Shell calls,
mutations, and unknown external tools execute in statement order.

Discard speculative result reuse at that boundary. Repeated mutations execute
each time, and reads after mutations obtain fresh results. Previously assigned
bindings retain their original values.

Stop evaluation on a failed, cancelled, or pending host result and preserve its
status in the outer result, including calls inside `print` and `each`. Record
each executed host result once at execution, rather than replaying observations
from a cache.

## Consequences

Independent leading reads still overlap. Shell and external calls lose implicit
speculative parallelism; expanding the allowlist requires a verified read-only
contract. `src/rlm_order_tests.zig` covers ordered edits, stopped evaluation,
fresh reads, repeated writes, and the streaming boundary.
