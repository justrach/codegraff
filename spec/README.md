# Conformance layer

The implementation is not the spec. Hand-written examples are not the spec
either. A flag combination nobody wrote a test for can still be wrong — that
is how `view_image.available` defaulting on quietly added a 22nd catalog
entry.

This directory is the missing piece from the Lean diagram: a **formal source
of truth**, an **executable reference model**, **properties**, and a
**conformance harness** that returns pass or a counterexample.

```
                    spec/kernels/<name>
                    formal source of truth
                           |
           +---------------+---------------+
           |               |               |
     Markdown spec   Reference model   Properties
     kernels/*.md    ref/*.py          lean theorems
           |               |               |
           v               +-------+-------+
     AI-built Zig                  |
     src/*.zig                     v
                           Conformance harness
                           spec/conformance.py
                           + zig test vs fixtures
                                   |
                           pass / counterexample
```

Lean lives in `lean-proofs/` (see `lean-proofs/KERNELS.md`). It is **not**
on the pre-push path: `lake` is not required, and the hook stays a
20-second offline Zig run. The exported JSON in `kernels/*.json` is what
CI and `zig build test` actually consume. When `lake` is installed,
`python3 spec/conformance.py --lean` typechecks the same definitions.

## What belongs here

A kernel is worth formalizing when the state space is discrete, the
properties are load-bearing, and a missed combination is a real bug.

| Kernel | Status | Why |
|---|---|---|
| `tool_catalog` | live | 64 catalog cubes. `#330` / `#352` / `--lean`. |
| `transport` | live | Process kernel. 96 turns, **1** WebSocket cell. Sub never WS. |
| `provider` | live | 18 baked rows over 3 wire kinds. |
| `goal_loop` | live | Process kernel (`Event`/`step`, not a TM). 360 snapshot cells. Standing does not retire. |
| `prompt_cache` | live | Process kernel. 48 cells. Sub never spawns. Child key isolated. Join restores root. |
| `prompt_prefix` | live | Process kernel. 6 cells. Names-only catalog, pin once. Skill events do not rewrite the prefix. |
| `terminal_modes` | live | Process kernel. 14 sequences. Enable+restore returns to Idle. Pop floors. Alt last. |
| `path_confine` | live | Process kernel. Component walk; Escaped/Absolute absorb. 80 leases. |
| `shape` | live | 1728 cells. Hand ladder + explicit arm. Budget from remaining/cap/floor. |
| `score` | live | Process kernel. 1210 cells, 240 filed. Attempt never files; capture after join does. |
| `bash_policy` | live | 32 command cells. Simple + in-cwd + seed. External is never auto-allowed. |
| TUI, prompts, SSE bytes | never | Eval, don't prove. Every other harness part is listed in `lean-proofs/KERNELS.md`. |

## Run

```sh
python3 spec/conformance.py            # properties + fixture self-check
python3 spec/conformance.py --export   # regenerate kernels/*.json and GoalLoop mermaid
python3 spec/conformance.py --diagram goal_loop   # live Event/step projection
python3 spec/conformance.py --diagram prompt_cache
python3 spec/conformance.py --diagram prompt_prefix
python3 spec/conformance.py --showcase            # prefix cube + maximizing walk + key machine
python3 spec/conformance.py --diagram terminal_modes
python3 spec/conformance.py --diagram path_confine
python3 spec/conformance.py --diagram transport
python3 spec/conformance.py --diagram score
python3 spec/conformance.py --break imagegen-always-on   # demo a counterexample
python3 spec/conformance.py --lean     # lake build, if installed
zig build test --summary none -Dtest-filter="spec/tool_catalog"
```

Process kernels (`GoalLoop`, `PromptCache`, `PromptPrefix`, `TerminalModes`,
`PathConfine`, `Transport`, `Score`) are finite `Event` / `step` diagrams,
not Turing machines. Cube kernels (Shape, Provider, ToolCatalog) stay cubes.
BashPolicy stays a command cube this turn. The shape of a subagent fleet
is not a Shape cell — PromptCache / PathConfine / Transport force every
child through a machine; Score files that unbounded fleet as one stage
row after the join. `--diagram` prints a live `step` projection;
`--showcase` prints the one HIT cell and the session walk that stays on it;
`--export` writes those fences into `kernels/*.md`.

The Zig test is the impl half of the harness: it sets the same flags the
spec enumerated, asks `effectiveRootSpecs` / `subToolsJson` for names, and
fails with the first differing cell as a counterexample.
