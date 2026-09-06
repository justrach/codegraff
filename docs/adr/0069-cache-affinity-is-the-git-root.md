# 0069. Prompt-cache affinity is the git root, not the leaf cwd

Status: accepted 2026-09-06

## Context

The in-house 12-task remasure on 289 held 12/12 and beat the 284 wall pin
(179.6s vs 219.6s) but list$ rose $0.3169 → $0.4205. Uncached input went
95k → 150k. `projectRootId` hashed the real cwd, so every eval sandbox
and worktree was its own xAI cache partition and paid the system+tools
prefix at `$2/M` instead of a cache read at `$0.50/M`. The
`cache-gitroot` fixture already named this: a temp dir with no `.git`
must not seed on its leaf cwd.

## Decision

The durable project cache id hashes the git root when one exists, otherwise
the constant scratch seed `graff-scratch`. Nested dirs in one repo share a
key. Scratch trees share one key. Do not hash the leaf cwd. Do not turn
`x_search` off or shrink the catalog to close list$ (ADR 0024 / 0031).

## Consequences

First request after the seed change is a one-time miss, then sibling
`-p` evals and worktrees can reuse the warm prefix. Unrelated scratch
jobs share a routing id and may evict each other's tails; the prefix
still hits when the bytes match. Revisit only if a same-session table
shows pass or wall regressing to buy the cache.

The offline guard is `affinity: two scratch sandboxes share one project
cache id` (tier 1 `cache-affinity-scratch`): two `/tmp` leaves must mint
the same UUID `projectRootId` would send. Hashing the leaf cwd is a
forced miss, asserted separately. No provider call.
