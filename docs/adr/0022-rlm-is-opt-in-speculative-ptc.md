# 0022. `rlm` is opt-in speculative programmatic tool calling

Status: accepted 2026-08-25

## Context

[spec-ptc](https://github.com/alexzhang13/spec-ptc) overlaps tool work with
generation for harnesses whose tools are functions inside one code REPL (RLM,
CodeAct). Graff's native loop is the opposite shape: the model emits structured
`read_file` / `bash` / `subagent` calls, and `runTools` fans a *finished* batch
across the pool. That is parallelism after the arguments close, not speculation
from partial source.

Dropping spec-ptc's Python shadow REPL into the default catalog would change
every prefix and the 64-cell tool-catalog kernel. A first cut has to be
measurable against the native loop without that cost.

## Decision

`rlm` is an opt-in native tool (`--rlm` / `GRAFF_RLM=1`). Off, the catalog is
unchanged. On, the model gets one REPL whose functions *are* graff tools
(`read_file`, `codedb`) plus `sleep_ms` / `print`. The speculator is Zig
(`src/spec_ptc.zig`): closed statements with literal args launch in parallel
before the script walks them. Default structured tools stay the main harness.

A live comparison is `scripts/compare-ptc.py`: same prompt, native vs `--rlm`.

## Consequences

- True mid-stream speculation (feed `code` while the `rlm` argument is still
  arriving) is the next increment; v1 speculates at exec start from the
  complete script, which already overlaps independent calls with each other.
- `llm_query` as a host function (a real RLM sub-call) is not in this cut.
- SDK / `--schema` do not list `rlm` until it graduates off the flag.
