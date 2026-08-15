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
| `transport` | live | 96 turns, **1** WebSocket cell. `Kind × seat × flags`. |
| `provider` | live | 18 baked rows over 3 wire kinds. |
| `goal_loop` | live | 360 gate cells. Empty ≠ done. Standing does not retire. |
| `path_confine` | live | Lexical cwd jail, symlink prefixes, 80 lease verdicts. |
| `shape` | live | 1152 ladder cells. Explicit never below R2. Audit beats bugfix. |
| TUI, prompts, SSE bytes | never | Eval, don't prove. |

## Run

```sh
python3 spec/conformance.py            # properties + fixture self-check
python3 spec/conformance.py --export   # regenerate kernels/tool_catalog.json
python3 spec/conformance.py --break imagegen-always-on   # demo a counterexample
python3 spec/conformance.py --lean     # lake build, if installed
zig build test --summary none -Dtest-filter="spec/tool_catalog"
```

The Zig test is the impl half of the harness: it sets the same flags the
spec enumerated, asks `effectiveRootSpecs` / `subToolsJson` for names, and
fails with the first differing cell as a counterexample.
