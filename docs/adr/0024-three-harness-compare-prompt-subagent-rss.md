# 0024. Steal prompt/subagent craft from grok-build, kimi-cli, dsh — not their runtimes

Status: accepted 2026-08-25

## Context

PR 621 made `rlm` the default loop (ADR 0022) and turned prompt-cache
max on (ADR 0011: stable catalog, role-lane child `x-grok-conv-id`).
A follow-up asked whether
[grok-build](https://github.com/xai-org/grok-build),
[kimi-cli](https://github.com/MoonshotAI/kimi-cli), or
[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
beat that story on cache, child spawn, prompt tokens, or RSS.

Cloned 2026-08-25 (shallow). None of the three binaries ran here:
grok-build needs Rust + DotSlash (or `x.ai/cli` install + an xAI
account the SuperGrok OAuth file does not unlock as `grok`); kimi-cli
is Python and wants a Moonshot login; dsh is a pnpm/Node plugin host
and wants a DeepSeek key. Architecture is the evidence; live numbers
are graff `--old` vs default RLM (see below, filled after the A/B).

## Decision

**Take (Zig, no IPython, no new catalog tool):**

| Source | What | Why it beats us |
|---|---|---|
| grok-build | Short focused child prompt; "do not broaden"; parallelize independent calls | Their `subagent_prompt.md` is a worker brief, not a copy of the root. Ours was already shorter; we tighten it further. Role-lane conv-id and `/btw` parent-prefix already landed in ADR 0011 — nothing left to steal there. |
| grok-build | Recap/`/btw` share the *parent* `prompt_cache_key` | Already ours. Do not extend that to children. |
| kimi-cli | Persist the child's system prompt on first run; "do not narrate tool calls" | Persist-binds already cover REPL state. Narration tax is real on children — one line on `sub_system_prompt`. Resume-existing-child is a feature, not a cheap win. |
| kimi-cli | Default foreground; `run_in_background` only when the result is not the next step | Same as Codex sidecar (ADR 0023). Already in the shortened `subagent` desc. |
| dsh | PromptContext as a *user-role* snapshot so the system prefix stays byte-stable | Standing goal already does this (ADR 0005). In-process spawn (not fork) is already ours. Child catalog is already `base_specs` comptime JSON — shared bytes, not rebuilt. |
| Codex (ADR 0023) | Sidecar vs critical-path; drop the routing essay from the always-on `subagent` desc | Catalog prefix shrink. Kept. |

**Reject:**

| Source | What | Why |
|---|---|---|
| grok-build | Share the root `x-grok-conv-id` / `prompt_cache_key` with children | Official xAI cache is keyed on conv-id + prefix. Children have a different system+tools array. Role-lane among *siblings* is the win (ADR 0011). Sharing the root id is a forced miss. Do not make the child prompt start with the root prompt to "share prefix" — without a shared key the bytes do not cache. |
| grok-build | `resume_from` a completed child transcript | Token/RSS bomb; we already persist binds on the *root* REPL. |
| grok-build | Memory search / hashline edit workflow | Different product. |
| kimi-cli | `${KIMI_NOW}` and a workdir listing in the system prompt | Cache-bust factory (datetime every minute, tree every file change). We already refuse timestamps on the prefix. |
| kimi-cli | IPython / Python REPL / huge `system.md` | Longer than ours. ADR 0022: no IPython. |
| kimi-cli | Inject AGENTS.md + skill bodies into every system prompt | We load skills on demand. |
| dsh | Harbor / Pier / full DeepSWE | Out of scope. We have DeepSWE-SHAPED local tasks 17–22. |
| dsh | Fork-seed parent history into the child | Codex default is cold; so is `execSubagent`. Seeding is a token/RSS bomb (ADR 0023). |
| dsh | Plugin host, continuable Activation graph, `send_message`/`list_agents` | Extra catalog tools. We have `subagent` + `agent_output`. |
| all three | A Python/Node/Rust fan-out process | Product stays Zig. `graff-evals/run.py` only launches `graff`. |

**Prompt hell-optimize (this revision):**

- `rlm_spec.system_note` stays on the root prefix only (children use
  `sub_system_prompt` — they never see `rlm(code)`). Shorten the note
  without dropping persist / sidecar / print.
- Child brief: do not broaden, do not narrate tool calls (grok + kimi).
- Do not reshuffle messages. Keep `reasoning_content` replay (already
  pinned; grok's official top Chat cache-miss cause).
- `rlm` stays folded; it is not added to `--schema` / `optional_specs` /
  the 64-cell kernel, and it is never the only catalog tool.

**RSS:** children are in-process (`runSub` builds an `Agent` on a
per-spawn arena, comptime `sub_system_prompt`, comptime child tools
JSON). No allocator rewrite. Peak RSS is a column in
`graff-evals/run.py` (`rss_peak_kb` / `tree_rss_kb`). Cheap wins are
fewer prefix bytes, not a new heap.

## Consequences

- First request after the shorter `subagent` desc / `rlm` note is a
  one-time cache miss, then a smaller stable prefix.
- Live A/B after this revision is required (cache-max 92ec3b2 was
  never re-measured with these prompt bytes). Suite: `--suite rlm`
  then `--suite swe`. Harnesses: `graff-dev-old,graff-dev`.

## Live A/B (2026-08-25, after this revision)

SuperGrok OAuth, grok-4.6, one rep. `[usage]` is `$0.0000 · N subscription
call(s), flat-rate` both ways. External harnesses (grok-build / kimi-cli /
dsh) did not run: no binaries, no Moonshot/DeepSeek keys, grok-build needs
Rust+DotSlash or an xAI CLI login this OAuth file does not unlock as `grok`.

`graff-evals/results/run-20260825-061442.jsonl` (`--suite rlm`) and
`run-20260825-061746.jsonl` (`--suite swe -j 12`).

### rlm suite (5 tasks)

| harness | pass | wall | in | cached | out | calls | RSS | $ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `--old` | 4/5 | 104.6s | 96683 | 60928 (63%) | 2441 | 19 | 91.1M | $0.0000 |
| default rlm | 5/5 | 35.5s | 79549 | 52992 (67%) | 1279 | 17 | 9.1M | $0.0000 |
| **delta** | **+1** | **−69.1s (−66%)** | **−17134 (−18%)** | +4pt hit | **−1162** | −2 | **−82M** | wash |

| task | `--old` s | default s | `--old` in/out/cached | default in/out/cached |
|---|---:|---:|---:|---:|
| multi-read | 20.98 | 6.31 | 13420 / 215 / 4992 | 13686 / 255 / 9344 |
| scatter-sum | 6.65 | 5.85 | 13327 / 169 / 9216 | 13583 / 171 / 9344 |
| fanout-merge | 6.42 | 6.02 | 13291 / 151 / 6528 | 13547 / 159 / 9344 |
| needle-files | 8.14 | 5.17 | 13478 / 212 / 9344 | 13720 / 202 / 9472 |
| bind-reuse | 62.4 ✗ | 12.12 ✓ | 43167 / 1694 / 30848 | 25013 / 492 / 15488 |

`--old` `bind-reuse` failed this rep: the model noticed `rlm` is off and
never wrote `found.txt` (prior A/B it still passed the long way). Default
rlm reused the bind (12s / 25k / 5 calls). `--old` scatter RSS of ~91M
looks like a leftover child (`timed_out` on 6s tasks); SWE below is the
fairer RSS compare (~9M both ways). Default `bind-reuse` RSS is 9.1M vs
`--old` 26.5M.

### swe suite (6 DeepSWE-shaped tasks, `-j 12`)

| harness | pass | wall (sum) | in | cached | out | calls | RSS | $ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `--old` | 4/6 | 520.6s | 740197 | 541184 (73%) | 39842 | 75 | 9.6M | $0.0000 |
| default rlm | 4/6 | 462.3s | 527559 | 368640 (70%) | 33274 | 56 | 9.3M | $0.0000 |
| **delta** | wash | **−58.3s (−11%)** | **−212638 (−29%)** | −3pt hit | **−6568** | **−19** | wash | wash |

Same 4/6 as #619 (label-sort and json-stream fail both ways). `map-conflict`
is the clear default-rlm win (108s / 148k → 38s / 41k). `--old` has a
slightly higher cache *rate* because it sends a fatter prefix; default rlm
sends fewer total input tokens.

**Verdict:** keep default RLM. After cache-max + this prompt/subagent cut,
rlm-suite is a pass-rate win and a wall/token/RSS win; swe is a token/call
win at the same 4/6. SuperGrok $ is a wash (flat-rate); the token cut is
the metered-key spend win.
