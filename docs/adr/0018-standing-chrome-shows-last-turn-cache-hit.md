# 0018. Standing chrome shows last-turn cache hit

Status: accepted 2026-08-21

## Context

`/cache` already has session hit rate (ADR 0011). The standing line only
said `ctx N%` — window fill — so a 99% prompt-cache hit looked like
nothing happened. `cache_read` was already on `.prompt_ready`; the TUI
footer and the line-REPL meter just never printed the share.

## Decision

Last-turn hit rate (`cache_read / prompt tokens`) rides next to `ctx`
on both frontends:

- line REPL dim meter: `ctx 6% · cache 94%`
- TUI composer footer: ` ·  12% ·  94%c` (fixed-width; the `c` is cache)

Cache never appears without a context meter (no denominator). A measured
turn with zero cached tokens still prints `cache 0%` — the fun is
watching it jump. `/cache` stays the posture HUD.

## Consequences

A narrow pane may drop `cache` before `ctx` (same #209 right-to-left
budget). Do not substitute session hit rate here; that number lives
behind `/cache`.
