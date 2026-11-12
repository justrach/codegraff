# Boot prewarm and retry abort

`BootPrewarm.tla` is a finite model of two lifecycles that decide whether a
worker, or a process it spawned, can outlive the decision to exit:

- the companion prewarm (`src/boot_prewarm.zig`, ADR 0337): a
  worker connects `codedb-pro --mcp` before the registry exists, and the boot
  thread joins it at its one consumer, `connectCompanion`, or discards it;
- one registry start task's retry pause (`src/mcp_start.zig`): teardown must
  not wait out the pause, and must still join the task (#325).

| Model action | Implementation boundary |
| --- | --- |
| `KeysOk`, `FatalExit`, `BannerOk` | `startup.resolveKeysOrRunAcpPreAuth` and `session_start.setupWorktreeAndBanner`. Both can leave through `std.process.fatal` (no credential, `--add-dir`, isolation, `--experiment`), which runs no defer and joins nothing. |
| `Start` | `main` after `setupWorktreeAndBanner`: `boot_prewarm.startCompanion` (gate: `wantsCompanion`, no project `.mcp.json`, opt-out, PATH), then `defer boot_prewarm.discard(io)`. `start` launches `connectTask` with `io.concurrent`. |
| `WindowError` | Any `try` that fails between that start and `initRegistryConsent` returning: the deferred `discard` runs. |
| `RegistryUp` | `initRegistryConsent` returned; `defer registry_storage.deinitAtExit()` is armed. |
| `WorkerFinish`, `WorkerTimeout` | `connectTask`: one `startServer` on a task-local registry whose `spawn_watch` publishes every child (`Registry.spawnStdio`). A failure reaps its child; success hands the child to the outcome. A child that never answers ends the attempt only at the 15 s handshake timeout, or when `discard` stops it. |
| `MoveCwd` | Any chdir between the start and the consumer. Nothing in the code does this now that the start follows the banner; the cwd key is kept and checked. |
| `TakeAdopt`, `TakeFailed`, `TakeMismatch` + `MismatchJoin`, `TakeNone` | `boot_prewarm.take` (through `connect`): `matches` (cwd key, home, probe and lazy settings), `Future.await`, then `mcp_boot.adoptStarted` under the registry mutex. A failed attempt returns its error, the error `addServer` would have returned. A mismatch calls `discard` and the caller runs `addServer`. |
| `InlineConnect` | `boot_prewarm.connect` falling back to `Registry.addServer` when no attempt ran to a result. |
| `SkipConsumer`, `Teardown`, `DiscardJoin` | `connectCompanion`'s deferred `discard`, and `Registry.deinitAtExit` calling `discard`: `Watch.stop` (SIGKILL the published child; one spawned later is stopped as it is published), `Future.await`, tear the outcome down. Then `Registry.deinit` sets `retry_abort` before `joinPending`. |
| `IoDown` | `main` returns; `std.process.Init` deinitializes the threaded `Io` after joining its workers. |
| `AttemptEnds`, `PauseTimesOut`, `PauseAborted`, `RetryEnds` | `mcp_start.task` and `pauseBeforeRetry`: the pause is `Io.Event.waitTimeout` on the registry's heap-owned event. |

The positive configuration checks the following over every interleaving of
these actions, including a companion that never answers:

- `ExitClean`: once the process has exited, no companion the prewarm spawned
  is alive, whether prewarm-owned or registered, and no prewarm worker was
  left unjoined. This is the real hazard of every exit path.
- `NoExitStall`: no exit path waits out a silent companion's handshake timeout.
- `JoinedBeforeUse`: the outcome is never used before the worker ended.
- `NoStaleAdoption`: a prewarm recorded in another directory is never adopted.
- `NoRepeatAfterResult`: an attempt that ran to a result is the one attempt.
- `AtMostOneCompanion`: the companion is registered at most once.
- `NeverMissing`: the consumer always ends adopted, with an attempt's result,
  or with the inline connect tried.
- `NoRetryAfterAbort`: no retry starts after teardown signalled.
- `NoUseAfterTeardown`: no worker or start task is live once the `Io` is down.
- `TeardownFinishes`: under weak fairness of the worker (including its
  timeout), consumer, teardown and task steps, every exit that started
  finishes.

`NoUseAfterTeardown` is not evidence about this change. `std.process.Init`
joins every worker before it deinitializes the `Io`, so the runtime rules
that hazard out by construction. Its control removes that join from the
model. On the uncovered exit paths the actual failure was a stall plus a
leaked child, which `ExitClean` and `NoExitStall` capture. `ExitClean`
replaces the earlier `NoLeakAtExit`, which covered only the normal teardown.

Run TLC from `formal/` with `-deadlock`, since exit is a terminal state.

| Config | Deliberate mutation | Violated invariant |
| --- | --- | --- |
| `BootPrewarmNoJoin.cfg` | Adopt while the worker still runs | `JoinedBeforeUse` |
| `BootPrewarmNoCwdKey.cfg` | Adopt without comparing the cwd key | `NoStaleAdoption` |
| `BootPrewarmNoTeardownJoin.cfg` | Tear the `Io` down without joining the prewarm or the start task | `NoUseAfterTeardown` |
| `BootPrewarmNoRetryAbort.cfg` | Ignore `retry_abort` in the pause | `NoRetryAfterAbort` |
| `BootPrewarmEarlyStart.cfg` | Start the prewarm before credentials resolve (the first revision): a credential failure exits fatally with the child alive | `ExitClean` |
| `BootPrewarmNoWindowDiscard.cfg` | No deferred discard between the start and the registry: an error return leaves the connected child behind | `ExitClean` |
| `BootPrewarmNoStop.cfg` | `discard` only joins, without stopping the child: an exit waits for the handshake timeout | `NoExitStall` |
| `BootPrewarmRetryFailed.cfg` | A failed attempt falls back to a second, inline start (the first revision) | `NoRepeatAfterResult` |

These are mutation checks of the model. Two of them, `EarlyStart` and
`RetryFailed`, are also the behavior of the first revision of the prewarm.
Runtime anchors that fail on that revision:

- `boot prewarm: a failing companion is started exactly as often as the
  inline path starts it`: two spawns against one on the first revision.
- `boot prewarm: an error return before the registry exists discards promptly
  and leaves no child`. On a `discard` that cancels the worker, the child
  survives or the test process faults: a cancel delivered inside the bounded
  handshake's `Io.Select` returns before the select's read task stops. On a
  `discard` that only joins, it waits for the 15 s handshake timeout.
- `src/mcp_start.zig` `teardown with a pending transient retry returns in well
  under the pause` fails when `Registry.deinit` does not set the event.

`boot prewarm: main starts it after credentials and the banner, and defers its
discard` checks only source placement, which is weaker evidence. The no-key
case was also checked end to end with a stub companion that ignores stdin:
the first revision left it running after `graff -p` exited 1, and the current
code spawns nothing.

Omitted:

- the handshake's own protocol states;
- the content of the catalog (the byte-comparison test covers it);
- a fatal exit after the registry exists (it does not involve the prewarm);
- Windows, where `Watch` has no signal and `discard` waits for the attempt,
  bounded by the handshake timeout;
- more than one start task.

The model does not establish that the Zig code refines it.
