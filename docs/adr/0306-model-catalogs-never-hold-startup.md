# 0306. Model catalogs never hold startup or `graff/models`

Status: accepted 2026-10-28

## Context

ACP clients discover models by spawning `graff acp` and sending
`initialize`, `session/new`, and `graff/models` under one short timeout.
Boot awaited every live catalog GET: Kimi's account catalog on every start
(it had no disk cache), and every router catalog whose cache was older than
its TTL. The `graff/models` gateway refresh had a 500ms deadline, but on
timeout it cancelled and joined its HTTP worker, and a worker parked in DNS
or TLS cannot be cancelled. A cold DNS lookup or a slow host held
`initialize` for 10 to 40 seconds and the client reported "graff model
discovery timed out". The fleet elite pull used `io.async`, which runs
inline when the pool is busy, so boot also waited on its 3s deadline.

## Decision

Catalog GETs run on detached threads (`catalog_bounded.zig`) with their own
`Io` and allocator, and their only output is the disk cache.

- A cached catalog, fresh or stale, activates immediately. A stale one (and
  xAI's, always) refreshes behind it; nothing waits.
- Only catalogs with no cache wait, together, for at most
  `startup_budget` (800ms). A fetch that misses it is abandoned, not
  cancelled, and still writes its cache for the next process.
- Kimi's catalog is cached at `~/.codegraff/kimi-models.json` with a 6h TTL.
- The `graff/models` gateway refresh uses the same worker, so its 500ms
  deadline holds.
- The fleet elite pull starts with `io.concurrent`, falling back to `async`.

`/models` and `graff models` remain the blocking freshness moments.

## Consequences

The first start on a slow network, with no cache, may show baked rows for a
provider until the next process. An abandoned worker keeps running until its
own HTTP timeout; it touches no session state, so exit does not wait for it.
