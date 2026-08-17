# 0003. Codegraff gateway wire follows model capability

Status: accepted 2026-08-17

## Context

The Codegraff gateway has one OpenAI-shaped public contract but two transport
capability sets. Chat Completions accepts every alias and translates Claude and
Gemini at the edge. Responses (HTTP or WebSocket) is native only for the
GPT-5.6 family and grok-4.6; Claude and Gemini return 400 there. A single static
provider wire therefore either leaves native Responses features unused or
breaks translated models.

## Decision

Resolve the Codegraff provider's wire per model. `gpt-5.6`,
`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, and `grok-4.6` use
`/v1/responses` and may use its WebSocket transport. Every other gateway alias
uses `/v1/chat/completions` unless the public gateway contract adds it to the
native Responses set.

## Consequences

- GPT-5.6 and grok-4.6 receive native Responses request shapes, prompt cache
  keys, streaming events, and the WS-to-SSE fallback ladder.
- Claude and Gemini remain on the edge-translated Chat Completions path.
- Switching models on one Codegraff credential must rebuild both `kind` and
  endpoint; the allowlist is the contract boundary and needs updating when the
  gateway adds another native Responses family.

Evidence: [Codegraff gateway contract](https://codegraff.com/docs/gateway).
