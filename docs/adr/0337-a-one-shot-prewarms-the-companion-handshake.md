# 0337. A one-shot prewarms the companion handshake; teardown ends retry pauses

Status: accepted 2026-11-12

## Context

`-p` connects the companion (`codedb-pro --mcp`) on the boot thread:
ADR 0230 defers it only for interactive and ACP sessions
(`companion_boot.deferCompanion`), so the first request's catalog already
holds the companion. Its spawn and handshake ran in series after
credentials, the plugin scan and the MCP merge. With no tool cache, a
hermetic one-shot with a stub companion sent its first request at a median
of 24.2 ms, against 14.0 ms with no companion on PATH.

Teardown had the opposite problem. `Registry.deinit` joins every pending
start, and a start that failed transiently slept 1.5 s before its one retry,
with no way to wake it. A REPL whose companion failed at once was ready in
about 50 ms but took about 1.54 s to exit.

## Decision

- **Overlap, not defer.** A one-shot starts the companion connect on its own
  task (`boot_prewarm.startCompanion`) once credentials have resolved and
  the banner has settled the cwd. `main` defers `boot_prewarm.discard`
  right after the start. The boot thread joins the task in
  `connectCompanion`, exactly where `addServer` ran.
  The handshake is not deferred past the first request, so the first
  request's tools, prompt and cache key are byte-identical to the serial
  path.
- **Only when the outcome is known in advance.** The prewarm starts only
  when the registry will be the empty one and this companion is the one
  `connectCompanion` would try first: lean `-p`, no positionals, no `-w`, no
  project `.mcp.json`, none of `GRAFF_MCP_PROBE`, `GRAFF_MCP_EAGER`,
  `GRAFF_MCP_HANDSHAKE_SECS` or `GRAFF_MCP_PROBE_MS`, not opted out in
  `.harness/settings.json`, and on `PATH`. Every other session keeps the
  serial path.
- **Join at the consumer, or discard.** `take` adopts the result only if the
  cwd, home and registry settings still match, awaits it, and merges it
  under the registry mutex (ADR 0197). Discard stops the attempt's child,
  joins the task and tears the outcome down. It applies to a mismatch, or to
  a prewarm nobody adopted, at three points: in `connectCompanion`, in
  `Registry.deinitAtExit`, and on any return between the start and the
  registry (`main`'s defer). The task is never cancelled: a cancel delivered
  inside the bounded handshake's `Io.Select` returns before the select's
  read task stops. Instead, the worker's task-local registry publishes each
  child it spawns (`Registry.spawn_watch`, `boot_prewarm.Watch`). Discard
  kills that child, so the handshake read ends at once. The worker forgets
  its child before it reaps it, under the same lock, so a pid that may
  already be reused is never signalled.
- **One attempt.** An attempt that ran to a result is the attempt the serial
  path made. Its error is returned as `addServer`'s would have been, with the
  same (empty) diagnostics; the companion is not started again. Only when no
  attempt ran to a result (none started, or discarded on a mismatch) does the
  consumer call `addServer` inline.
- **Teardown ends retry pauses.** Each registry owns a heap event,
  `retry_abort`. `Registry.deinit` sets it before joining, and the pause in
  `mcp_start` waits on it. A start waiting to retry stops waiting and
  records its first failure. The registry still joins every task, so no
  thread outlives `io` (#325).
- **Formal evidence.** `formal/BootPrewarm.tla` models the fatal exits, the
  early error return and both discards. Each of these invariants has a
  negative control: `ExitClean` (no live companion and no unjoined worker
  once the process exits), `NoExitStall`, `NoRepeatAfterResult`,
  `JoinedBeforeUse`, `NoStaleAdoption` and `NoRetryAfterAbort`. The model
  also checks `NoUseAfterTeardown`, but the runtime's join rules that out by
  construction (`formal/boot-prewarm.md`).

## Consequences

- The gain applies to a cold MCP tool cache only: the first `-p` per HOME,
  or the first after the companion binary changes. There, `-p` reaches its
  first request in about `max(companion, rest of boot)` instead of their
  sum. With a warm cache the companion is restored dormant in both paths:
  the prewarm task spawns no process, and gains and costs nothing
  measurable. The pre-series binary spawned none either.
- Measured on macOS, hermetic `-p hi --model lmstudio`, fresh HOME with 15
  plugins, a stub companion that answers after 6 ms. Medians of the first
  POST, 20 runs each, alternating with the pre-series binary:

  | Companion | Pre-series | Now | Companion spawns per run |
  | --- | --- | --- | --- |
  | answers, cold tool cache | 22.1 ms | 18.6 ms | 1 / 1 |
  | answers, warm tool cache | 12.6 ms | 12.4 ms | 0 / 0 |
  | fails (exits 1) | 24.5 ms | 20.2 ms | 2 / 2 |
  | not on PATH | 11.6 ms | 11.7 ms | 0 / 0 |

  A failing companion is spawned twice by both, because the stdio probe
  respawns a process that closed. The first revision of this change retried
  the failed attempt inline: 4 spawns and 32.2 ms.
- The companion's connect line on stderr can print earlier than other boot
  diagnostics.
- A run that fails on credentials or in the banner spawns no companion, as
  before. Those paths exit through `std.process.fatal`, which runs no defer.
  Credential resolution measures about 0 ms for a one-shot with an
  environment key, so starting after it costs no overlap. With a
  Keychain-only credential the lookups no longer overlap the handshake.
- On Windows, `Watch` has no signal, so a discard waits for the attempt,
  which the handshake timeout bounds.
- An interrupted retry is not attempted again in that process; the next
  session starts the server again.
- The plugin scan is not prewarmed. `plugins.applyEnv` stores
  `plugins.disabled` on the boot thread while a scan worker would read it in
  `discoverFresh`. With the companion prewarmed, the scan already overlaps
  the longer handshake. Revisit it if `applyEnv` stops storing an unchanged
  value, or if the scan becomes the longest boot phase.
- Moving the one-shot companion to the background entirely, as ADR 0230
  does for interactive sessions, would make the first request's catalog
  depend on timing. That stays an owner decision.
