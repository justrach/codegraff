------------------------------ MODULE BootPrewarm ------------------------------
EXTENDS Naturals, TLC

\* A finite abstraction of the boot-thread companion prewarm (boot_prewarm.zig)
\* and of one registry start task's retry pause at teardown (mcp_start.zig).
\* The prewarm worker connects the companion before the registry exists; the
\* boot thread joins it at its one consumer (connectCompanion) or discards it.
CONSTANTS BypassJoin, BypassCwdKey, BypassTeardownJoin, BypassRetryAbort
ASSUME /\ BypassJoin \in BOOLEAN
       /\ BypassCwdKey \in BOOLEAN
       /\ BypassTeardownJoin \in BOOLEAN
       /\ BypassRetryAbort \in BOOLEAN

BootStates == {"pre", "consumer", "inline", "connected", "noConsumer", "joining", "exited"}
WorkerStates == {"none", "running", "done", "consumed"}
TaskStates == {"attempt", "pause", "retry", "done"}

VARIABLES boot, worker, result, spawned, adopted, inlined, registered,
          cwdMoved, cwdAtTake, usedEarly, ioAlive, task, abort, retriedAfterAbort

vars == <<boot, worker, result, spawned, adopted, inlined, registered,
          cwdMoved, cwdAtTake, usedEarly, ioAlive, task, abort, retriedAfterAbort>>

prewarm == <<worker, result, spawned, adopted, cwdAtTake, usedEarly>>
taskVars == <<task, retriedAfterAbort>>

\* The gate either declined (no slot) or started the worker after
\* runSubcommand; the registry's own start task is in its first attempt.
Init ==
  /\ boot = "pre"
  /\ worker \in {"none", "running"}
  /\ result = "none"
  /\ spawned = (worker = "running")
  /\ adopted = FALSE
  /\ inlined = FALSE
  /\ registered = 0
  /\ cwdMoved = FALSE
  /\ cwdAtTake = FALSE
  /\ usedEarly = FALSE
  /\ ioAlive = TRUE
  /\ task = "attempt"
  /\ abort = FALSE
  /\ retriedAfterAbort = FALSE

\* connectTask: one attempt on a task-local registry. A failure leaves no
\* process; success leaves a prewarm-owned server.
WorkerFinish ==
  /\ worker = "running" /\ ioAlive
  /\ \E r \in {"ok", "fail"}:
       /\ result' = r
       /\ spawned' = (r = "ok" /\ ~adopted)
  /\ worker' = "done"
  /\ UNCHANGED <<boot, adopted, inlined, registered, cwdMoved, cwdAtTake,
                 usedEarly, ioAlive, abort>> /\ UNCHANGED taskVars

\* -w or auto-isolation between prewarm start and the consumer.
MoveCwd ==
  /\ boot = "pre" /\ ~cwdMoved
  /\ cwdMoved' = TRUE
  /\ UNCHANGED <<boot, ioAlive, registered, inlined, abort>> /\ UNCHANGED prewarm /\ UNCHANGED taskVars

ReachConsumer ==
  /\ boot = "pre"
  /\ boot' = "consumer"
  /\ UNCHANGED <<cwdMoved, ioAlive, registered, inlined, abort>> /\ UNCHANGED prewarm /\ UNCHANGED taskVars

\* A path that exits after the registry exists without reaching the
\* consumer (--selftest-spinner); deinitAtExit discards the slot.
SkipConsumer ==
  /\ boot = "pre"
  /\ boot' = "noConsumer"
  /\ UNCHANGED <<cwdMoved, ioAlive, registered, inlined, abort>> /\ UNCHANGED prewarm /\ UNCHANGED taskVars

KeyMatches == ~cwdMoved \/ BypassCwdKey

\* take(): await, then mergeOutcomes under the registry mutex.
TakeAdopt ==
  /\ boot = "consumer" /\ KeyMatches
  /\ \/ worker = "done" /\ result = "ok"
     \/ BypassJoin /\ worker = "running"
  /\ usedEarly' = (worker = "running")
  /\ cwdAtTake' = cwdMoved
  /\ worker' = IF worker = "done" THEN "consumed" ELSE worker
  /\ adopted' = TRUE
  /\ spawned' = FALSE
  /\ registered' = registered + 1
  /\ boot' = "connected"
  /\ UNCHANGED <<result, inlined, cwdMoved, ioAlive, abort>> /\ UNCHANGED taskVars

\* A failed prewarm falls back to addServer on the boot thread.
TakeFailed ==
  /\ boot = "consumer" /\ KeyMatches
  /\ worker = "done" /\ result = "fail"
  /\ worker' = "consumed"
  /\ boot' = "inline"
  /\ UNCHANGED <<result, spawned, adopted, inlined, registered, cwdMoved,
                 cwdAtTake, usedEarly, ioAlive, abort>> /\ UNCHANGED taskVars

\* A key mismatch discards: Future.cancel is a joined operation, then the
\* server is torn down.
TakeMismatch ==
  /\ boot = "consumer" /\ ~KeyMatches
  /\ worker \in {"running", "done"}
  /\ worker' = "consumed"
  /\ spawned' = FALSE
  /\ boot' = "inline"
  /\ UNCHANGED <<result, adopted, inlined, registered, cwdMoved, cwdAtTake,
                 usedEarly, ioAlive, abort>> /\ UNCHANGED taskVars

TakeNone ==
  /\ boot = "consumer" /\ worker = "none"
  /\ boot' = "inline"
  /\ UNCHANGED <<cwdMoved, ioAlive, registered, inlined, abort>> /\ UNCHANGED prewarm /\ UNCHANGED taskVars

InlineConnect ==
  /\ boot = "inline"
  /\ \E ok \in BOOLEAN: registered' = registered + (IF ok THEN 1 ELSE 0)
  /\ inlined' = TRUE
  /\ boot' = "connected"
  /\ UNCHANGED <<cwdMoved, ioAlive, abort>> /\ UNCHANGED prewarm /\ UNCHANGED taskVars

\* deinitAtExit: discard any unadopted prewarm (cancel + join), then
\* Registry.deinit sets retry_abort and joins its start tasks.
Teardown ==
  /\ boot \in {"connected", "noConsumer"}
  /\ IF BypassTeardownJoin
       THEN UNCHANGED <<worker, spawned>>
       ELSE /\ worker' = IF worker \in {"running", "done"} THEN "consumed" ELSE worker
            /\ spawned' = FALSE
  /\ abort' = TRUE
  /\ boot' = "joining"
  /\ UNCHANGED <<result, adopted, inlined, registered, cwdMoved, cwdAtTake,
                 usedEarly, ioAlive>> /\ UNCHANGED taskVars

\* main returns; std.process.Init tears the Io down after its join.
IoDown ==
  /\ boot = "joining"
  /\ BypassTeardownJoin \/ task = "done"
  /\ ioAlive' = FALSE
  /\ boot' = "exited"
  /\ UNCHANGED <<registered, inlined, cwdMoved, abort>> /\ UNCHANGED prewarm /\ UNCHANGED taskVars

\* The registry's start task: one attempt, a transient failure pauses, and
\* the pause either times out into the one retry or ends on retry_abort.
AttemptEnds ==
  /\ task = "attempt" /\ ioAlive
  /\ task' \in {"pause", "done"}
  /\ UNCHANGED retriedAfterAbort
  /\ UNCHANGED <<boot, ioAlive, registered, inlined, cwdMoved, abort>> /\ UNCHANGED prewarm

PauseTimesOut ==
  /\ task = "pause" /\ ioAlive
  /\ ~abort \/ BypassRetryAbort
  /\ task' = "retry"
  /\ retriedAfterAbort' = abort
  /\ UNCHANGED <<boot, ioAlive, registered, inlined, cwdMoved, abort>> /\ UNCHANGED prewarm

PauseAborted ==
  /\ task = "pause" /\ abort /\ ~BypassRetryAbort
  /\ task' = "done"
  /\ UNCHANGED retriedAfterAbort
  /\ UNCHANGED <<boot, ioAlive, registered, inlined, cwdMoved, abort>> /\ UNCHANGED prewarm

RetryEnds ==
  /\ task = "retry" /\ ioAlive
  /\ task' = "done"
  /\ UNCHANGED retriedAfterAbort
  /\ UNCHANGED <<boot, ioAlive, registered, inlined, cwdMoved, abort>> /\ UNCHANGED prewarm

Next ==
  \/ WorkerFinish \/ MoveCwd \/ ReachConsumer \/ SkipConsumer
  \/ TakeAdopt \/ TakeFailed \/ TakeMismatch \/ TakeNone \/ InlineConnect
  \/ Teardown \/ IoDown
  \/ AttemptEnds \/ PauseTimesOut \/ PauseAborted \/ RetryEnds

Spec == Init /\ [][Next]_vars
        /\ WF_vars(WorkerFinish) /\ WF_vars(ReachConsumer)
        /\ WF_vars(TakeAdopt \/ TakeFailed \/ TakeMismatch \/ TakeNone \/ InlineConnect)
        /\ WF_vars(Teardown) /\ WF_vars(IoDown)
        /\ WF_vars(AttemptEnds \/ PauseTimesOut \/ PauseAborted \/ RetryEnds)

TypeOK ==
  /\ boot \in BootStates
  /\ worker \in WorkerStates
  /\ result \in {"none", "ok", "fail"}
  /\ registered \in 0..2
  /\ task \in TaskStates
  /\ {spawned, adopted, inlined, cwdMoved, cwdAtTake, usedEarly, ioAlive, abort, retriedAfterAbort} \subseteq BOOLEAN

\* The boot thread never uses the prewarm outcome before the worker ended.
JoinedBeforeUse == ~usedEarly

\* A prewarm recorded in another directory is never adopted.
NoStaleAdoption == adopted => ~cwdAtTake

\* No thread still uses the Io after it is torn down.
NoUseAfterTeardown == ~ioAlive => (worker # "running" /\ task = "done")

\* No prewarm-owned server outlives the registry teardown.
NoLeakAtExit == boot = "exited" => ~spawned

\* The companion is registered once at most: adopted or inline, never both.
AtMostOneCompanion == registered <= 1 /\ ~(adopted /\ inlined)

\* Reaching the consumer always ends adopted or with the inline connect tried.
NeverMissing == boot = "connected" => (adopted \/ inlined)

\* Once teardown signals, no retry attempt starts.
NoRetryAfterAbort == ~retriedAfterAbort

\* Under the fairness above, a started teardown finishes.
TeardownFinishes == (boot = "joining") ~> (boot = "exited")
=============================================================================
