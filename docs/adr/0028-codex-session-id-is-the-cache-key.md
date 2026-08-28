# 0028. Codex session_id is the prompt_cache_key

Status: accepted 2026-08-25

## Context

[openai/codex](https://github.com/openai/codex) `ModelClient::prompt_cache_key`
defaults to `CodexResponsesMetadata.session_id`. The same string is sent as the
`session_id` header (`build_session_headers`). A hit needs that key plus an
identical instructions/tools prefix.

Graff already sent a durable cwd `prompt_cache_key` (ADR 0009). The ChatGPT
`session_id` header was a **per-process UUIDv4**. Trajectories of a live Codex
session (`gpt-5.6-sol`) still recorded multi-million `cache_read_tokens` on
later calls in a turn, and 0/0 on turns whose usage never landed in `g_cost`.
The first-party client never splits those two ids.

The 2026-08-28 rematch then showed the cwd-derived root id made every sibling
sandbox a cold write. ADR 0011 now seeds the root with the git root (or
`graff-scratch`). Codex uses that same id — it does not get a second scheme.
The ChatGPT backend still rejects `prompt_cache_options` /
`prompt_cache_breakpoint` (openai/codex#35300); do not add them.

## Decision

- Codex `session_id` (HTTP extra headers and the WS handshake) is the same
  value as the Responses body's `prompt_cache_key` (`requestCacheKey`:
  git-root / `graff-scratch` for main/`/btw`, four role lanes for children).
- `sessionId()` stays a per-process UUIDv4 for the persisted graff session
  record. It is not the ChatGPT cache partition.
- `store: false` is unchanged (openai/codex also sends `store: false`).
- `/cache` names the Codex key the same way it names the xAI key.

## Cost

ChatGPT session telemetry now groups by project/lane rather than process.
That is the cache contract. Do not restore a random `session_id` header
without measuring a live `cached_tokens` regression. Do not emit a GPT-5.6
Platform breakpoint on this wire.
