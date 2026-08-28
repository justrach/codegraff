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
  session hit rate, catalog mode, last bust reason, and the live wire's
  affinity (xAI keyed headers, Codex `session_id` = `prompt_cache_key`,
  OpenAI Platform breakpoint, Claude explicit `cache_control` on tools +
  system + last message, Kimi automatic prefix + chat `prompt_cache_key`).
  Remaining max levers stay listed. No prompt text, paths, or tool bodies.
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
- Root affinity (`x-grok-conv-id` / `prompt_cache_key`) is the **git root**,
  not the leaf cwd. No repo → the constant `graff-scratch`. Do not hash cwd:
  sibling sandboxes and worktrees share one prefix and must share one key.

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

Affinity seed (2026-08-28 rematch): the root key is the **git root**, not
the leaf cwd (`graff-scratch` when there is no repo). xAI partitions cache
by `prompt_cache_key`; a cwd-derived id made every graff-evals sandbox a
cold ~8k write (first-call cache 0–512) while grok-build's first calls
arrived already warm (11k–43k). Prefix bytes still have to match — this
only stops an identical system+tools prefix missing because the sandbox
path changed. Worktrees of one repo share; a repo CLAUDE.md still misses
another repo.

Claude (2026-08-28): mark `cache_control` on the last tool, the system
block, and the last cacheable message. A system-only mark still hashes
tools (they precede system), but a long tool loop walks the 20-block
lookback off that write; the tools breakpoint is the earlier slot. Do
not send top-level automatic `cache_control` next to those three marks
(fourth slot / no-op). MiniMax stays unmarked.

Kimi (2026-08-28): chat sends `prompt_cache_key` (coding-agent / Code
Plan). Anthropic-transport Kimi still gets the three explicit marks;
the server hashes the prefix either way.
