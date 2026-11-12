# 0339. A one-shot joins the companion handshake with a budget

Status: accepted 2026-11-12

## Context

[ADR 0337](0337-a-one-shot-prewarms-the-companion-handshake.md) prewarms the
companion (`codedb-pro --mcp`) so a lean `-p` one-shot's first request already
carries its tools, and joins it in `connectCompanion`
(`boot_prewarm.take`). The join was unbounded, and the attempt's own ceilings
are the stdio probe's 5 s (`GRAFF_MCP_PROBE_MS`) plus `initialize`'s 15 s
(`GRAFF_MCP_HANDSHAKE_SECS`). A companion that spawns and then never answers
held the first request for 20.1 s — measured on macOS with a stub first on
PATH, on a run whose answer otherwise takes ~25 ms. Nothing on screen names
the wait, and a user cannot tell it from a stalled model. A healthy companion
answers in ~6-50 ms and a missing one is not started at all, so the unbounded
join only ever bought patience for the pathological case.

The documented knobs did not reach it. `GRAFF_MCP_HANDSHAKE_SECS` and
`GRAFF_MCP_PROBE_MS` are applied by `mcp_rpc.applyHandshakeTimeoutEnv`, which
runs in `mcp_boot.initWithMerged` — the path `oneshotSkipsImportedMcp` skips on
a lean `-p` — and `boot_prewarm.wantsCompanion` refuses to prewarm at all when
any of those variables is set. The one case where a shorter handshake would
help was the one case where it could not be asked for.

The first version of this change bounded the join and got three things wrong,
all three found by review against it and fixed here: teardown was only bounded
on POSIX (`signal` returned early on Windows, so `stopAtExit` still awaited the
attempt, up to the probe plus handshake caps); a companion that failed *after*
the budget was reported as a successful connect and its error was dropped; and
the two late-merge tests were order-dependent, so a failure in one corrupted
the run instead of failing where it happened.

A second review against that fix found a fourth, and it is the one a user would
have seen: teardown's own kill came back out as a connect failure. Ending a
healthy companion because the run is ending is not the companion failing, but
the worker reported the `McpClosed` that kill produces exactly like one, so a
normal `-p` exit printed `companion: codedbpro failed to connect after the boot
budget (McpClosed); native tools only` on its way out — after the tools it was
claiming had failed to arrive.

## Decision

- **A join budget, not an unbounded await.** `take` waits
  `boot_prewarm.default_budget_ms` for the attempt and then returns. 250 ms is
  the `acp_mcp_servers.attach_budget_ms` precedent for the same decision, 1500
  ms on Windows as there. `GRAFF_MCP_COMPANION_BOOT_MS` overrides it; unset,
  `0` or unparsable mean the default, and anything above the 60 s cap is
  clamped to the cap — a typo buys a long bound, never the unbounded join, and
  never a silent fall back to the default either. It is read where the prewarm
  starts (`startCompanion`) — not by `applyHandshakeTimeoutEnv` — and it is
  deliberately not in `wantsCompanion`'s disable list: a knob for this path
  must not turn the path off. The wait is an `Io.Event` deadline set by the
  worker's last write, not a poll: a 2 ms `io.sleep` costs ~5 ms of overshoot on
  macOS, which turned a 250 ms budget into a 355 ms wait.
- **Over budget, the attempt keeps running and merges itself.** `take` hands
  `reg` to the watch (`Watch.late_merge`, written once under the same lock as
  `Watch.done`, asserted null before the write) and reports `.late`, so
  `connectCompanion` neither waits nor falls back to `addServer`: one spawn
  either way. Whichever side gets there first consumes the outcome exactly
  once — `take` awaits the future and adopts, or the worker merges through
  `mcp_boot.adoptStarted`, the single merge point, which drops a latecomer
  whose server name is already connected (#505: two copies of every tool make a
  strict Responses endpoint reject the request) and keeps its arena in
  `task_arenas` for the normal teardown.
- **`.late` is not "connected", and a late failure is not a success.** `take`
  and `connect` return `Adopted`: `.connected` (the catalog is in the
  registry), `.late` (still running, this registry is its merge target), or an
  error. A failure that lands before the budget keeps the contract the serial
  path had — `take` returns it, `error.McpClosed` included. A failure that
  lands *after* the budget has no request left to return to, so the worker
  records it (`lateOutcome` / `lateError`) and prints one line to stderr
  (`companion: <name> failed to connect after the boot budget (<err>); native
  tools only`). `connectCompanion` names the other half of the same fact for
  `.late` (`companion: <bin> still connecting after the boot budget`). Both
  lines go to **stderr**, which is the only destination this path can reach:
  the dim engine notice `connectCompanion` prefers needs `GRAFF_REPL_DEBUG`
  *and* an interactive session, and every interactive session — REPL and ACP
  alike — queues the companion on `pending_starts` instead, so the branch that
  could reach the sink is the one only `-p` and `--json` take, where `speak` is
  already false. Silence is what made a late failure indistinguishable from a
  connect; one line on stderr is what it gets instead.
- **A stop the exit path asked for is not a failure.** `stopAtExit` ends the
  attempt the run can no longer wait for, and the child's death arrives as a
  `McpClosed` like any other. Reported as one, a healthy companion printed the
  failure line above on a normal exit. `Watch.settle` now reads the stop intent
  in the same critical section as the merge target, so an attempt whose read
  returned `McpClosed` because teardown killed it publishes `.stopped`: the
  outcome is recorded, never printed, and `lateError` stays null — `.failed` is
  the only state that carries an error. A companion that genuinely failed at
  the instant teardown asked it to stop is indistinguishable and is recorded as
  `.stopped`, which is the quiet direction a dying run can afford. `stopAtExit`
  returns that outcome because the slot and its watch are freed at exit, so
  `lateOutcome` has nothing left to read; `boot_prewarm_tests` pins `.stopped`
  against `.failed` there.
- **`discard` keeps its meaning; `stopAtExit` is new and bounded on both
  platforms.** `discard` still means "nobody wants it: stop, join, tear down",
  and now leaves a handed-off attempt alone — it is running on purpose.
  `Registry.deinitAtExit` calls `stopAtExit` instead: end the child, join the
  worker, tear down. `Watch.signal` ends the child on both platforms — POSIX
  `SIGKILL`, and on Windows `NtTerminateProcess` on the process handle
  (`Child.Id` is that handle there) — without waiting or freeing the `Child`,
  which the worker still reaps. So the join is bounded by "the read sees end of
  stream", not by the 5 s probe plus the 15 s handshake, and that runs before
  `reg.deinit()`, which is what makes the worker's late merge safe at exit.
- **The one-shot's own exits take the same path.** `std.process.exit` unwinds
  no `defer`, so `main`'s `deinitAtExit` never runs on the two exits inside
  `oneshot.run` — the provider-failure one and the `budget_exhausted` /
  `unfinished_work` one a `-p` run actually takes. Both call
  `boot_prewarm.stopAtExit(io)` first. They still skip the rest of the
  registry's teardown, as they did before; what they no longer do is abandon a
  live worker and, on Windows, orphan the companion process.
- **A run that is going to fatal prewarms nothing.** The side finding that
  framed this work — a keyless `-p` spawning the companion before exiting 1 —
  does not reproduce on this tree. `main` starts the prewarm after
  `resolveKeysOrRunAcpPreAuth` returns, and that call is an `orelse return`, so
  the credential fatal returns first: `-p hi` with no key and a stub on PATH
  spawns nothing and exits in ~66 ms. `boot_prewarm_tests` pins the ordering.

## Consequences

- The pathological case is gone, and nothing is given up in the normal one.
  Measured on macOS, hermetic `-p hi --model lmstudio`, stub `codedb-pro` first
  on PATH, stub answers after N ms, medians of wall clock over the binaries
  built from the same tree with and without this change:

  | Stub companion | Before | After | First request's companion tools |
  | --- | --- | --- | --- |
  | answers in 6 ms (n=8) | 23.3 ms (22.0-24.8) | 23.0 ms (22.1-25.4) | `codedbpro (search, read)` in 8/8 both |
  | answers in 600 ms (n=5) | 624.6 ms (618.4-642.6) | 265.9 ms (264.8-266.9) | present before, absent after |
  | never answers (n=5) | 20 134.0 ms (20 125.7-20 179.4) | 266.1 ms (263.9-300.5) | absent both |

  Re-measured on the fixed tree: a 6 ms stub answers in 20.3 ms (n=8) with
  `codedbpro (search, read)` on the first request in 8/8, and a silent stub
  costs 263.5-265.0 ms (n=5, three runs) with one spawn per run. The silent row
  is why this is not a regression for it: the unbounded join paid 20 s and
  still ended with no companion tools, because the attempt failed at its own
  timeout.
- **Teardown is bounded too, and that is measured, not argued.** With a silent
  child, the handshake cap lowered to 1200 ms and the join already handed off,
  `stopAtExit` on macOS takes 0-1 ms (n=3) with the child kill in place and
  1025-1037 ms (n=3) with it suppressed — the attempt's own handshake timeout,
  which is what the reviewer measured as 1191 ms against the version this
  fixes. **Windows is unmeasured; what is verified there is a cross-compile.**
  `zig build -Dtarget=x86_64-windows` builds the Windows branch and is the
  command that passes — the whole binary, not the test binary: `zig build
  test-bin -Dtarget=x86_64-windows` does not link, leaving `fchdir`, `setenv`
  and `unsetenv` undefined from `src/git_dirs_tests.zig`. That builds the
  branch, but it does not run it, so it says nothing about whether a
  terminated child's pipe reads return promptly on Windows, and therefore
  nothing about whether the join there is ~0 ms or one handshake timeout. What
  is known by reading: `Child.Id` is the process handle on Windows, and
  `NtTerminateProcess` is what `Child.kill` itself issues before it reaps. The
  kill is a signal, not a cancellation: the worker is never cancelled (a
  cancel that lands inside the bounded handshake's `Io.Select` returns before
  the select's read task stops, and that task would outlive its frame).
- The trade-off is the middle row: a cold-and-slow companion can miss the
  one-shot catalog. It keeps connecting, and a late merge is the same event
  `/mcp add` causes — the next request sees the tools and the prompt cache is
  busted from that turn (ADR 0221) — but it can also land after the run's last
  request and never be seen at all. Nothing here can both hold the first
  request and keep the catalog of a companion that has not answered. That the
  degradation is now visible (`.late` plus a one-line notice) is the only claim
  made about it: the catalog itself is still lost.
- **The exit path is quiet, and measured on the binary as well.** A stub that
  answers in 200 ms, `GRAFF_MCP_COMPANION_BOOT_MS=1`, and a `-p hi --model
  lmstudio` run that finishes in ~18 ms: teardown kills the attempt in its
  handshake, and the version this fixes prints `companion: codedbpro failed to
  connect after the boot budget (McpClosed); native tools only` on stderr in
  3/3 runs, this one in 0/3, recording `.stopped` instead. The silent row of
  the table above is the same defect seen from the other side: a stub that
  never answers printed that line 3/3 before and 0/3 now, and the wall clock it
  measures did not move — 266.7-274.3 ms (n=12, two invocations, medians 268.3
  and 268.1) against the 263.5-265.0 ms recorded here before. The other
  direction is unchanged: a companion that exits 1 at 300 ms while the run is
  still waiting on the model (1 s response) still prints that line exactly once
  (3/3 before, 3/3 after), and a healthy 5 ms companion still shows its catalog
  and no such line, at the 250 ms default and at a 1 ms budget alike (3/3
  each).
- **What is still not fixed, stated plainly.** A companion whose handshake has
  not finished when the run ends is now lost quietly: no failure line, and no
  catalog either, because the exit path kills it rather than waiting. `.stopped`
  and `.failed` cannot be told apart when a companion dies at the same instant
  teardown asks it to stop; the record says `.stopped`. The Windows join time
  and the Windows pipe behaviour on a terminated child have not been run. A
  late merge can land after the run's last request, so the catalog exists and is
  never seen. And the budget is clamped at 60 s, so a genuinely slow companion
  cannot be waited for through the knob.
- Interactive and ACP sessions are untouched: they queue the companion on
  `pending_starts` (ADR 0230) and never create a prewarm slot, so the budget
  exists only on the `-p` path. The one shared line, `Registry.deinitAtExit`,
  is a no-op when no slot exists.
- The worker now merges from a task thread rather than the boot thread. Every
  reader that matters takes the registry mutex (`snapshotTools`), the same
  assumption a deferred start's join already makes.
- **The late-merge tests own their fixtures.** Each defers `stopAtExit` before
  its first assertion, so a failed `expect` still joins the worker before the
  registry it merges into is deinited; otherwise one failure leaks the slot and
  the next test crashes inside a merge into freed memory. Each states its own
  premise (`.late`, empty catalog) instead of depending on a fixture that has
  not landed yet, and each names its property through the worker's published
  outcome (`.merged`, `.duplicate`, `.failed`) rather than through "nothing
  visibly went wrong" — a dropped latecomer and a merge that never happened
  look identical from the registry otherwise. Proved by mutation, each applied
  to the fixed tests and run over the whole filtered suite: deleting
  `and !s.watch.handOff(reg)` fails all three budget tests in `waitForLate`
  (`TestExpectedLateMerge`) — `take` still reports `.late`, but nothing ever
  merges it — with the other 120 passing; deleting `w.late_merge = reg` fails
  the same three the same way, and the tests that follow still pass with no
  leaked allocations, which is the case that used to segfault the next test;
  deleting `done_event.set(io)` fails only the join-wake test, at
  `expect(ms < 500)` (1200 ms budget, one instant answer), with 122 passing.
- Revisit by raising `default_budget_ms`, not by restoring the unbounded join;
  measure with `scripts/bench-startup.py --companion` plus a first-request
  body capture (the schema gate's `Deferred now:` line names what was left
  out).
