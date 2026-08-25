# 0011. Prompt-cache max is a visible posture, not a new default

Status: accepted 2026-08-19

## Context

v0.0.266 already earned the cacheable prefix: sticky `prompt_cache_key`,
names-only skill catalog pinned once, standing goal as one prefix line,
Anthropic `cache_control`, GPT-5.6 explicit breakpoint (ADR 0009), per-agent
partitions, no timestamps. #476 still listed cache-rate as the remaining gap
(~45–58% vs opencode ~85%). The leftover automatic bust is `load_tool_schemas`
rewriting tools JSON. `GRAFF_STABLE_CATALOG=1` exists for that and **measured
empty** on the v0.0.246 audit, so it stays off.

What you could not see: whether this session's prefix was still the same
bytes, which named mutation last moved it, or which remaining levers are
intentional. `/debug` counted tokens; it did not say why a miss happened.

## Decision

- `/cache` is the content-free cache HUD: prefix hash, last read/write,
  session hit rate, catalog mode, last bust reason, xAI affinity
  (`x-grok-conv-id` + `x-grok-session-id` + `prompt_cache_key`), and the
  remaining max levers. No prompt text, paths, or tool bodies.
- `/debug` gets one cache row from the same snapshot.
- Named busts (`goal`, `playbook`, `compact`, `persona`, `tools`, `mcp`) are
  recorded at the mutation site and counted only when the next request's
  system+tools hash actually changes. Startup compose is not a bust.
- `GRAFF_STABLE_CATALOG` is the default (2026-08-25). RLM default makes
  `load_tool_schemas("rlm")` a guaranteed first-turn load; rewriting tools
  JSON there was a 0% cache-read on the next call. The loaded schema still
  rides the load result; the catalog head stays byte-identical. Opt out
  with `GRAFF_STABLE_CATALOG=0` or `GRAFF_NO_STABLE_CATALOG=1`. Do not move
  playbook / compact notes / standing goal off the prefix — those ride the
  system prompt on purpose (ADR 0005, #381, #391) and already share the
  compaction boundary.
- `/btw` is a grok-build side-call: same system prompt, same tools JSON, same
  `prompt_cache_key` as the parent. The side-question note is appended as a
  user message. Tools are advertised for the prefix and not executed.

## Consequences

A `/cache` after a miss names the lever. Stable-catalog is now the default
so an `rlm` (or MCP) load does not rewrite the tools prefix. Children
inherit the process-global catalog mode.

Subagents (2026-08-25): children share four role-lane `x-grok-conv-id` /
`prompt_cache_key` values so sibling scouts with the same system+tools
land on the same xAI server (official sticky routing). They do not reuse
the root id — the child prefix is a different messages array. A
per-agent pointer suffix was a forced miss.

Live Grok 4.6 (Responses, SuperGrok OAuth, 2026-08-19): same-process
append-only turn 2 cached 3,712 of turn 1's 3,721 input tokens. `/btw` after
that turn reused **3,712** tokens (99.8% of the prior prompt). A new process
in the same folder started cold at 128 — the official first-request write.
