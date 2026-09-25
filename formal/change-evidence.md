# Making behavioral changes reviewable

A Git diff shows edited text. A lifecycle model states which behaviors that edit
allows or forbids across concurrent events. Neither replaces evidence from the
running implementation.

For each behavioral change, retain this chain:

1. **Source revision and rule.** Identify the exact before/after code and the
   changed transition or guard. Do not silently replace the historical code with
   a hypothetical broken version.
2. **Model difference.** Show the corresponding before/after action, invariant
   and explicit environment assumptions. Record finite bounds for both checks.
3. **Counterexample or check result.** When an invariant fails, describe the
   shortest useful sequence of actions. When it passes, state only the bounded
   properties checked; a state count is not a coverage percentage.
4. **Runtime scenario.** Exercise that sequence through the corresponding code
   path. Ideally the regression test fails on the actual old revision and passes
   on the new one. A test that only inspects source text is weaker evidence.
5. **Outcome evidence.** Separately measure any claimed performance improvement.
   Correctness model checks establish no wall-time, token, caching or cost win.

## Existing connections

| Behavioral rule | Formal check | Existing runtime regression anchor |
| --- | --- | --- |
| An old effort worker cannot fill a newer admission | `SelectedOriginIsCurrent` | `src/jev_effort_state.zig`: `pending effort is per agent, first admission wins, and stale routes or tokens do not apply` |
| A repeated tool ID must not execute twice | `AtMostOnceExecution` | `src/agent_async_tools.zig`: `async tools complete call dispatches once in headless mode and claims once` |
| A synchronous predecessor stops early admission | `NoLateAdmission` | `src/agent_async_tools.zig`: `async tools do not cross a synchronous predecessor or execute partial arguments` |
| Owned workers retire before their storage is freed | Async cancellation/reset model | `src/agent_async_tools.zig`: `async tools reset cancels and joins workers before freeing owned state` |
| Permission replies belong to their live transport and session | ACP permission extension | `apps/native/lib/acp-permission.test.ts`: `permission replies bind process, session, original ID and offered option exactly once` |

These anchors connect intent and implementation tests. They do not establish
that every modeled interleaving is exercised by a runtime test, or that the
implementation refines the model. Inspect and run the relevant tests when the
mapped code changes.

## Negative controls are not historical regressions

The existing `*Stale` and `*No*` configurations deliberately remove guards from
the model. Their counterexamples establish that the invariant detects that
mistake. They do **not** by themselves show that a historical release contained
it. Describe those results as mutation checks unless an actual earlier source
revision and failing runtime test support the historical claim.

A future change report should explicitly mark its evidence level: model only,
model plus current runtime test, or before/after source with a runtime regression
reproduced on both revisions. Missing evidence stays missing; do not turn a
plausible source mapping into a claim of proof.
