# 0346. ACP Accounts, Plan Usage Windows, and Live Rate-Limit Tracking

Status: accepted 2026-11-15

## Context

Subscription logins (`codex`, `chatgpt-new`, `anthropic`, `claude-agent`, `xai`, `codegraff`, `kimi`) carry account identities, billing tiers, and provider rate-limit windows that previously required running `/usage` in the REPL for only a subset of providers, left ACP clients without a way to query signed-in accounts or per-session remaining quota, and could not skip an exhausted separate-quota model (`claude-fable-5-2`) until a turn actually failed with a quota error.

## Decision

1. **Live rate-limit cache and separate-pool bypass:** `plan_usage_live` maintains a fixed-slot mutex-guarded snapshot cache across HTTP headers (`x-codex-*`, `anthropic-ratelimit-*`, `x-ratelimit-*`), Responses WebSocket `codex.rate_limits` frames, and Claude Agent `rate_limit_event` frames, paired with an atomic `g_blocked_mask` queried synchronously (`isModelBlocked`) by `subagent_pin` so exhausted `hard_frontier` capacity steps directly onto `claude-opus-5-5` without incurring a failing turn.
2. **Unified multi-account & usage reporting (REPL and ACP):** `plan_accounts` and `plan_accounts_probe` collect redacted `AccountEntry` records (email, display name, organization, plan badge, prepaid/reset credits, and usage windows — never tokens or keys) across all signed-in providers (`codex`, `chatgpt-new`, `anthropic`, `claude-agent`, `xai`, `codegraff`, `kimi`), surfaced identically in `/usage` and `/cost` on the REPL and via ACP `graff/accounts` / `_codegraff/accounts` (`{"probe": bool}`). Credential profile metadata (`0600` atomic writes) is persisted alongside OAuth tokens.
3. **ACP advertisements & live usage windows:** `initialize` advertises `_meta["codegraff/accounts"]: true` and all 7 terminal `authMethods` (`graff-login`, `graff-login-anthropic`, `graff-login-claude-agent`, `graff-login-chatgpt-new`, `graff-login-codex`, `graff-login-xai`, `graff-login-kimi`), while `_codegraff/usage` attaches `planWindows` from the active provider's cached live windows.

## Consequences

- ACP clients (including Harness and Zeron) can render signed-in identities, remaining plan usage bars, and provider login choices without shelling out or touching secret stores directly.
- Adding a new provider sign-in or rate-limit window requires updating only `plan_accounts` / `plan_accounts_probe` / `plan_usage_live` while preserving the single REPL+ACP contract.
