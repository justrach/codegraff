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

Cloned 2026-08-25 (shallow). **grok-build uses the same SuperGrok OAuth
we already have.** `graff login xai` writes
`~/.xai/credentials/graff-oauth.json` with grok-build's public client
(`b1a00492-…`, issuer `https://auth.x.ai`, same 10-scope set). Mapped
into `~/.grok/auth.json` as `auth_mode=oidc` under
`https://auth.x.ai::<client>` — `grok -p` answers in ~3s. Install is
`npm i -g --prefix ~/.local @xai-official/grok` (1.0.5 here). kimi-cli
and dsh still need Moonshot / DeepSeek keys; those two stay architecture
compare only.

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
call(s), flat-rate` for graff. grok-build ran on the same login (mapped
`graff-oauth.json` → `~/.grok/auth.json`). kimi-cli / dsh still did not
run (no Moonshot / DeepSeek keys).

`graff-evals/results/run-20260825-061442.jsonl` (`--suite rlm`) and
`run-20260825-061746.jsonl` (`--suite swe -j 12`, graff-only). The
grok-inclusive SWE retry is `run-20260825-061731.jsonl`.

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

**Verdict (graff-only swe, prior rep):** keep default RLM. After cache-max
+ this prompt/subagent cut, rlm-suite is a pass-rate win and a
wall/token/RSS win; swe is a token/call win at the same 4/6. SuperGrok $
is a wash (flat-rate); the token cut is the metered-key spend win.

### swe retry vs grok-build (same OAuth, `run-20260825-061731.jsonl`)

`--suite swe --harness graff-dev-old,graff-dev,grok -j 12`. grok 1.0.5
(`@xai-official/grok`), `--always-approve`, `streaming-messages-json`.

| harness | pass | wall (sum) | first | RSS | in | out | calls | $ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `--old` | 4/6 | 576.3s | 10.6s | 8.7M | 1015137 | 42267 | 88 | $0.0000 |
| default rlm | 4/6 | 742.7s | 4.9s | 9.1M | 1259428 | 48430 | 96 | $0.0000 |
| grok-build | **5/6** | **500.2s** | **3.4s** | 164.6M | **184880** | 32040 | **39** | — |

| task | `--old` | default | grok |
|---|---:|---:|---:|
| config-parse | ✓ 84s / 150k | ✓ 76s / 153k | ✓ 69s / 11k |
| cookie-store | ✓ 103s / 236k | ✓ 230s / 322k | ✓ 123s / 53k |
| json-stream | ✗ 90s / 190k | ✗ 100s / 149k | **✓ 202s / 81k** |
| label-sort | ✗ 81s / 79k | ✗ 170s / 354k | ✗ 49s / 20k |
| map-conflict | ✓ 126s / 205k | ✓ 56s / 111k | ✓ 25s / 13k |
| validated | ✓ 94s / 154k | ✓ 112s / 170k | ✓ 33s / 8k |

All three fail `label-sort` (held-out check). grok is the only pass on
`json-stream`. Default rlm vs `--old` is a wash on pass (4/6) and a
loss on this rep's summed wall — `cookie-store` 103s→230s and
`label-sort` 81s→170s dominate; `map-conflict` still wins (126s→56s).
One-rep noise vs the earlier swe file (default was −11% wall there).

**RSS:** graff stays ~9M. grok-build peaks **165M** (~18×). That is the
Zig process model, not a prompt trick. grok's token win is real (185k
in vs 1.0–1.3M) — shorter catalog + fewer calls (39 vs 88–96). Do not
copy their V8/Rust heap to chase the pass; steal prompt brevity if
anything.

## Why grok-build looked better (and what we took)

Two separate facts. Neither is "their loop is smarter."

**1. `json-stream` is a spec-contract miss, not an architecture miss.**
The hidden check is `iter_json("application/json-seq", "   ") == []`.
`SPEC.md` says "Empty payload yields nothing." Public tests never cover
whitespace-only json-seq. Grok's sandbox `lstrip`s JSON whitespace and
returns; graff treated `"   "` as a record and `json.loads` failed. Do
not copy their heap for that extra pass.

**2. The lean catalog lied under `-p --yolo`.** Evals run `graff -p --yolo
--lean`. `unattended_note` (the real "AUTO-DENIED" sentence) is *not*
appended when yolo is on (`main.zig` passes `unattended and
!effectiveYolo()`). But `lean_subagent_desc` still said the root's
bash/edit tools are approval-denied and the model should delegate. That
is why graff spent 88–96 calls / 1.0–1.3M input tokens against grok's
39 / 185k: the model spawned children for work the root could do. Grok's
root prompt says do clear local work this turn; only launch Task when
the user asked or the work is independent (same Codex sidecar rule we
already put on the *full* `subagent` desc, not on lean).

**Take (this revision):**

- Rewrite `lean_subagent_desc` to sidecar-only. Keep critical path
  local. Drop the approval-denied claim — that fact lives on
  `unattended_note` only.
- Two sentences on `work_note`: a named `SPEC.md` is the contract; a
  green public test is not the whole spec; empty includes
  whitespace-only unless the spec says otherwise. Does not leak hidden
  checks.

**Still reject:** V8 / grok heap, extra spawn tools, parent-history
fork, share root `prompt_cache_key` with children, IPython.

Live A/B after the lean-desc rewrite (`run-20260825-063211.jsonl`,
same OAuth / grok-4.6 / `-j 12`):

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| `--old` | 4/6 | 551.8s | 16.2s | 9.5M | 819087 | 40858 | 80 |
| default rlm | 4/6 | 572.2s | 9.6s | 9.4M | **678343** | 42606 | **67** |
| grok-build | **5/6** | **376.6s** | **1.8s** | 158.7M | **157065** | 24438 | **31** |

Versus the pre-cut grok-inclusive file (`061731`): default rlm
**−46% input tokens** (1.26M → 678k) and **−30% calls** (96 → 67),
RSS still ~9M. `cookie-store` 19→12 calls / 322k→152k;
`label-sort` 22→11 / 354k→125k. Pass rate stayed 4/6 —
`json-stream` still raised on whitespace-only json-seq (`"   "` has
no RS; grok skips content before the first RS and yields nothing).
The follow-up `work_note` sentence is that clause: a required
delimiter applies to records that exist; a payload with no records
is empty, not malformed.

Confirm after that sentence (`run-20260825-064129.jsonl`, graff-dev
only):

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| default rlm | **5/6** | **441.0s** | 3.6s | 9.2M | **447074** | 28909 | **50** |

Tied with grok-build on pass (both miss `label-sort`). Versus `061731`
default rlm: **+1 pass**, **−41% wall** (743s → 441s), **−65% input
tokens** (1.26M → 447k), **−48% calls** (96 → 50). Still ~3× grok's
tokens/calls (fatter prefix + more turns) and **~17× less RSS**. Do
not copy grok's 159M heap.

## Why still ~3× tokens (and the next cut)

447k vs grok's 157–185k is **not** their heap. Per-call ~9k vs ~5k,
and 50 calls vs 31. Two leftover taxes on `-p --yolo --lean`:

1. **`rlm` was folded out of the catalog.** Stable-catalog + native
   fold hid the default loop behind `load_tool_schemas`. The model
   did N structured bash/read/edit calls instead of one script.
   Lean now unfolds `rlm` onto the catalog (ADR 0022: it is the
   one-shot loop, not a late power tool).
2. **Interactive essays on every one-shot turn.** Fan-out /
   `.graff/traces` / `gh issue create` / heads-up / the outside-cwd
   local-tools essay / the repo map / the folded-native listing.
   None of that helps a 5-file SWE sandbox. Dropped or swapped for
   a short `lean_local_tools_note`.

Live A/B after this diet: `--suite swe --harness graff-dev`. Goal:
same 5/6, fewer calls and input tokens, RSS stays ~9M.
