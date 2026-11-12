# 0340. A cold catalog cache never holds boot

Status: accepted 2026-11-12

## Context

`startup.resolveKeysOptional` runs `router_catalog.ensureForStartup` before the
prompt. For every keyed dynamic provider with **no** disk cache it started a
live `/v1/models` GET and waited for it in `catalog_bounded.Batch.wait` (a 5 ms
poll, capped at `startup_budget`, 800 ms). A cached catalog, fresh or stale,
never waited: it activated and refreshed behind. So the wait was paid exactly
when there was nothing on disk — every first-ever boot, every fresh `HOME`, and
every boot after a rejected key, because a 401 writes no cache.

Anthropic is dynamic (`models_url` `https://api.anthropic.com/v1/models`), so a
run with an Anthropic key and no cache paid one TLS round trip to that host
before it accepted a keystroke: 237-261 ms by `curl` from the machine measured,
plus the poll quantum and the thread spawn. An external startup benchmark
(fresh `HOME`, tmux, loopback mock model, dummy OpenAI and Anthropic keys)
reads exactly that: time to first accepted keystroke ~310-320 ms with both keys,
~71-76 ms with only the OpenAI key (OpenAI's list is baked, nothing spawns).

The list only feeds the model pickers, `/models`, and context windows of
discovered rows. The baked rows in `pricing.zig` are the documented fallback
and already what a boot sees when the fetch misses the budget or fails.

## Decision

- **A cold cache detaches, like a stale one.** `startSpec` (now in
  `router_catalog_boot.zig`) activates a fresh or stale cache exactly as
  before; with no cache it marks the provider in `catalog_landing` and hands
  the fetch to `catalog_bounded.detach`. Boot proceeds on the baked rows. Kimi's
  account catalog takes the same path in `startKimi`, with its existing
  `"baked fallback — live catalog still loading"` source line.
- **The list activates when the fetch lands, on the main thread.** The worker
  cannot touch the model table or the session arena, so it only reports
  (`catalog_landing.settle`: static atomics). `activateLanded` takes each
  landed slot once and activates the cache the worker wrote; it runs at the
  top of `router_catalog.ensureForQuery`, the beat every `/model` picker,
  `set_model`, and the stdin chat REPL already go through. `/models` refetches
  live anyway (`refreshForListing`), and `--schema` / ACP model options read
  every cache (`loadCachedAll`); ACP model options also run `activateLanded`
  at every `acp_model_option.hydrate`, the same beat shape as the REPL picker.
  A stale cache's refresh is not marked, so it
  still lands for the next process only — that path is byte-for-byte unchanged.
- **One case still waits, bounded as before: a `--model` the baked rows cannot
  resolve.** Startup resolves `--model` before the prompt and fatals on an
  unknown row (`qualifiedProvider`, `resolveModelName`). On a cold cache a model
  the provider serves but the baked table lacks would be refused without the
  live list, so `needsLiveRows` keeps that fetch in the batch under
  `startup_budget`. A provider name, an exact baked row, a saved model (a
  catalog omission never changes it), or no flag never waits.
- **Failure stays quiet and is not retried.** A failed or rejected fetch
  clears its landing mark, activates nothing, and writes no cache. Its status
  is recorded in `catalog_failures` as before, which only the listing commands
  print; boot prints nothing. The once-per-process attempt latch is set before
  the detach, so neither `ensureForQuery` nor a second startup pass starts
  another GET. The next process tries once more, as it always did.
- **Exit never waits for the worker, and the worker writes nothing exit
  frees.** As in ADR 0336 and `catalog_bounded`, joining is not an option: a
  worker parked in `getaddrinfo` cannot be cancelled. Unlike ADR 0339's late
  merge, nothing here needs a `stopAtExit`, because the worker's only outputs
  are the cache file (an atomic replace), its own `smp_allocator` task, and
  static atomics (`catalog_landing`, `catalog_failures`). The one input that
  lived in freed memory was the workspace router's spec, parsed into the
  session arena that `main` frees on return; `router_config.load` now copies
  its strings into never-freed memory (`outliveSession`), which also covers
  the stale-refresh and over-budget paths that already detached it.

## Consequences

- Measured with the same external rig and measurement path, `graff` REPL,
  fresh `HOME`, both dummy keys, binaries built with
  `zig build graff -Doptimize=ReleaseSafe -Dlearn=false` from the base and from
  this change, three rounds of n=12 each, alternating before/after: time to
  first accepted keystroke **312.0 ms before (n=36, 298.3-340.1, IQR
  305.9-322.7) → 57.2 ms after (n=36, 55.0-74.3, IQR 56.0-61.3)**. The
  catalog still lands: with a loopback `/v1/models` behind a Z.AI key
  (`GRAFF_ZAI_URL`), a fresh-`HOME` boot writes `zai-models.json` while
  sitting at the prompt, the first `/model` picker lists the fetched rows, and
  a later `graff models` lists them from the cache with the endpoint down.
  The dummy Anthropic key itself gets a 401, so that run writes no cache.
- **The trade-off: a first-ever boot's `/model` picker briefly shows baked
  rows.** Until the fetch lands (one round trip, ~250 ms against Anthropic) the
  provider's slice is the baked one; the first picker opened after that shows
  the live list. ACP model options read the caches once per live session
  (`acp_model_option.hydrate`), so a session built before the landing kept
  the baked list until a `/model`. That gap is now closed and measured:
  `hydrate` runs `activateLanded` on every beat, and with a fresh `HOME`, a
  loopback `/v1/models` behind a dummy Z.AI key (`GRAFF_ZAI_URL`) answering
  after 1.2 s, and `graff acp` initialized as t3-code, `session/new` before
  the landing served the 7 baked zai rows; after the fetch landed, the same
  session's model options (re-read through a `session/set_config_option`
  response) and the `graff/models` view listed the landed row, no `/model`
  issued — the pre-fix binary kept the 7 baked rows on both re-reads. A boot
  whose fetch fails sees the baked rows, as it did when the fetch failed
  inside the budget.
- **Rejected: a small blocking budget (e.g. 100 ms) on a cold cache.** It still
  adds up to that much to every first keystroke, and the fetch it protects is
  ~250 ms to a real provider, so it would almost always expire anyway and buy
  nothing but the delay. The one boot whose correctness depends on the live
  list — `--model` naming an unbaked row — keeps the full budget instead.
- A cold `--model` that names an unbaked row still pays up to 800 ms, as before.
  Revisit if that shows up in a benchmark; the fix there is a lazy model
  validation, not a shorter wait.
- Tests (`router_catalog_boot_tests.zig`) drive the real `ensureForStartup`
  against a loopback catalog that answers after `startup_budget + 700` ms:
  boot returns in under a quarter of the budget, the list activates through
  `ensureForQuery` once the worker lands, a stale cache still activates now and
  refreshes for the next process, a 401 activates nothing and starts no second
  GET. Restoring the batched cold path fails the first at its elapsed-time
  assertion; dropping the `activateLanded` call fails it at the activation.
  `acp_model_option.zig` pins the ACP half: a session that hydrated before a
  landing must activate the landed rows on its next `hydrate`, and removing
  that call fails the test at the same assertion (mutation-verified in a
  tree copy).
