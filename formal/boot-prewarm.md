# Boot prewarm and retry abort

`BootPrewarm.tla` is a finite model of two lifecycles that decide whether a
worker can still use the process `Io` when boot or teardown moves on:

- the companion prewarm (`src/boot_prewarm.zig`, DRAFT-boot-prewarm ADR): a
  worker connects `codedb-pro --mcp` before the registry exists, and the boot
  thread joins it at its one consumer, `connectCompanion`;
- one registry start task's retry pause (`src/mcp_start.zig`): teardown must
  not wait out the pause, and must still join the task (#325).

| Model action | Implementation boundary |
| --- | --- |
| `Init` (worker `running` or `none`) | `startup.resolveKeysOrRunAcpPreAuth` calls `boot_prewarm.startCompanion` after `runSubcommand`; the gate (`wantsCompanion`, no project `.mcp.json`, opt-out, PATH) either declines or `start` launches `connectTask` with `io.concurrent`. |
| `WorkerFinish` | `connectTask`: one `startServer` on a task-local registry; a failure tears its server down before returning. |
| `MoveCwd` | `-w` or auto-isolation changing the cwd between start and consumer. |
| `TakeAdopt`, `TakeFailed`, `TakeMismatch`, `TakeNone` | `boot_prewarm.take`: `matches` (cwd key, home, probe and lazy settings), `Future.await`, then `mcp_boot.adoptStarted` under the registry mutex; a fast failure returns null so the caller runs `addServer`; a mismatch calls `discard`. |
| `InlineConnect` | `companion_boot.connectNow` falling back to `Registry.addServer`. |
| `SkipConsumer`, `Teardown` | `connectCompanion`'s deferred `discard`, and `Registry.deinitAtExit` calling `discard` (cancel, join, tear down); `Registry.deinit` sets `retry_abort` before `joinPending`. |
| `IoDown` | `main` returns; `std.process.Init` deinitializes the threaded `Io` after joining its workers. |
| `AttemptEnds`, `PauseTimesOut`, `PauseAborted`, `RetryEnds` | `mcp_start.task` and `pauseBeforeRetry`: the pause is `Io.Event.waitTimeout` on the registry's heap-owned event. |

The positive configuration checks, over every interleaving of these actions:
the outcome is never used before the worker ended (`JoinedBeforeUse`), a
prewarm recorded in another directory is never adopted (`NoStaleAdoption`),
no worker or start task is live once the `Io` is down (`NoUseAfterTeardown`),
no prewarm-owned server outlives teardown (`NoLeakAtExit`), the companion is
registered at most once (`AtMostOneCompanion`), the consumer always ends
adopted or with the inline connect tried (`NeverMissing`), and no retry starts
after teardown signalled (`NoRetryAfterAbort`). Under weak fairness of the
worker, consumer, teardown and task steps, a started teardown finishes
(`TeardownFinishes`).

Run TLC from `formal/` with `-deadlock`, since exit is a terminal state.

| Config | Deliberate mutation | Violated invariant |
| --- | --- | --- |
| `BootPrewarmNoJoin.cfg` | Adopt while the worker still runs | `JoinedBeforeUse` |
| `BootPrewarmNoCwdKey.cfg` | Adopt without comparing the cwd key | `NoStaleAdoption` |
| `BootPrewarmNoTeardownJoin.cfg` | Tear the `Io` down without joining the prewarm or the start task | `NoUseAfterTeardown` |
| `BootPrewarmNoRetryAbort.cfg` | Ignore `retry_abort` in the pause | `NoRetryAfterAbort` |

These are mutation checks of the model, not historical regressions. The
retry pause has a runtime anchor that fails on the old revision:
`src/mcp_start.zig` `teardown with a pending transient retry returns in well
under the pause` (fails when `Registry.deinit` does not set the event). The
prewarm anchors are the `boot prewarm:` tests in `src/boot_prewarm.zig`
(byte-identical catalog against `addServer`, cwd-change discard, settings
mismatch, failed-prewarm fallback, discard of a silent server, and the
early-exit gate).

Omitted: the handshake's own protocol states and timeouts, the content of the
catalog (covered by the byte-comparison test), the error-return paths that
leave `main` before the registry exists (there `std.process.Init` joins the
worker, bounded by the handshake timeout, and process exit closes the child's
pipe), and more than one start task. The model does not establish that the
Zig code refines it.
