# 0350. Non-blocking 5-minute catalog revalidation and in-session `/refresh`

Status: accepted 2026-11-19

## Context

ADR 0340 eliminated boot blocking on cold model catalogs, leaving three gaps
that kept newly released models (such as `gpt-6.2-sol` and `gpt-6.2-astra`) from
appearing without manual CLI steps or restarts:

1. Router catalogs kept a 6-hour refresh threshold with no background
   revalidation for caches younger than 6 hours (except xAI), and stale-cache
   background refreshes were not marked in `catalog_landing` so they waited for
   the next process restart.
2. Codex account discovery had no detached background refresh at boot, its
   offline version check ignored newer native Codex caches whenever an older
   `codex-models.json` existed, and `chatgpt-new`'s `client_version` query was
   pinned at `0.159.0`, hiding newer models gated on newer client versions.
3. ACP `graff/models` only refreshed the `codegraff` gateway, ignored explicit
   `{"force": true}` requests, and sessions had no `/refresh` slash command.

## Decision

- **Preserve 0 ms boot blocking while revalidating every 5 minutes in the
  background.** At startup, any on-disk cache still activates immediately. When
  a keyed dynamic provider's cache is absent or older than 5 minutes
  (`router_catalog.background_revalidate_ms`), or Codex's cache is absent,
  older than 5 minutes, or behind `codex_client_version_floor` (`0.170.0`),
  boot marks its slot in `catalog_landing` and detaches a `catalog_bounded`
  worker. Landed refreshes activate on the main thread at the next model-surface
  beat (`activateLanded`) without a restart.
- **Keep `graff/models` fast by default and support bounded `{"force": true}`.**
  Ordinary `graff/models` calls activate landed refreshes and trigger throttled
  non-blocking background revalidation (`catalog_refresh.detachStaleAll`);
  `{"force": true}` runs a bounded concurrent batch across all signed-in
  dynamic providers (including Codex and Kimi) before returning rows.
  `{"refresh": false}` remains strictly local.
- **Add `/refresh` (and `/models refresh`) across REPL and ACP.** Both surfaces
  share `commands_refresh.tryHandle`, refreshing all signed-in dynamic
  providers and Codex in-session and emitting ACP `config_option_update` when
  the offered model list changes.

## Consequences

- Boot time remains unblocked by network I/O (ADR 0340).
- New provider model rollouts appear within minutes automatically and on demand
  via `/refresh` or `graff/models {"force": true}` without restarting.
