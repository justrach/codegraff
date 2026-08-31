# yxlyx leftovers (279 continuation)

What still exists in this repo versus what is parked. No new product mode.

Landed on [v0.0.282](releases/v0.0.282.md): `#674` atomic paste spans,
`#693` Codex WS `type:error`, `#694` HTTP client generations (ADR 0048),
`#697` clone-on-write session branches (ADR 0049; `#698` was a yxlyx reopen
of the same head and is closed as duplicate), `#679` MCP TLS reuse
(ADR 0050), `#695` omit an empty tool catalog, `#677` `/teleport` +
`/snapshot gc` (ADR 0051), `#675` DeepSeek thinking-off / lean 15s bash
(ADR 0052–0055). Still parked below.

| Issue | In this repo today | This cut |
| --- | --- | --- |
| [#321](https://github.com/justrach/codegraff/issues/321) `/doctor` | Goal/todo slice plus the live job table and `RunBudget`: `JOB_STATE`, `JOB_SHARES_ROOT_PGID`, `BUDGET_STATE`, `BUDGET_NEAR_LIMIT`, `BUDGET_EXCEEDED`. TUI `/doctor` uses the same report (no chrome-only "ok" line). | Partial. **Parked:** durable session-lease, listener, and orphan-descendant findings (`DUPLICATE_WORKTREE_OWNER`, `STALE_SESSION_LEASE`, `ORPHANED_OWNED_JOB`, `LISTENER_AFTER_CLEANUP`). Those need a registry that does not exist; doctor still refuses to fake them. |
| [#217](https://github.com/justrach/codegraff/issues/217) governed run budget | `src/run_budget.zig`: invocation-wide `--max-model-calls` (default unlimited), concurrency 8, depth 1. Charged across root / children / title / judges / compaction. Exhaustion is a structured stop, not a model plea. `--max-tool-calls` is still root-only. | Partial. **Parked:** finite defaults for `/goal`/`/loop`, wall-time, token, and USD ceilings, descendant tool accounting, slash widening-with-approval. |
| [#220](https://github.com/justrach/codegraff/issues/220) protected verifiers | `--eval` / `--until` scores a command the agent can invoke. ADR [0008](adr/0008-synthetic-evals-use-external-verifiers.md) is the eval-suite rule, not a `/goal` acceptance contract. | **Parked.** Independent verifier stages and hidden tests are a new controller, not a docs tweak. |
| [#306](https://github.com/justrach/codegraff/issues/306) review runaway | Same budget knobs as #217. `/review` is one isolated pass (catalog). No review-specific cycle cap or "confirm before implementing" gate. | **Parked** on the #217 remainder. |
| [#283](https://github.com/justrach/codegraff/issues/283) cube NDJSON buffer | `graff serve` already emits NDJSON as events happen. The failure is Daytona preview buffering the response and iOS `URLSession` idling out. `graff cube` / `src/cube.zig` is the sandbox+serve CLI. | **Parked** (ingress + iOS client). Not a new harness mode. |
| [#199](https://github.com/justrach/codegraff/issues/199) idle localhost servers | No `graff processes` / idle supervisor. Jobs exist for tool-started bash; they do not pause forgotten `next dev` trees. PR #200 closed as abandoned vs tip. | **Parked.** Do not start a process-supervisor product on this branch. |
| [#106](https://github.com/justrach/codegraff/issues/106) representative Ultracode sims | Unit suite + `TUI/sim.zig` Term + tier-2 harness cases. Not a multi-turn human Ultracode drama. | **Parked** (eval/tier-2 work, not 279 continuation). |

#218 / #219 (siblings under #216 governed runs) follow #217/#220: do not open a second budget product here.

## Cheap truth

The leftover that already lives as product is `/doctor`: goal/todo plus the
live in-process job table and `RunBudget` (`JOB_STATE`, `JOB_SHARES_ROOT_PGID`,
`BUDGET_STATE`, `BUDGET_NEAR_LIMIT`, `BUDGET_EXCEEDED`). Line REPL and TUI
share that report. Everything else is another surface (Daytona, iOS, a
durable lease/listener/orphan registry) or a new mode (idle-server
supervisor, protected verifier, review cycle cap).
