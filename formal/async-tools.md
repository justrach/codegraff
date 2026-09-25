# Owned asynchronous tool lifecycle

`AsyncTools.tla` is a finite model of the early execution path described by
[ADR 0177](../docs/adr/0177-owned-async-tool-execution.md). It uses two original
call IDs and explores arbitrary interleavings of stream events, worker
completion, response assembly, cancellation, and owner-thread consumption.
The IDs are deliberately distinct; repeating an ID models duplicate stream or
final-response items. The model is about lifecycle and ordering, not tool
content or transport bytes.

| Model action | Implementation boundary |
| --- | --- |
| `Partial`, `CompleteEligible`, `SynchronousPredecessor`, `HostedDiscovery` | `agent_stream.zig` passes each line to `agent_async_tools.onLine`; `onEvent` ignores incomplete items, admits only complete eligible async calls, deduplicates `call_id`, closes its barrier on an unknown/synchronous predecessor, and exempts hosted discovery. |
| `WorkerDone`, `Join` | `agent_async_tools.execute` publishes a completed result; `join` awaits owned futures before the successful Responses request returns in `agent_request.zig`. |
| `HistoryItem`, `Deliver` | `agent_steps.stepResponses` calls `duplicateItem` before appending a final item; `agent_tools.runTools` calls `claim`, whose cached result is returned for repeated invocations; the tool result message uses the original call ID. |
| `NextRequest` | `agent_request.request` joins before returning a response; `stepResponses` consumes and appends results before the model loop can request again. |
| `TransportFailure`, `Fallback`, `Cancel`, `CancelAndReset` | `agent_request.request` rejects retry/rebuild after `started`; `agent_async_tools.reset` cancels and joins futures before destroying owned storage and closes announced UI entries. `agent.runTurn` defers reset. |

The baseline checks single execution and history inclusion per original ID,
single result delivery, no admission after the first barrier, no next request
before every admitted job is joined and delivered, no live worker after reset,
and no fallback after admission. `admittedAtBarrier` snapshots the actual
admitted set when the barrier closes: `NoLateAdmission` would fail if the
barrier guard were removed. The next-request invariant checks live state,
not a counter recording whether a join was called. Repeated `claim()` calls
are valid because they return the cached result; no invariant prohibits them.

Weak fairness for worker completion, owner join, history assembly, delivery,
and next request gives `NormalEventuallyDelivers`: a completed response with
admitted work eventually delivers its result or is cancelled. This is a
conditional scheduling argument. It does not assert that external tool work
terminates, that a network response arrives, or that cancellation always
occurs. `CancelAndReset` models `Future.cancel` as a joined operation, matching
its required contract; TLC does not prove that Zig's runtime implements it.

Run TLC from `formal/` with `-deadlock`, since an ended turn is an expected
terminal state. `AsyncTools.cfg` is the positive model. The negative configs
each switch off one guard and must produce the named counterexample:

| Config | Deliberate mutation | Violated invariant |
| --- | --- | --- |
| `AsyncToolsNoJoin.cfg` | Allow the next request before owned work joins | `JoinedBeforeNextRequest` |
| `AsyncToolsNoDedup.cfg` | Admit a repeated original ID | `AtMostOnceExecution` |
| `AsyncToolsNoBarrier.cfg` | Admit a later call after a synchronous predecessor | `NoLateAdmission` |

The finite abstraction admits any two eligible read-only calls and does not
encode the full tool allowlist, argument parsing, user approval, rate limits,
UI timing, network failure classifications, or the separate RLM path. Local
admission denial and failed worker creation are omitted: the concrete code
keeps an owned job with a ready error result and no worker in those cases.
The model does not establish a refinement proof from Zig to TLA+.
Implementation tests and transport fixtures remain necessary.
