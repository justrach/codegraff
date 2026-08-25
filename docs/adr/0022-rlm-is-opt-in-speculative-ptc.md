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
unchanged. On, the model gets one REPL whose functions *are* graff tools
(`read_file`, `codedb`) plus `sleep_ms` / `llm_query` / `print`. The
speculator is Zig (`src/spec_ptc.zig` + `rlm.feedLive`): closed statements
with literal args launch as the `code` argument streams (including `-p`,
where `Agent.out` is null), then `runScript` claims the futures. Default
structured tools stay the main harness.

A live comparison is `scripts/compare-ptc.py`. The eval A/B is
`graff-evals/run.py --harness graff-dev,graff-dev-rlm`.

## Consequences

- Mid-stream speculation is on the SSE path even when the one-shot frontend
  is quiet (`printDelta` still feeds `ArgLive` for `rlm` when `--rlm` is set).
  `rlm` is *not* visible-prose for the WS stall signal (SSE does not grow
  `partial_text` for `code`).
- `llm_query` is a bounded tools-off sub-call on the session provider
  (`src/rlm_query.zig`). Nested spend is real; the host function exists so
  sPTC can overlap an expensive sub-LM with the rest of the script.
- SDK / `--schema` do not list `rlm` until it graduates off the flag.
