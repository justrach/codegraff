# 0329. Scoped mcp_cache single-server cloning, same-plan subscription failover, and ACP policy-refusal classification

Status: accepted 2026-11-09

## Context

Three issues surfaced across long-running ACP sessions (`f93feeb4`, `676746da`, #1756, #1822):

1. `mcp_cache.lookupWith`, `mcp_cache.store`, and `mcp_cache.forget` parsed the shared multi-server `mcp-list-cache.json` directly into the caller's long-lived arena, retaining the full JSON parse tree of every cached MCP server per server lookup.
2. When a user had multiple ChatGPT subscription credentials configured on the same plan (e.g., `chatgpt-new` and `codex`) and the primary token failed authentication mid-session, `providers.runTurnWithFallback` did not try the sibling same-plan credential before surfacing an auth failure.
3. When OpenAI Responses rejected a request mid-stream with `cyber_policy_violation`, `content_policy_violation`, or `request_rejected` (including nested `response.failed` / `response.incomplete` payloads), `acp_prompt_err` only matched HTTP 400 status text and fell back to a generic error or left the model guessing that encrypted compaction state had failed.

## Decision

- `mcp_cache` parses `mcp-list-cache.json` inside a scoped temporary arena freed on `defer` and clones only the single matched server's `protocol_version` and `tools` slice into the caller's arena. `agent_ws.postResponsesWs` and `session_workspaces.remember` likewise use per-request/scoped scratch arenas.
- `providers.runTurnWithFallback` checks `sameChatgptPlanFallback` on subscription authentication failure and retries once on a configured sibling subscription seat before failing the turn.
- `sse_Responses.parseErrorEvent`, `providers.classifyProviderFailure`, and `acp_prompt_err.classify` extract and classify `cyber_policy_violation`, `content_policy_violation`, `safety_violation`, and `request_rejected` across both HTTP status bodies and in-stream SSE/WebSocket `response.failed` events, surfacing the provider's refusal reason and `_meta["graff/error"]` (`category: "policy_refusal"`) verbatim on ACP.

## Consequences

Multi-server MCP caches no longer multiply memory across lookups, sibling subscription seats recover seamlessly from single-token expiry, and provider safety/cyber policy flags are reported accurately on ACP instead of being misdiagnosed as compaction bugs.
