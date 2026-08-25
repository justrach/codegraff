# 0009. GPT-5.6 Platform gets an explicit prompt-cache boundary

Status: accepted 2026-08-18

## Context

GPT-5.6 caches only at eligible breakpoints and no longer falls back to the
longest matching unmarked prefix. Graff's large instructions/tool prefix is
stable, but separate sessions and sibling agents begin with different user
messages, so the default latest-message breakpoint can repeatedly write the
variable suffix instead of reusing the common prefix.

xAI has a different contract: caching is automatic over an exact append-only
message prefix, and `x-grok-conv-id` / `prompt_cache_key` provide per-conversation
server affinity. OpenAI-only breakpoint fields must not leak onto that wire.

A live OpenAI Platform GPT-5.6 Luna probe over the same 6,307-token prompt
wrote 6,304 cache tokens cold; the immediate repeat read 6,002 tokens and wrote
zero. The Codex subscription backend rejected `prompt_cache_options` as an
unsupported parameter, so its supported automatic/keyed path must remain.

## Decision

- OpenAI Platform Responses requests on `gpt-5.6*` prepend one stable developer
  `input_text` cache anchor after top-level instructions and mark it with an
  explicit breakpoint. Codex subscription, xAI, and older models receive
  neither the anchor nor Platform-only options.
- Root sessions use `prompt_cache_options.mode = "implicit"`: the explicit
  stable prefix remains reusable while append-only conversation turns keep the
  useful latest-message checkpoint. Subagents use `mode = "explicit"` so their
  unique task suffix is not written at 1.25× input price. Both use the documented
  30-minute TTL.
- Root OpenAI/Codex requests keep the durable project key. Child prefix traffic
  is deterministically spread over four stable role lanes to stay below the
  documented approximately 15 requests/minute per-key guidance while preserving
  reuse across repeated workflow roles. Codex uses this supported keyed,
  automatic path without explicit options.
- xAI keeps automatic prefix caching. Header `x-grok-conv-id` and body
  `prompt_cache_key` are the same sticky-routing id (official maximize-hits
  guidance). Root uses the project id; children share role lanes, not the
  root id and not a per-agent suffix. It never receives OpenAI Platform
  breakpoint/options fields.
- Cache writes are parsed separately from reads and ordinary input, shown in the
  cost summary, and billed at the documented 1.25× rate for GPT-5.6 and
  Anthropic ephemeral cache creation.

## Consequences

The cold request pays one cache write and adds a short, stable developer anchor;
warm sessions and repeated workflow roles can reuse the expensive instructions
and tool catalog even when their first user message differs. Exact-prefix
matching still prevents a stale prompt or tool catalog from being reused.

Provider/model gating is load-bearing: globally enabling these fields breaks
the current Codex subscription backend and would be unsupported on xAI/older
routes. Revisit the synthetic anchor if the API permits a breakpoint directly
on top-level instructions, or if live cache-write/read
measurements stop justifying the extra cold-write cost.
