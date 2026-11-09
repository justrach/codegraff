# 0325. Kimi global vs. Mainland China OAuth region resolution and k3.1-pro catalog hydration

Status: accepted 2026-11-09

## Context

Kimi Code operates separate OAuth and API endpoints for global users (`https://auth.kimi.ai`, `https://api.kimi.com/coding/v1`) and Mainland China users (`https://auth.kimi.com`). Pinning a new `graff login kimi` to a previously saved region file prevented users from switching regions without manually deleting config files, while using the current environment heuristic during token refresh broke tokens minted on the other host (`0270cf47`). Additionally, newer Kimi models (`k3.1-pro`, `k3.1-pro-highspeed`, `k3-256k`) expose unified metadata (`limit.context`, `reasoning.type`, `reasoning.effort`) that the static catalog did not persist.

## Decision

- `oauth_kimi.chooseRegion` resolves the region for a new login from explicit environment overrides (`KIMI_REGION`, `KIMI_OAUTH_HOST`), `~/.kimi-code/region` / `~/.kimi/region`, and local timezone without locking onto a stale saved token's region.
- Token refresh always uses the `oauth_host` recorded inside the saved token credential itself, never re-guessing the host from the current environment.
- `kimi_catalog` parses unified model metadata (`limit.context`, `reasoning.type`, `reasoning.effort`), persists `~/.codegraff/kimi-models.json` on refresh, and surfaces `k3.1-pro`, `k3.1-pro-highspeed`, and `k3-256k` across `router_catalog`, `credential_failover`, `graff route`, CLI, and ACP model listings.

## Consequences

New Kimi logins follow the user's active region or override while existing tokens refresh reliably against the host that issued them, and `k3.1-pro` routes with accurate context and reasoning metadata offline and online.
