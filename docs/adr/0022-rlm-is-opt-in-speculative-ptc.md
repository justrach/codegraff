# 0022. RLM + spec-ptc is the default loop; `--old` restores structured-only

Status: accepted 2026-08-25; default flipped 2026-08-25

## Context

[spec-ptc](https://github.com/alexzhang13/spec-ptc) overlaps tool work with
generation for harnesses whose tools are functions inside one code REPL (RLM,
CodeAct). [Recursive Language Models](https://github.com/alexzhang13/rlm)
(Zhang, Kraska, Khattab) treat long context as a REPL variable and peel
questions off with `llm_query` / `rlm_query`. Graff's native loop is the
opposite shape: the model emits structured `read_file` / `bash` / `subagent`
calls, and `runTools` fans a *finished* batch across the pool. That is
parallelism after the arguments close, not speculation from partial source.

Dropping spec-ptc's Python shadow REPL into the default catalog would change
every prefix and the 64-cell tool-catalog kernel. The first cut stayed
opt-in so it was measurable against the native loop without that cost.
Scatter and persist then won by enough that the loop itself became the
default; `--old` is the escape hatch, not a second implementation.

## Decision

`rlm` is the default native tool. `--old` / `--no-rlm` / `GRAFF_OLD=1` /
`GRAFF_RLM=0` restore the structured-only catalog. `--rlm` / `GRAFF_RLM=1`
force it on. Last CLI flag wins; env does not clobber `--old` or `--rlm`.

This is **Alex Zhang's spec-ptc + RLM**, implemented in Zig — not Prime
Agent's IPython/ZeroMQ kernel, and not a Python fan-out process. Prime's
shape we kept: persistent binds across `rlm` calls and `subagent("task")`
via graff's existing `subagent` tool.

The spec joins the `native_fold` stack (the same meta-tool listing as
`workflow` / `subagent`): name only on `load_tool_schemas` until the model
loads or calls it, so default `-p` (lean) does not pay the full
description on every turn. The REPL's functions *are* graff tools
(`read_file`, `codedb`, `bash`, `webfetch`) plus `sleep_ms` / `llm_query`
/ `print` / `subagent`. The speculator is Zig (`src/spec_ptc.zig` +
`rlm.feedLive`): closed statements with literal args launch as the `code`
argument streams (including `-p`, where `Agent.out` is null), then
`runScript` claims the futures. `--schema` and the 64-cell tool-catalog
kernel do not grow a new always-on tool.

A live comparison is `scripts/compare-ptc.py`. The eval A/B is
`graff-evals/run.py --harness graff-dev-old,graff-dev`.

Measured 2026-08-25 on grok-4.6 (SuperGrok login, one rep, full
`graff-evals` suite). Both harnesses **12/12** in both catalog shapes.

First cut appended the full `rlm` spec to every request: **+7,411** input
tokens (164,481 vs 157,070) and 99.6s vs 105.7s wall. Folding `rlm` onto
the `load_tool_schemas` stack (this revision) drops that to **+304** input
tokens (157,212 vs 156,908) and a dead-heat wall (86.4s vs 86.6s). These
tasks are sequential single-file work with ~0ms local reads, so sPTC
overlap is not the story — the number that matters is *no correctness
regression* without a catalog tax. Per-task swings are one-rep variance.

| task | native s | `--rlm` s | native in/out | `--rlm` in/out |
|---|---:|---:|---:|---:|
| exact-reply | 2.59 | 2.49 | 4291 / 36 | 4294 / 42 |
| regex-count | 9.91 | 9.43 | 13836 / 466 | 13853 / 395 |
| csv-sum | 5.59 | 5.52 | 13227 / 172 | 13237 / 172 |
| recall-noise | 3.43 | 3.45 | 8909 / 65 | 8915 / 87 |
| json-transform | 7.08 | 7.27 | 13365 / 233 | 13352 / 252 |
| file-ops | 8.52 | 7.39 | 13303 / 321 | 13272 / 276 |
| fix-fib | 11.10 | 10.49 | 19073 / 531 | 19118 / 551 |
| write-tests | 7.53 | 8.35 | 17968 / 283 | 18073 / 316 |
| git-ops | 10.75 | 12.18 | 14187 / 541 | 14216 / 495 |
| refactor-rename | 7.59 | 7.13 | 18111 / 301 | 18109 / 281 |
| schema-output | 8.21 | 8.61 | 11773 / 372 | 11871 / 463 |
| dead-code | 4.34 | 4.04 | 8865 / 109 | 8902 / 117 |
| **total** | **86.6** | **86.4** | **156908 / 3430** | **157212 / 3447** |

## Consequences

- Mid-stream speculation is on the SSE path even when the one-shot frontend
  is quiet (`printDelta` still feeds `ArgLive` for `rlm` when it is on).
  `rlm` is *not* visible-prose for the WS stall signal (SSE does not grow
  `partial_text` for `code`).
- `llm_query` is a bounded tools-off sub-call on the session provider
  (`src/rlm_query.zig`). Nested spend is real; the host function exists so
  sPTC can overlap an expensive sub-LM with the rest of the script.
- SDK / `--schema` do not list `rlm` as a catalog tool (fold + `maybeAppend`
  only). Launch flags `--rlm` / `--old` are in the `--schema` flags list.
- Semicolons (outside strings) are statements, so a one-line script still
  speculates. Host positional fields include `bash` / `webfetch`. `print(a, b)`
  joins binds. A short system note is spliced only while the flag is on so
  the folded spec is discoverable without paying its schema.
- Scatter-gather tasks live in the `rlm` eval suite (`graff-evals/run.py
  --suite rlm`). Default `--suite all` runs core + rlm + swe. Measured
  2026-08-25 on grok-4.6 (one rep): both **4/4**, native **86.8s / 53564
  in**, `--rlm` **23.7s / 54496 in**. `needle-files` (62.8s → 5.6s)
  dominates the wall delta; `multi-read` was 1s slower on `--rlm`
  (one-rep noise). Extra input is the system note (~900 tokens across
  four tasks), not a catalog schema.
- DeepSWE-shaped multi-file bugfixes live in `--suite swe`, distilled
  from [deepswe.datacurve.ai/run](https://deepswe.datacurve.ai/run)
  (cookie-store, label-sort, config-parse, map-conflict, json-stream,
  validated). Held-out checks stay in `graff-evals/hidden/` so the
  agent cannot read them. The runner records peak RSS, child CPU, and
  first-output latency next to wall and tokens. Full Harbor/Pier/Docker
  DeepSWE is out of scope; this suite is the graff-shaped subset.
  Measured 2026-08-25 on grok-4.6 (one rep, `-j 12`): both **4/6**
  (label-sort and json-stream failed on both). Parallel clock ~140s;
  summed per-task wall native **624s / 822k in / 9.7M RSS** vs `--rlm`
  **652s / 816k in / 9.4M RSS**. `map-conflict` was the only clear
  `--rlm` win (84s → 52s). Same pass rate, no memory win, no wall win
  on this suite — `--old` stays as the structured-only escape. Default
  flipped anyway because persist (`bind-reuse`) is the spend win, #619
  scatter showed a wall win that is one-rep fragile, and core/swe did
  not regress.

## Default vs `--old` (this branch, 2026-08-25)

Live `graff-evals/run.py --suite rlm --harness graff-dev-old,graff-dev
--model grok-4.6` (one rep, SuperGrok OAuth, `run-20260825-043814.jsonl`).
`graff-dev` is default RLM; `graff-dev-old` is `--old`. The `[usage]`
footer printed `$0.0000 · N subscription call(s), flat-rate (not in $)`
both ways — token/call counts are the cost axis on a plan seat.

| harness | pass | wall | in | out | calls | $ |
|---|---:|---:|---:|---:|---:|---:|
| `--old` | 5/5 | 161.0s | 203276 | 4186 | 26 | $0.0000 |
| default rlm | 5/5 | 135.7s | 105414 | 1669 | 22 | $0.0000 |
| **delta** | wash | **−25.3s (−16%)** | **−97862 (−48%)** | **−2517 (−60%)** | −4 | wash |

| task | `--old` s | default s | `--old` in/out | default in/out |
|---|---:|---:|---:|---:|
| multi-read | 38.25 | 40.49 | 23212 / 337 | 23887 / 357 |
| scatter-sum | 10.24 | 9.93 | 18318 / 379 | 18800 / 389 |
| fanout-merge | 6.12 | 39.33 | 13303 / 157 | 23590 / 297 |
| needle-files | 6.82 | 6.70 | 13475 / 197 | 13836 / 211 |
| bind-reuse | 99.58 | 39.21 | 134968 / 3116 | 25301 / 415 |

**Saved:** persist `bind-reuse` — 99.6s / 135k in / 11 calls → 39.2s /
25.3k in / 5 calls (−61% wall, −81% input). The model did
`s = read_file(...)` then `print(s)`. `--old` spent a turn discovering
`rlm` is off, then wrote `found.txt` the long way. Confirms #619
(97.5s / 145k → 41.4s / 30.9k).

**Wash:** the four scatter tasks this rep. `--old` `needle-files` was
already 6.8s (no 62.8s hang), so #619's 86.8s → 23.7s did not
reproduce. Default `fanout-merge` wrote a correct `merged.cfg` then
hung until the runner killed it (`timed_out`, still pass) — one-rep
noise, not a catalog tax. Scatter-only totals: 61.4s / 68.3k in vs
96.5s / 80.1k in.

**$:** SuperGrok is flat-rate. Do not read `$0.0000` as "free on a
metered key" — the 98k input / 2.5k output token cut *is* the spend
win if the same seats were `XAI_API_KEY`.

Core 12/12 dead heat (~86s, +304 in) and SWE 4/6 (~624s vs 652s,
822k vs 816k in) were not re-run; cite #619. `subagent()` has no live
eval task; unit pins landed on this branch (`maybeAppend` keeps
`subagent`, `feedLive` launches two independent `subagent()` calls,
persist does not break `execSubagent`, `emitArgText` stays rlm-only).

Graff's `--rlm` is a Zig subset of [Prime Agent's RLM programming
model](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/rlm.md),
not an IPython/ZeroMQ kernel. Prime's invariants we keep in graff shape:
assignments persist across `rlm` tool calls in a session (context as
variables; `/new` and `/clear` drop them), and `subagent("task")` is
Prime-style recursion via graff's existing `subagent` tool (positional
`prompt`; v1 is synchronous so `print(h)` is the child's report;
`run_in_background=true` returns an id). We do not make `rlm` the only
catalog tool, and we do not add control flow. The speculator is still Zig.
