# 0022. `rlm` is opt-in speculative programmatic tool calling

Status: accepted 2026-08-25

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
every prefix and the 64-cell tool-catalog kernel. A first cut has to be
measurable against the native loop without that cost.

## Decision

`rlm` is an opt-in native tool (`--rlm` / `GRAFF_RLM=1`). Off, the catalog is
unchanged. On, the spec joins the `native_fold` stack (the same meta-tool
listing as `workflow` / `subagent`): name only on `load_tool_schemas` until
the model loads or calls it, so `--rlm -p` (lean) does not pay the full
description on every turn. The REPL's functions *are* graff tools
(`read_file`, `codedb`) plus `sleep_ms` / `llm_query` / `print`. The
speculator is Zig (`src/spec_ptc.zig` + `rlm.feedLive`): closed statements
with literal args launch as the `code` argument streams (including `-p`,
where `Agent.out` is null), then `runScript` claims the futures. Default
structured tools stay the main harness.

A live comparison is `scripts/compare-ptc.py`. The eval A/B is
`graff-evals/run.py --harness graff-dev,graff-dev-rlm`.

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
  is quiet (`printDelta` still feeds `ArgLive` for `rlm` when `--rlm` is set).
  `rlm` is *not* visible-prose for the WS stall signal (SSE does not grow
  `partial_text` for `code`).
- `llm_query` is a bounded tools-off sub-call on the session provider
  (`src/rlm_query.zig`). Nested spend is real; the host function exists so
  sPTC can overlap an expensive sub-LM with the rest of the script.
- SDK / `--schema` do not list `rlm` until it graduates off the flag.
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

Graff's `--rlm` is a Zig subset of [Prime Agent's RLM programming
model](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/rlm.md),
not an IPython/ZeroMQ kernel. Prime's invariants we keep in graff shape:
assignments persist across `rlm` tool calls in a session (context as
variables; `/new` and `/clear` drop them), and `subagent("task")` is
Prime-style recursion via graff's existing `subagent` tool (positional
`prompt`; v1 is synchronous so `print(h)` is the child's report;
`run_in_background=true` returns an id). We do not make `rlm` the only
catalog tool, and we do not add control flow. The speculator is still Zig.
