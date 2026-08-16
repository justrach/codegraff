# Kernels

A kernel graduates when (1) Lean builds, (2) the reference model exhausts
the reachable cells, (3) the Zig implementation matches the export.

## Process vs cube

A kernel is a **cube** (flag or table product; `native_decide` over the cells)
or a **process** (a finite `Event` / `step` state diagram). Process kernels
are not Turing machines: no tape, no halt state, no computability encoding.
The diagram is the transition function. The cube, if the kernel has one, is
the snapshot of that function.

`GoalLoop` and `PromptCache` are the process kernels. GoalLoop: standing
has no retire edge; harness-done needs a done write. PromptCache: sub never
spawns; spawn isolates the child key; join restores the root partition;
isolation does not mint a key. Score, Shape, Provider, and ToolCatalog stay cubes.


## Every harness part

Every part is **live**, **new**, or **never**. Never is a classification,
not a skip: TUI, prompts, and SSE bytes stay out of Lean on purpose.

### Live (already a complete triangle)

| Kernel | Cells | What it is *not* |
|---|---|---|
| `ToolCatalog` | 64 flag cubes | MCP names, descriptions, JSON wrappers |
| `Transport` | 96 turns; **1** WS cell | frames, TLS, idle-kill timing of the server |
| `Provider` | 18 baked rows | live `/models` overlay, Kimi protocol flip |
| `GoalLoop` | 360 gate cells + `Event`/`step` | model wording, whether the work is correct |
| `PromptCache` | 48 cells + `Event`/`step` | provider cache HIT, uuid5 cwd bytes, vision pin |
| `PathConfine` | 16 lexical paths + 80 lease cells | OS errno, Windows drives, live symlink walk |
| `Shape` | 1728 ladder cells | `admit`, learned override, ε-explore, `observe` |
| `Score` | 1210 filing cells (240 filed); 11 titles; 16 class samples | HMAC, providerClass price fallback |

### New (this loop)

| Kernel | Cells | What it is *not* |
|---|---|---|
| `BashPolicy` | finite command cube: `isSimple`, `escapesCwd`, `readOnlyAllowed`, `readOnlyExternal` | live argv quoting, Windows cmd.exe |

### Never (accounted for; eval / tier 2)

| Part | Why never |
|---|---|
| TUI (layout, colors, glyphs, hover) | the emulator owns the font and the cell grid |
| Prompts / system text | wording is not a discrete decision |
| SSE / stream bytes | wire framing, not a predicate |
| MCP protocol / tool descriptions | names and schemas, not a flag cube |
| HMAC score signing | crypto, not a discrete gate |
| Learned override / ε-explore | archive-backed, not the compiled prior |
| `observe` file tokenizer / session decline counts | encoder in front of the ladder |
| Live `/models` overlay | network, not the baked table |
| `noSymlinkEscape` on a real FS | OS; modelled lexically in PathConfine |
| Approvals session state (allow-list, yolo persistence) | mutable human session, not a pure function |
| Compaction / HTTP / process runner | I/O and timing |
| "eval GREEN before completion" | no such discrete Zig predicate exists |

The leftover discrete bash/policy family (`isSimple` / `escapesCwd` /
`readOnlyAllowed`, plus the `#64` twin `readOnlyExternal`) is the new
triangle. `isInterpreter`, `isDestructiveGit`, and `planReadMatch` live
in the same module and are covered as tables/cases on that triangle, not
as a ninth kernel.

## How a kernel evolves

1. Write the axes and the illegal-cell predicates in Lean first.
2. Prove the cheap general facts.
3. Port the same functions to `spec/ref/<kernel>.py`.
4. Export `spec/kernels/<kernel>.json`.
5. Diff the live Zig function against the export.
6. Stop. Do not add a vendor-specific theorem.
