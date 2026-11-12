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
  task (`boot_prewarm.startCompanion`) right after `runSubcommand`, and the
  boot thread joins it in `connectCompanion`, exactly where `addServer` ran.
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
  under the registry mutex (ADR 0197). A mismatch, or a prewarm nobody
  adopted, is cancelled, joined and torn down: in `connectCompanion`, and in
  `Registry.deinitAtExit`.
- **A prewarm never loses the companion.** A quick failure falls back to the
  inline `addServer`. A timeout is not repeated.
- **Teardown ends retry pauses.** Each registry owns a heap event,
  `retry_abort`. `Registry.deinit` sets it before joining, and the pause in
  `mcp_start` waits on it. A start waiting to retry stops waiting and
  records its first failure. The registry still joins every task, so no
  thread outlives `io` (#325).
- **Formal evidence.** `formal/BootPrewarm.tla` holds the invariants
  `JoinedBeforeUse`, `NoStaleAdoption`, `NoUseAfterTeardown` and
  `NoRetryAfterAbort`, each with a negative control.

## Consequences

- `-p` with an uncached companion reaches its first request about as fast as
  `max(companion, rest of boot)` instead of their sum. A cached companion
  (restored dormant) gains nothing and costs nothing.
- The companion's connect line on stderr can print earlier than other boot
  diagnostics.
- When boot fails after the prewarm started (no credential, an error before
  the registry exists), the companion has already been spawned. Process
  exit closes its pipe, and `std.process.Init` joins the worker, which is
  bounded by the handshake timeout.
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
