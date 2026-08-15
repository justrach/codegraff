# Kernels

A kernel graduates when (1) Lean builds, (2) the reference model exhausts
the reachable cells, (3) the Zig implementation matches the export.

| Kernel | Status | Reachable cells | What it is *not* |
|---|---|---|---|
| `ToolCatalog` | live | 64 flag cubes | MCP names, descriptions, JSON wrappers |
| `Transport` | live | 96 turns (3 kinds × 5 bools); **1** WS cell | frames, TLS, idle-kill timing of the server |
| `Provider` | live | 18 baked rows | live `/models` overlay, Kimi protocol flip |
| `GoalLoop` | live | 360 gate cells; empty ≠ done; standing does not retire | model wording, whether the work is correct |
| `PathConfine` | live | 16 lexical paths + 80 lease cells; yolo does not free a sub | OS errno, Windows drives |
| `Shape` | live | 1152 ladder cells; explicit never below R2; audit beats bugfix | model wording, learned override, ε-explore |
| TUI, prompts, SSE bytes | never | — | eval / tier 2 |

The discrete kernels we set out to write are all live. Next additions would
be *new* decision procedures (e.g. `isSimple` shell classification, or
"eval GREEN required before completion"), not more vendors.

## How a kernel evolves

1. Write the axes and the illegal-cell predicates in Lean first.
2. Prove the cheap general facts (`sub` never WS, only `responses` is WS,
   unique provider ids, `#330` wins).
3. Port the same functions to `spec/ref/<kernel>.py`.
4. Export `spec/kernels/<kernel>.json`.
5. Diff the live Zig function against the export.
6. Stop. Do not add a vendor-specific theorem.

When `provider_specs` gains a row, `Provider.lean` and the fixture grow by
one line and the Zig test fails until they do. That is the ratchet.
