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
`graff-evals` suite). Both harnesses **12/12**. `--rlm` added ~7k input
tokens (the extra tool schema) and was 6s faster on wall (99.6s vs 105.7s).
These tasks are sequential single-file work with ~0ms local reads, so
sPTC overlap is not the story — the number that matters is *no correctness
regression* while the catalog grows by one opt-in tool. The biggest wall
delta (`git-ops` 17.4s → 11.8s) is one-rep variance, not a claimed speedup.

| task | native s | `--rlm` s |
|---|---:|---:|
| exact-reply | 3.84 | 3.21 |
| regex-count | 10.81 | 8.89 |
| csv-sum | 6.92 | 6.25 |
| recall-noise | 4.43 | 4.15 |
| json-transform | 7.79 | 7.01 |
| file-ops | 8.62 | 8.99 |
| fix-fib | 11.46 | 11.62 |
| write-tests | 8.98 | 10.68 |
| git-ops | 17.42 | 11.83 |
| refactor-rename | 10.34 | 10.07 |
| schema-output | 10.14 | 11.32 |
| dead-code | 4.90 | 5.60 |
| **total** | **105.7** | **99.6** |

## Consequences

- Mid-stream speculation is on the SSE path even when the one-shot frontend
  is quiet (`printDelta` still feeds `ArgLive` for `rlm` when `--rlm` is set).
  `rlm` is *not* visible-prose for the WS stall signal (SSE does not grow
  `partial_text` for `code`).
- `llm_query` is a bounded tools-off sub-call on the session provider
  (`src/rlm_query.zig`). Nested spend is real; the host function exists so
  sPTC can overlap an expensive sub-LM with the rest of the script.
- SDK / `--schema` do not list `rlm` until it graduates off the flag.
