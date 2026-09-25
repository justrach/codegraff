# Effort selection lifecycle

`EffortSelection.tla` abstracts one agent's pending effort choice. A worker
may finish after cancellation or a manual change; the owner alone can apply a
choice at the next request boundary or normal turn exit. This models the
optional effort selector in ADR 0193 and the shared session setting in ADR
0191. It does not model a general judgment tool.

| Model action or state | Implementation |
| --- | --- |
| `Begin`, `phase`, `gen`, `pendingRoute` | `Pending.begin` in `src/jev_effort_state.zig` admits only an idle slot, increments its token, and copies the provider/model. `jev_tool.execute` calls it after input and eligibility checks. |
| `Complete` | `jev_tool.selectedEffort` parses a choice and checks `effort_route.allows`; `Pending.commit` accepts it only while in flight and only for the current token. The model's `selectionOrigin` is ghost state that exposes which worker supplied a choice. |
| `Abort` | `jev_tool.execute` defers `Pending.abort`; a failed or invalid response clears only its own in-flight admission. |
| `Invalidate` | `Pending.invalidate` increments the token and clears the slot. Callers include `commands_effort.zig` and `acp_config.zig` for manual effort, `jev_tool.updateProvider` for route changes, `agent_request.zig` and `jev_effort_state.finishTurn` for cancellation, and `Agent.runTurn` error cleanup. The outstanding worker remains in the model so a late completion is explored. |
| `OwnerBoundary` | `jev_effort_state.take` consumes a selection and checks the copied route; `applyToState` checks the current allowlist before changing `agent.reasoning`. `agent_request.request` calls `apply` at the next request boundary; `finishTurn` calls it on normal exit. |
| `Levels`, `Eligible` | Abstract finite classes of `effort_route.levels/allows` and `jev_model_scope.eligible`. Two routes share a multi-level allowlist, one route has a binary allowlist, and one is ineligible. Their names deliberately carry no provider or model identity. |

The normal configuration bounds the generation to 3. That is enough to
explore admission, invalidation, readmission, and completion from the first
worker after the newer admission. `SelectedOriginIsCurrent` checks the
selected worker's generation. `ActiveAdmissionIsCurrent` and the guarded
`Begin` action capture first-admission ownership of the slot.
`ManualWins` ensures a manual change cannot be overwritten by an older
worker; a fresh admitted choice may supersede it. `OwnerOnlyWritesEffort`
compares a ghost owner copy as an abstraction sanity check. Owner-thread
confinement is assumed by the modeled owner actions and the worker actions'
`UNCHANGED` clauses; this equality does not independently establish that the
implementation confines writes to its owner. `AllowedJevApplication` checks
the route's allowlist at application.

`SelectedEventuallyConsumed` is checked only with weak fairness for
`OwnerBoundary`: if a selection remains pending, the owner eventually reaches
a request boundary or normal exit. Cancellation or an error may instead clear
it. This is a conditional scheduling assumption, not a claim that every
process run finishes. TLC uses `-deadlock` because the finite generation
bound intentionally creates terminal states.

`EffortSelectionStale.cfg` changes one rule: `Complete` ignores the token
equality check in `Pending.commit`. TLC then finds a trace in which token 1
begins, invalidation advances the generation, token 3 begins, and token 1's
late completion fills the selected slot. `SelectedOriginIsCurrent` fails.
This mutation checks that the invariant has discriminatory power; it is not
an implementation defect.

The model treats each mutex operation as atomic and interleaves the worker and
owner actions. It omits token wraparound, byte limits, allocator failures,
parser details, network behavior, persistence, notifications, and multiple
agents. Its static route classes mean a route change invalidates the pending
slot before `take`; the route and allowlist checks remain modeled but their
rejection branch is defensive under the current call paths. Passing TLC
establishes these finite-model properties, not refinement of the Zig code.
