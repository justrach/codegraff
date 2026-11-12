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

## Decision

- **A join budget, not an unbounded await.** `take` waits
  `boot_prewarm.default_budget_ms` for the attempt and then returns. 250 ms is
  the `acp_mcp_servers.attach_budget_ms` precedent for the same decision, 1500
  ms on Windows as there. `GRAFF_MCP_COMPANION_BOOT_MS` overrides it; unset,
  `0`, unparsable or above 60 s mean the default, so a typo cannot restore the
  unbounded join. It is read where the prewarm starts (`startCompanion`) — not
  by `applyHandshakeTimeoutEnv` — and it is deliberately not in
  `wantsCompanion`'s disable list: a knob for this path must not turn the path
  off. The wait is an `Io.Event` deadline set by the worker's last write, not
  a poll: a 2 ms `io.sleep` costs ~5 ms of overshoot on macOS, which turned a
  250 ms budget into a 355 ms wait.
- **Over budget, the attempt keeps running and merges itself.** `take` hands
  `reg` to the watch (`Watch.late_merge`, written under the same lock as
  `Watch.done`) and reports success, so `connectCompanion` neither waits nor
  falls back to `addServer`: one spawn either way. Whichever side gets there
  first consumes the outcome exactly once — `take` awaits the future and
  adopts, or the worker merges through `mcp_boot.adoptStarted`, the single
  merge point, which drops a latecomer whose server name is already connected
  (#505: two copies of every tool make a strict Responses endpoint reject the
  request) and keeps its arena in `task_arenas` for the normal teardown.
- **`discard` keeps its meaning; `stopAtExit` is new.** `discard` still means
  "nobody wants it: stop, join, tear down", and now leaves a handed-off
  attempt alone — it is running on purpose. `Registry.deinitAtExit` calls
  `stopAtExit` instead: kill the child, join the worker, tear down. That runs
  before `reg.deinit()`, which is what makes the worker's late merge safe at
  exit and keeps a silent companion from stalling teardown.
- **A run that is going to fatal prewarms nothing.** The side finding that
  framed this work — a keyless `-p` spawning the companion before exiting 1 —
  does not reproduce on this tree. `main` starts the prewarm after
  `resolveKeysOrRunAcpPreAuth` returns, and that call is an `orelse return`, so
  the credential fatal returns first: `-p hi` with no key and a stub on PATH
  spawns nothing and exits in ~66 ms. `boot_prewarm_tests` pins the ordering;
  the earlier observation came from a revision of the branch that predates the
  ordering commit.

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

  The silent row is why this is not a regression for it: the unbounded join
  paid 20 s and still ended with no companion tools, because the attempt
  failed at its own timeout.
- The trade-off is the middle row: a cold-and-slow companion can miss the
  one-shot catalog. It keeps connecting, and a late merge is the same event
  `/mcp add` causes — the next request sees the tools and the prompt cache is
  busted from that turn (ADR 0221) — but it can also land after the run's last
  request and never be seen at all. Nothing here can both hold the first
  request and keep the catalog of a companion that has not answered.
- Interactive and ACP sessions are untouched: they queue the companion on
  `pending_starts` (ADR 0230) and never create a prewarm slot, so the budget
  exists only on the `-p` path. The one shared line, `Registry.deinitAtExit`,
  is a no-op when no slot exists.
- The worker now merges from a task thread rather than the boot thread. Every
  reader that matters takes the registry mutex (`snapshotTools`), the same
  assumption a deferred start's join already makes.
- Revisit by raising `default_budget_ms`, not by restoring the unbounded join;
  measure with `scripts/bench-startup.py --companion` plus a first-request
  body capture (the schema gate's `Deferred now:` line names what was left
  out).
