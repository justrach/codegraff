# 0010. Prompt-cache max is a visible posture, not a new default

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
  session hit rate, catalog mode, last bust reason, and the remaining max
  levers. No prompt text, paths, or tool bodies.
- `/debug` gets one cache row from the same snapshot.
- Named busts (`goal`, `playbook`, `compact`, `persona`, `tools`, `mcp`) are
  recorded at the mutation site and counted only when the next request's
  system+tools hash actually changes. Startup compose is not a bust.
- Do not default `GRAFF_STABLE_CATALOG`. Do not move playbook / compact notes
  / standing goal off the prefix — those ride the system prompt on purpose
  (ADR 0005, #381, #391) and already share the compaction boundary.

## Consequences

A `/cache` after a miss names the lever. Revisit defaulting stable-catalog
only if a new live measurement shows load-after-load cache-read returning
from 0% without discovery or compaction regressions.
