# Phase 2, slice 1: Dynamic escalation / de-escalation (design)

Working note, not committed. First slice of vision.md Phase 2 (the Smart
Router). Scope: failure-triggered tier promotion at subagent boundaries.
Explicitly NOT in this slice: mid-turn model switching, complexity
profiling, the cache-switching predictor.

## Why this slice first

- It is the smallest closed loop: run -> detect failure -> rerun one tier
  up -> score both -> emit the trace.
- It sidesteps the Cache-Switching Paradox entirely. A subagent respawn is
  a fresh context anyway, so there is no cache momentum to lose. Mid-turn
  switching (the hard economic problem) waits until we have data.
- Its traces ARE the training data for the rest of Phase 2. The predictor
  needs (task, tier, outcome, cost) tuples; nothing produces those today.

## What exists to build on (all in src/main.zig unless noted)

| piece | where | role in this slice |
|---|---|---|
| `runSub(ctx, kind, label, prompt, sys_override, niche)` | ~L15900 | the seam: every subagent + workflow task passes through it |
| `providerClass(model)` -> frontier/mid/small | main.zig (19 refs) | the tier ladder |
| pricing catalog | `src/pricing.zig` | cost of a retry, cost delta in the trace |
| fitness scores + `scoreVariants` | main.zig | the success/failure signal for eval'd runs |
| `Telemetry.fleetEvent` (propose/submit/elite_pull) | main.zig | pattern to copy for the new `escalate` event |
| `/effort`, `/fast`, `/fleet` REPL toggles | main.zig / repl.zig | pattern for `/escalate on|off` |

## Design

### Failure signal (v1, cheap and unambiguous)

A subagent run counts as FAILED when any of:
1. the run errored (tool loop died, provider error after retries);
2. an eval/judge score exists for the run and is below `ESCALATE_FLOOR`
   (default 0.5, matches the fleet score scale);
3. the run hit the turn cap without producing a result.

No LLM-judge-of-everything in v1. If nothing scored the run and it did
not error, it is a success. Keep the signal deterministic so traces are
trustworthy.

### Escalation rule

- Ladder: small -> mid -> frontier (reuse `providerClass` ordering).
- On FAILED and tier < frontier and escalation enabled: rerun the same
  `runSub` args once at the next tier up. One rung per failure, max one
  retry per subagent (a frontier failure is just a failure).
- The rerun replaces the failed result for the caller; the failed
  attempt still scores/submits as itself (its genome earned its score).

### De-escalation rule (shadow, cheap)

- Per (niche, tier): after `DEESCALATE_STREAK` (default 5) consecutive
  successes at a tier, mark the niche "try one tier down next time".
- The downgraded run is live, not shadowed (shadowing doubles cost, which
  is the thing we are minimizing). If it fails, the escalation rule
  already catches it and the streak resets. Worst case cost = one cheap
  failed attempt + the escalated rerun.

### Telemetry: the `escalate` fleet event

New `fleetEvent` kind `escalate`, emitted on every escalation AND every
deliberate de-escalated run:

```
{ kind: "escalate", niche, from_class, to_class, reason: "error"|"score"|"cap"|"deescalate",
  failed_score, rerun_score, cost_delta_usd, ms_delta }
```

Same privacy posture as the rest of the fleet loop: no task content, no
prompt text; scores + tiers + deltas only. Backend just needs an events
passthrough (harness_events already captures unknown kinds; no migration).

### Controls

- `GRAFF_ESCALATE=off` env + `/escalate [on|off]` REPL command, mirroring
  the `/fleet` pattern. Default: ON for subagents (it only ever spends
  money to rescue a failure), OFF for de-escalation until traces say the
  streak heuristic is safe.
- Knobs as consts next to the fleet knobs: `ESCALATE_FLOOR=0.5`,
  `DEESCALATE_STREAK=5`.

## Implementation order

1. Tier ladder helper: `nextClassUp(class)` / `nextClassDown(class)` +
   pick a concrete model for a class (cheapest in class from pricing.zig;
   respects the user's provider config).
2. Wrap the `runSub` call sites (workflowTask + the Task tool path) with
   the retry-one-rung-up loop. Keep `runSub` itself untouched.
3. `fleetEvent("escalate", ...)` + the env/REPL toggles.
4. Unit tests: ladder ordering, failure classification, one-rung cap.
   E2e: extend `scripts/e2e_fleet.sh` mock to assert an escalate record
   when a forced-fail subagent reruns.
5. (later, own slice) de-escalation streak tracking, persisted per niche
   in the session state file.

## Exit criteria for the slice

- A forced-failure subagent on a small-class model visibly reruns on mid,
  the caller gets the mid result, and the collector sees one `escalate`
  record with both scores and the cost delta.
- `zig build test` green; e2e green; `GRAFF_ESCALATE=off` produces
  byte-identical behavior to today.

## What the traces unlock next

- Cache-Switching Predictor (vision.md P2): needs P(success | tier,
  niche) priors -> read them off accumulated escalate records per cell.
- Complexity profiling: label = "did small tier succeed"; the escalate
  stream is the labeled dataset, no separate collection pass.
- Intelligence arbitrage (P3): success-per-dollar per (niche, tier) falls
  out of rerun_score / cost_delta aggregation, SQL only, same
  no-central-inference rule as the DGM loop.
