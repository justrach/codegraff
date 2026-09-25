# Further lifecycle formalization

This is a ranked plan, not a list of proved properties. Add a model only when
its state transitions can be mapped to implementation boundaries and a negative
control can demonstrate that its invariants detect the intended mistake.

| Priority | Lifecycle | Properties to check | Implementation anchors |
| --- | --- | --- | --- |
| 1 | ACP permissions | Only a pending request on the owning live transport accepts an offered option; stale or duplicate replies cannot grant; cancellation denies pending input. | `src/acp_permission.zig`, `apps/native/lib/acp-transport.ts`, ADR 0180 |
| 2 | HTTP/2 lease ownership | A connection has at most one active owner; idle and leased sets are disjoint; cancellation closes only its lease; only completed streams return to the idle slot. | `src/http2_pool.zig`, `src/agent_stream_h2.zig`, ADR 0162 |
| 3 | Retry and usage accounting | An ambiguous send cannot silently fall back; every retry crosses request admission; an unresolved attempt remains unknown after later success; cleanup cannot count it twice. | `src/agent_request.zig`, `src/request_usage_attempts.zig`, ADR 0183 |
| 4 | Shared descendant budgets | Concurrent tool reservations cannot exceed a finite limit; failed tools still consume admission; each concurrency permit releases once; cancellation can retire a waiter. | `src/run_budget.zig`, ADR 0169 |
| 5 | Session configuration and restore | A setting received during a turn applies at the boundary; a delayed response cannot change another session; restoring history cannot execute saved tools again. | `src/acp_config.zig`, ADRs 0181 and 0191 |

## What makes the next models useful

Use at least two actors where ownership matters. For permissions, include two
transport generations with a repeated server request ID: proving uniqueness
only within one process misses the frontend replacement hazard. Model delivery
and cancellation as separate steps so their ordering is explored.

For HTTP/2, include two concurrent requests, two origins, an occupied idle slot,
and shutdown while another lease is active. Do not assume shared connection
multiplexing: the implementation deliberately uses exclusive leases. A model
must distinguish connection ownership from request success.

For retries, distinguish failures before send, proven-unprocessed requests and
ambiguous delivery. Remote exactly-once execution is not a property the harness
promises. Correctness means that retry policy and uncertainty accounting see
every ambiguous attempt, including when a later retry succeeds.

Budget liveness needs explicit environmental assumptions. A concurrency bound
does not prove that a remote call terminates or that every waiter is scheduled.
Model call limits separately from concurrency and tool-call limits.

## DGM admission

The existing `examples/dgm_loop.py` evolves prompt genomes. A formal gate can
validate the pinned harness baseline used for evaluation, but cannot certify
that a generated prompt obeys its instructions. Keep deterministic held-out
tests as the prompt correctness gate. Formal failure must prevent promotion;
formal success must not add fitness points.

For future harness-source evolution, model each changed lifecycle and bind the
check receipt to that candidate source, checker, configuration and executable.
A separate promotion-state model could check that no stale or missing formal
receipt, failed replay, or changed candidate can reach the passing score band.
That model would describe admission policy, not prove the underlying evaluator
or model implementation trustworthy.

## Closing the gap to code

Each model should ship with a source mapping, finite bounds, safety invariants,
explicit fairness assumptions for any liveness property, and targeted broken
variants. Counterexample traces should become deterministic runtime regression
scenarios where practical. Keep parser, allocator, socket and frontend delivery
tests: the model abstracts these mechanisms rather than verifying them.

After the models stabilize, add a separate pinned-toolchain CI job for changes
to the modeled source paths and formal files. A green Zig test job alone does
not establish that TLC ran. A future trace-conformance checker could compare
sanitized runtime state transitions to allowed model actions; it would improve
implementation evidence but would still not establish an unbounded refinement
proof. Do not export private traces to the public tracker.
