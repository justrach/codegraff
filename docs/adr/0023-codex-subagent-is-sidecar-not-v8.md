# 0023. Codex is a check, not a runtime: sidecar spawn, no V8 Code Mode

Status: accepted 2026-08-25

## Context

[openai/codex](https://github.com/openai/codex) is the closest production
harness to graff's Responses-wire + subagent + "tools as functions" shape.
A double-check against `codex-rs` (2026-08-25 tree) asked whether we should
copy Code Mode, `spawn_agent`, or their prompt-cache keying.

Codex **Code Mode** is an in-process V8 heap
(`codex-rs/code-mode-runtime`): tools become JS functions on `tools.*`,
with `store`/`load` cells and a yield. That is the same *idea* as graff
`rlm` (spec-ptc + persistent binds), implemented as a JavaScript runtime.

Codex **spawn_agent** (`multi_agents_v1`) starts a cold child thread: no
parent history by default, depth-capped, optional `fork_context`. The
always-on tool description hides the model-picker essay
(`hide_spawn_agent_metadata`) and spends its tokens on *when* to delegate:
keep the critical-path next step local; spawn only bounded sidecar work
that can run beside it; disjoint write sets; do not set `model` unless
the user asked. `prompt_cache_key` is the session id; internal/guardian
sessions reuse `{source}:{parent_thread_id}` when they share a prefix.

## Decision

Take Codex's **sidecar vs critical-path** rule into graff's advertised
prompts (`subagent` catalog desc, `rlm` tool desc, `rlm_spec.system_note`).
Drop the routing/tier essay from the always-on `subagent` description —
field schemas still carry pins; Codex was right that the essay does not
belong on every prefix.

Reject the rest:

- **V8 / Code Mode.** graff `rlm` is already the Zig analog. A JS heap
  would raise RSS for no product win (ADR 0022: no IPython, no Python
  kernel; same reason).
- **`spawn_agent` / `wait_agent` / `close_agent` / `send_input`.** graff
  already has `subagent` + `agent_output` + `run_in_background`. Extra
  catalog tools would break the fold and the 64-cell kernel.
- **Inherit or fork parent history.** Codex's default is cold; so is
  `execSubagent` (fresh arena, fresh history). Forking is a token/RSS bomb.
- **Share the root `prompt_cache_key` with children.** Codex does that
  only when the prefix is actually shared (guardian). graff children have
  a different system+tools prefix; they stay on role-lane keys (ADR 0011).
  `/btw` already shares the parent key, same as Codex recap.
- **ExplicitRequestOnly spawn.** Codex has a mode that forbids spawning
  unless AGENTS.md asked. Graff stays proactive (Codex's other mode):
  sidecar parallelism is the product.

## Consequences

- Catalog prefix shrinks (the old `subagent` desc was a routing essay).
  That is a one-time cache miss, then a smaller stable prefix.
- Models are told not to hand the blocker to a child and wait — the
  failure mode Codex's tests pin (`spawn_agent` must not push a smaller
  model by default; wait-by-reflex is called out).
- Cross-harness A/B against the Codex CLI is not runnable here without a
  ChatGPT login. Architecture compare is the evidence; live numbers stay
  graff `--old` vs default RLM (ADR 0022).
