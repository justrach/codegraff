------------------------------ MODULE BootPrewarm ------------------------------
EXTENDS Naturals, TLC

\* A finite abstraction of the one-shot companion prewarm (boot_prewarm.zig)
\* and of one registry start task's retry pause at teardown (mcp_start.zig).
\* The prewarm worker connects the companion before the registry exists; the
\* boot thread joins it at its one consumer (connectCompanion) or discards it
\* (stop the worker's child, then join). Boot can also leave early: a fatal
\* exit while resolving credentials or in the banner (no defer runs), or an
\* error return between the prewarm start and the registry (main's deferred
\* discard runs, then std.process.Init joins the remaining workers).
CONSTANTS BypassJoin, BypassCwdKey, BypassTeardownJoin, BypassRetryAbort,
          StartBeforeKeys, BypassWindowDiscard, BypassStop, RetryFailed
ASSUME /\ BypassJoin \in BOOLEAN
       /\ BypassCwdKey \in BOOLEAN
       /\ BypassTeardownJoin \in BOOLEAN
       /\ BypassRetryAbort \in BOOLEAN
       /\ StartBeforeKeys \in BOOLEAN
       /\ BypassWindowDiscard \in BOOLEAN
       /\ BypassStop \in BOOLEAN
       /\ RetryFailed \in BOOLEAN

BootStates == {"keys", "banner", "start", "window", "pre", "consumer", "mismatch",
               "inline", "connected", "noConsumer", "discarding", "joining", "exited"}
WorkerStates == {"none", "running", "done", "consumed"}
\* The companion process the prewarm spawned: owned by the worker or its
\* outcome ("alive"), adopted by the registry ("registry"), or reaped.
ChildStates == {"none", "alive", "registry", "reaped"}
TaskStates == {"idle", "attempt", "pause", "retry", "done"}

VARIABLES boot, worker, result, child, hangs, stopReq, stalled, adopted,
          inlined, taken, registered, cwdMoved, cwdAtTake, usedEarly, ioAlive,
          regUp, task, abort, retriedAfterAbort

vars == <<boot, worker, result, child, hangs, stopReq, stalled, adopted,
          inlined, taken, registered, cwdMoved, cwdAtTake, usedEarly, ioAlive,
          regUp, task, abort, retriedAfterAbort>>

prewarm == <<worker, result, child, stopReq, stalled, adopted, taken, cwdAtTake, usedEarly>>
taskVars == <<task, retriedAfterAbort>>
others == <<hangs, inlined, registered, cwdMoved, ioAlive, regUp, abort>>

\* `hangs`: a companion that never answers its handshake (only the 15 s
\* handshake timeout, or the discard's stop, ends the attempt). With
\* StartBeforeKeys the gate ran before credentials, as it once did.
Init ==
  /\ boot = "keys"
  /\ worker \in IF StartBeforeKeys THEN {"none", "running"} ELSE {"none"}
  /\ child = IF worker = "running" THEN "alive" ELSE "none"
  /\ hangs \in BOOLEAN
  /\ result = "none"
  /\ stopReq = FALSE
  /\ stalled = FALSE
  /\ adopted = FALSE
  /\ inlined = FALSE
  /\ taken = FALSE
  /\ registered = 0
  /\ cwdMoved = FALSE
  /\ cwdAtTake = FALSE
  /\ usedEarly = FALSE
  /\ ioAlive = TRUE
  /\ regUp = FALSE
  /\ task = "idle"
  /\ abort = FALSE
  /\ retriedAfterAbort = FALSE

\* ---------------------------------------------------------------- boot

KeysOk ==
  /\ boot = "keys" /\ boot' = "banner"
  /\ UNCHANGED prewarm /\ UNCHANGED others /\ UNCHANGED taskVars

\* resolveKeys or setupWorktreeAndBanner exits through std.process.fatal:
\* no defer runs, no worker is joined, a spawned child is left behind.
FatalExit ==
  /\ boot \in {"keys", "banner"} /\ boot' = "exited"
  /\ UNCHANGED prewarm /\ UNCHANGED others /\ UNCHANGED taskVars

BannerOk ==
  /\ boot = "banner" /\ boot' = "start"
  /\ UNCHANGED prewarm /\ UNCHANGED others /\ UNCHANGED taskVars

\* main: startCompanion (the gate declines or starts the worker, which
\* spawns the child), then `defer discard`.
Start ==
  /\ boot = "start" /\ boot' = "window"
  /\ IF StartBeforeKeys
       THEN UNCHANGED <<worker, child>>
       ELSE \E w \in {"none", "running"}:
              /\ worker' = w
              /\ child' = IF w = "running" THEN "alive" ELSE "none"
  /\ UNCHANGED <<result, stopReq, stalled, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

\* A failed `try` before initRegistryConsent returns: the deferred discard
\* stops and joins the worker.
WindowError ==
  /\ boot = "window"
  /\ IF BypassWindowDiscard
       THEN boot' = "joining" /\ UNCHANGED stopReq
       ELSE boot' = "discarding" /\ stopReq' = ~BypassStop
  /\ UNCHANGED <<worker, result, child, stalled, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

\* initRegistryConsent returned; `defer registry_storage.deinitAtExit()`.
RegistryUp ==
  /\ boot = "window" /\ boot' = "pre"
  /\ regUp' = TRUE /\ task' = "attempt"
  /\ UNCHANGED prewarm
  /\ UNCHANGED <<hangs, inlined, registered, cwdMoved, ioAlive, abort, retriedAfterAbort>>

\* Any chdir between the prewarm start and the consumer.
MoveCwd ==
  /\ boot \in {"window", "pre"} /\ ~cwdMoved
  /\ cwdMoved' = TRUE
  /\ UNCHANGED <<boot, hangs, inlined, registered, ioAlive, regUp, abort>>
  /\ UNCHANGED prewarm /\ UNCHANGED taskVars

ReachConsumer ==
  /\ boot = "pre" /\ boot' = "consumer"
  /\ UNCHANGED prewarm /\ UNCHANGED others /\ UNCHANGED taskVars

\* A path that exits after the registry exists without reaching the
\* consumer (--selftest-spinner); deinitAtExit discards the slot.
SkipConsumer ==
  /\ boot = "pre" /\ boot' = "noConsumer"
  /\ UNCHANGED prewarm /\ UNCHANGED others /\ UNCHANGED taskVars

\* ---------------------------------------------------------------- worker

\* connectTask: one startServer on a task-local registry. A failure reaps
\* its child; success hands the child to the outcome. A stopped child ends
\* the handshake at once.
WorkerFinish ==
  /\ worker = "running" /\ ioAlive /\ boot # "exited"
  /\ ~hangs \/ stopReq
  /\ \E r \in {"ok", "fail"}:
       /\ result' = r
       /\ child' = IF r = "ok" THEN "alive" ELSE "reaped"
  /\ worker' = "done"
  /\ UNCHANGED <<boot, stopReq, stalled, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

\* A silent companion's attempt ends only at the handshake timeout; an exit
\* path that waits for it has stalled.
WorkerTimeout ==
  /\ worker = "running" /\ ioAlive /\ boot # "exited"
  /\ hangs /\ ~stopReq
  /\ result' = "fail" /\ child' = "reaped" /\ worker' = "done"
  /\ stalled' = (boot \in {"discarding", "joining"})
  /\ UNCHANGED <<boot, stopReq, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

\* ---------------------------------------------------------------- consumer

KeyMatches == ~cwdMoved \/ BypassCwdKey

\* take(): await, then mergeOutcomes under the registry mutex.
TakeAdopt ==
  /\ boot = "consumer" /\ KeyMatches
  /\ \/ worker = "done" /\ result = "ok"
     \/ BypassJoin /\ worker = "running"
  /\ usedEarly' = (worker = "running")
  /\ cwdAtTake' = cwdMoved
  /\ worker' = IF worker = "done" THEN "consumed" ELSE worker
  /\ adopted' = TRUE /\ taken' = TRUE
  /\ child' = "registry"
  /\ registered' = registered + 1
  /\ boot' = "connected"
  /\ UNCHANGED <<result, stopReq, stalled, hangs, inlined, cwdMoved, ioAlive, regUp, abort>>
  /\ UNCHANGED taskVars

\* A failed attempt is the one attempt: its error is what addServer would
\* have returned. RetryFailed is the earlier fallback that started it again.
TakeFailed ==
  /\ boot = "consumer" /\ KeyMatches
  /\ worker = "done" /\ result = "fail"
  /\ worker' = "consumed" /\ taken' = TRUE
  /\ boot' = IF RetryFailed THEN "inline" ELSE "connected"
  /\ UNCHANGED <<result, child, stopReq, stalled, adopted, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

\* A key mismatch discards (stop the child, join, tear the outcome down),
\* then connects inline: no attempt's result was used.
TakeMismatch ==
  /\ boot = "consumer" /\ ~KeyMatches /\ worker # "none"
  /\ stopReq' = ~BypassStop /\ boot' = "mismatch"
  /\ UNCHANGED <<worker, result, child, stalled, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

MismatchJoin ==
  /\ boot = "mismatch" /\ worker # "running"
  /\ worker' = IF worker = "done" THEN "consumed" ELSE worker
  /\ child' = IF child = "alive" THEN "reaped" ELSE child
  /\ boot' = "inline"
  /\ UNCHANGED <<result, stopReq, stalled, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

TakeNone ==
  /\ boot = "consumer" /\ worker = "none"
  /\ boot' = "inline"
  /\ UNCHANGED prewarm /\ UNCHANGED others /\ UNCHANGED taskVars

InlineConnect ==
  /\ boot = "inline"
  /\ \E ok \in BOOLEAN: registered' = registered + (IF ok THEN 1 ELSE 0)
  /\ inlined' = TRUE
  /\ boot' = "connected"
  /\ UNCHANGED prewarm /\ UNCHANGED <<hangs, cwdMoved, ioAlive, regUp, abort>> /\ UNCHANGED taskVars

\* ---------------------------------------------------------------- exit

\* deinitAtExit: discard (stop the child, join the worker), then
\* Registry.deinit sets retry_abort and joins its start tasks.
Teardown ==
  /\ boot \in {"connected", "noConsumer"}
  /\ boot' = "discarding" /\ stopReq' = ~BypassStop
  /\ UNCHANGED <<worker, result, child, stalled, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED others /\ UNCHANGED taskVars

\* discard's join and teardown, then (registry up) Registry.deinit.
DiscardJoin ==
  /\ boot = "discarding"
  /\ worker # "running" \/ BypassTeardownJoin
  /\ worker' = IF worker = "done" THEN "consumed" ELSE worker
  /\ child' = IF child = "alive" \/ (child = "registry" /\ regUp) THEN "reaped" ELSE child
  /\ abort' = (abort \/ regUp)
  /\ boot' = "joining"
  /\ UNCHANGED <<result, stopReq, stalled, adopted, taken, cwdAtTake, usedEarly>>
  /\ UNCHANGED <<hangs, inlined, registered, cwdMoved, ioAlive, regUp>> /\ UNCHANGED taskVars

\* main returns; std.process.Init joins its workers, then tears the Io down.
IoDown ==
  /\ boot = "joining"
  /\ BypassTeardownJoin \/ (worker # "running" /\ task \in {"idle", "done"})
  /\ ioAlive' = FALSE
  /\ boot' = "exited"
  /\ UNCHANGED prewarm
  /\ UNCHANGED <<hangs, inlined, registered, cwdMoved, regUp, abort>> /\ UNCHANGED taskVars

\* ---------------------------------------------------------------- start task

\* The registry's start task: one attempt, a transient failure pauses, and
\* the pause either times out into the one retry or ends on retry_abort.
AttemptEnds ==
  /\ task = "attempt" /\ ioAlive
  /\ task' \in {"pause", "done"}
  /\ UNCHANGED retriedAfterAbort
  /\ UNCHANGED boot /\ UNCHANGED others /\ UNCHANGED prewarm

PauseTimesOut ==
  /\ task = "pause" /\ ioAlive
  /\ ~abort \/ BypassRetryAbort
  /\ task' = "retry"
  /\ retriedAfterAbort' = abort
  /\ UNCHANGED boot /\ UNCHANGED others /\ UNCHANGED prewarm

PauseAborted ==
  /\ task = "pause" /\ abort /\ ~BypassRetryAbort
  /\ task' = "done"
  /\ UNCHANGED retriedAfterAbort
  /\ UNCHANGED boot /\ UNCHANGED others /\ UNCHANGED prewarm

RetryEnds ==
  /\ task = "retry" /\ ioAlive
  /\ task' = "done"
  /\ UNCHANGED retriedAfterAbort
  /\ UNCHANGED boot /\ UNCHANGED others /\ UNCHANGED prewarm

Next ==
  \/ KeysOk \/ FatalExit \/ BannerOk \/ Start \/ WindowError \/ RegistryUp
  \/ MoveCwd \/ ReachConsumer \/ SkipConsumer
  \/ WorkerFinish \/ WorkerTimeout
  \/ TakeAdopt \/ TakeFailed \/ TakeMismatch \/ MismatchJoin \/ TakeNone \/ InlineConnect
  \/ Teardown \/ DiscardJoin \/ IoDown
  \/ AttemptEnds \/ PauseTimesOut \/ PauseAborted \/ RetryEnds

Spec == Init /\ [][Next]_vars
        /\ WF_vars(WorkerFinish) /\ WF_vars(WorkerTimeout)
        /\ WF_vars(TakeAdopt \/ TakeFailed \/ TakeMismatch \/ MismatchJoin \/ TakeNone \/ InlineConnect)
        /\ WF_vars(Teardown) /\ WF_vars(DiscardJoin) /\ WF_vars(IoDown)
        /\ WF_vars(AttemptEnds \/ PauseTimesOut \/ PauseAborted \/ RetryEnds)

TypeOK ==
  /\ boot \in BootStates
  /\ worker \in WorkerStates
  /\ child \in ChildStates
  /\ result \in {"none", "ok", "fail"}
  /\ registered \in 0..2
  /\ task \in TaskStates
  /\ {hangs, stopReq, stalled, adopted, inlined, taken, cwdMoved, cwdAtTake,
      usedEarly, ioAlive, regUp, abort, retriedAfterAbort} \subseteq BOOLEAN

\* The boot thread never uses the prewarm outcome before the worker ended.
JoinedBeforeUse == ~usedEarly

\* A prewarm recorded in another directory is never adopted.
NoStaleAdoption == adopted => ~cwdAtTake

\* No thread still uses the Io after it is torn down. std.process.Init joins
\* every worker before it deinitializes the Io, so the runtime rules this
\* out by construction; only BypassTeardownJoin (no such join) violates it.
NoUseAfterTeardown == ~ioAlive => (worker # "running" /\ task \in {"idle", "done"})

\* The hazard of every exit path: once the process has exited, no companion
\* the prewarm spawned is alive (prewarm-owned or registered) and no
\* prewarm worker was left unjoined.
ExitClean == boot = "exited" => (child \notin {"alive", "registry"} /\ worker # "running")

\* No exit path waits out a silent companion's handshake timeout.
NoExitStall == ~stalled

\* The companion is registered once at most: adopted or inline, never both.
AtMostOneCompanion == registered <= 1 /\ ~(adopted /\ inlined)

\* An attempt that ran to a result is the one attempt.
NoRepeatAfterResult == ~(taken /\ inlined)

\* Reaching the consumer always ends adopted, with an attempt's result, or
\* with the inline connect tried.
NeverMissing == boot = "connected" => (adopted \/ taken \/ inlined)

\* Once teardown signals, no retry attempt starts.
NoRetryAfterAbort == ~retriedAfterAbort

\* Under the fairness above, every exit that started finishes.
TeardownFinishes == (boot \in {"discarding", "joining"}) ~> (boot = "exited")
=============================================================================
