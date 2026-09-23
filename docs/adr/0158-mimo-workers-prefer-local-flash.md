# 0158. MiMo workers prefer local Flash

Status: accepted 2026-09-22

## Context

MiMo-V2.6-Pro and Flash are in the catalog, but the worker ladder has no
Xiaomi entry. An explicit small-tier request can therefore jump from a MiMo
session to a signed-in Luna subscription. The shipped DeepSWE snapshot
predates these MiMo models and cannot establish their relative quality.

## Decision

Use Pro as Xiaomi's frontier and Flash as its small worker default. Keep
MiMo tier requests on that provider even when another subscription is
available. On the multi-vendor provider, prefer this pair only when its live
catalog contains both models; preserve the existing DeepSeek family policy.
Keep automatic routing within its price ceiling. Exact model pins and
explicit provider selections remain authoritative.

This is a release routing preference, not a fabricated benchmark result.
Do not insert guessed MiMo scores into the DeepSWE table. Other providers
continue using models they actually serve; changing to a metered provider
still uses the explicit cross-provider selection path.

## Evidence

- [Pro model and pricing](https://mimo.mi.com/models/en-US/mimo-v2.6-pro)
- [Flash model and pricing](https://mimo.mi.com/models/zh-CN/mimo-v2.6-flash)
- [DeepSWE leaderboard](https://deepswe.datacurve.ai/)
- `src/subagent_mimo_tests.zig` verifies local routing, live availability,
  exact-pin precedence, and the cross-provider boundary.
