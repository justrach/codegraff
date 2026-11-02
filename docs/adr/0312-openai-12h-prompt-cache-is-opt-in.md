# 0312. OpenAI Platform 12-hour prompt cache on the stable prefix is opt-in

Status: accepted 2026-11-02 (proposed 2026-10-21 as 0298)

## Context

On 2026-10-20 OpenAI added a 12-hour minimum lifetime for prompt-cache
writes on GPT-5.6 and later, in the Responses API only. A 12-hour write
costs 2.5× uncached input; a 30-minute write stays 1.25×. Reads stay 0.1×
(0.05× on GPT-6.1 Sol). Chat Completions currently accepts only `ttl:
"30m"`; sending `12h` there, or to older models, is a 400
`invalid_request_error`. Older models keep the separate
`prompt_cache_retention` parameter.

ADR 0009 already marks graff's stable instructions/tools prefix with an
explicit breakpoint and uses a 30-minute request TTL. Long-lived sessions
pay to rewrite that prefix after a 30-minute gap.

## Decision

- On the direct OpenAI Responses route for GPT-5.6 and later, with 12h
  selected, the stable prefix breakpoint sends
  `prompt_cache_breakpoint.ttl = "12h"`. The request keeps
  `prompt_cache_options.ttl = "30m"` for session context. The current user
  turn is never marked.
- `GRAFF_OPENAI_CACHE_TTL` / `.harness/settings.json` `openai_cache_ttl`
  select `30m` (default, ADR 0009 bytes), `12h`, or `off`.
- 12h is opt-in until a live probe records it. The API reference still
  documents only `"30m"`, an unsupported value is a 400 on every request,
  and a 12-hour write costs 2.5× uncached input against 1.25×, so the
  default changes only after `scripts/openai_cache_retention_probe write`
  succeeds and a later `--check` shows the prefix still cached.
- Chat Completions, Codex, ChatGPT-new, xAI, and models before GPT-5.6
  receive no new fields.
- `prompt_cache_key` is unchanged. Usage parses `cached_tokens`,
  `cache_write_tokens`, and `cache_write_tokens_details`.

## Consequences

With the default nothing changes on the wire. The cold prefix write costs 2.5× instead of 1.25× when 12h is on. A later
request hours later can still read that prefix. Codex remains on its
keyed automatic path: it 400s on `prompt_cache_options`.
