# 0159. Picker catalog refresh is bounded

Status: accepted 2026-09-22

## Context

Gateway aliases can change independently of harness releases. Cache-only
model menus hide new aliases until a later catalog refresh, while refreshing
every provider when opening a menu makes interaction depend on many networks.

## Decision

The line REPL model picker and desktop model catalog request may refresh the
gateway catalog using existing credentials. Limit the request to 500 ms and
2 MiB, and retry no more than once per 30 seconds in a harness process.
Replace only that provider's rows after a successful, nonempty parse. Keep
the previous catalog after transport errors, bad responses, or timeout.
Catalog refresh does not change the selected provider or model. Setting
confirmations request local state with `refresh: false` so they do not wait
for unrelated provider discovery; initial and picker-open requests refresh.

Other providers retain local cache hydration. The explicit full catalog
refresh command remains the way to refresh all providers.

## Consequences

New aliases become selectable without a rebuild. Opening a model surface
can add up to the bounded wait, and a slow endpoint leaves its previous
snapshot available. The offline HTTP regression checks authenticated GET,
new alias activation, malformed and empty replies, and timeout fallback.
