# 0345. Claude Dual Frontier, Separate Quota Pool, and Plan Ladders

Status: accepted 2026-11-15

## Context

Subscription worker routing (`subagent_tier_ladder.zig`, `subagent_selection.zig`, `subagent_pin.zig`) previously mapped `anthropic` with only `claude-opus-5-5 -> claude-sonnet-5-5`, omitted `claude-agent`, `chatgpt-new`, and `xai`, could not distinguish a separate subscription usage pool from the shared plan pool, and relied solely on static version strings when a live `/v1/models` catalog rotated releases. At the same time, cross-provider `sub_login` routing checked credential presence rather than `billing.costFor(...) == .plan`, risking cross-provider routing onto metered `XAI_API_KEY` or `ANTHROPIC_API_KEY` credentials.

## Decision

1. **Claude (`anthropic` & `claude-agent`) dual frontier & 3-rung descent:** Both providers declare `.frontier = "claude-opus-5-5"`, `.hard_frontier = "claude-fable-5-2"`, `.mid = "claude-sonnet-5-5"`, `.small = "claude-haiku-5-5"`. Default unpinned descent steps `opus-5-5` / `fable-5-2 -> sonnet-5-5 -> haiku-5-5 -> inherit`. Explicit `tier: "frontier"` uses `claude-opus-5-5`, while `tier: "frontier"` paired with `effort: "xhigh" | "max"` selects `claude-fable-5-2` when affordable (`freeAtTheMargin` on plans; cost-ceiling-guarded on metered API seats).
2. **Separate Fable quota pool across REPL, ACP, and quota recovery:** `billing.quotaPoolFor` marks `claude-fable-*` on `anthropic` / `claude-agent` plans as `.separate`. REPL `/models` renders `"plan*"`, ACP `graff/models` exposes `separateQuota: bool`, `agent_request_quota.stepDownSeparateQuotaPool` steps sideways to the shared-pool plan frontier (`claude-opus-5-5`) on quota exhaustion before promoting any parked metered key, and `claude_agent.problemForModel` notes the separate pool and `/model claude-opus-5-5` workaround.
3. **xAI (`grok-4.7` or nothing) & `chatgpt-new`:** `chatgpt-new` carries `.frontier = "gpt-6-astra"`, `.mid = "gpt-6.1-sol"`, `.small = "gpt-6-luna"` (keeping the GPT-6 inherit rule on unpinned workers). `xai` carries only `.frontier = "grok-4.7", .mid = "grok-4.7"`, ignores `bench_priors` downgrades onto legacy Grok releases, and leaves `.small = null` so cheap tasks can borrow another logged-in plan's small rung when available.
4. **Dynamic live-catalog fallback & plan-source gate:** `subagent_selection.liveLadderModel` resolves Claude families (`claude_wire.version`) and GPT tier suffixes dynamically from `pricing.models()` when a live catalog rotates past the compiled version (never substituting for `xai`), and `subscriptionRung` / `subscriptionModel` / `visionSeat` require `billing.costFor(sid, prov.source) == .plan`.

## Consequences

- Separate-pool exhaustion degrades gracefully within the user's Claude plan instead of abruptly jumping to pay-per-token billing, and metered API keys cannot impersonate flat-rate plans.
- Adding a future Fable or Frontier release automatically routes through `liveLadderModel` until the next binary release updates `ladders`.
