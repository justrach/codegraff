# 0003. Codegraff gateway wire follows model capability

Status: accepted 2026-08-17

## Context

The Codegraff gateway has one OpenAI-shaped public contract but two transport
capability sets. Chat Completions accepts every alias and translates Claude and
Gemini at the edge. Responses (HTTP or WebSocket) is native for OpenAI GPT-5.6+
(including Codex `gpt-5.6-*` and GPT-6 `gpt-6-astra`) and grok-4.6; Claude and
Gemini return 400 there. A frozen 5.6 alias list left later GPT generations on
Chat Completions, so `/compact` fell through to a client summarizer instead of
`/v1/responses/compact`. A single static provider wire therefore either leaves
native Responses features unused or breaks translated models.

## Decision

Resolve the Codegraff provider's wire per model. GPT-5.6 and every later GPT
generation (`gpt-5.6`, `gpt-5.6-sol`/`terra`/`luna`, `gpt-6-astra`, …) plus
`grok-4.6` use `/v1/responses` and may use its WebSocket transport. `/compact`
on Codegraff GPT uses the standalone `/responses/compact` endpoint, same as
direct OpenAI. Grok compaction stays on the client summary (xAI's blob path
when seated on xAI). Every other gateway alias uses `/v1/chat/completions`.

## Consequences

- GPT-5.6+ and GPT-6 receive native Responses request shapes, prompt cache
  keys, streaming events, the WS-to-SSE fallback ladder, and OpenAI server
  compaction. Grok-4.6 gets the same Responses wire, not OpenAI compact.
- Claude and Gemini remain on the edge-translated Chat Completions path.
- Switching models on one Codegraff credential must rebuild both `kind` and
  endpoint. New GPT generations matching `gpt-5.6*` or `gpt-{N>=6}*` join
  Responses without another allowlist edit; Claude/Gemini still must not.

Evidence: [Codegraff gateway contract](https://codegraff.com/docs/gateway).
