# 0029. MCP-inside-rlm host calls + persist return shapes (not V8)

Status: accepted 2026-08-25

## Context

[Blacksmith code mode](https://www.blacksmith.sh/blog/code-smith-code-mode)
(2026-08-24) hid the MCP catalog, ran one sandbox script, and persisted
return **shapes** (field names + broad types, never values) so the next
search did not guess. Cold code mode lost on wall because the model
lacked shapes and retried.

Graff already has the coding-loop half as default `rlm` (ADR 0022). ADR
0023 rejected V8 Code Mode. An rlm-only catalog already failed (122
calls, ADR 0024). This record is the Linear-shaped measurement of
**MCP-inside-rlm** + muscle memory, on a fixture stdio server
(`scripts/linear_fixture_mcp.py`: 8 fat issues, fat comments per id).
No live Linear.

## Decision

- After `load_tool_schemas` unfolds a tool, an `rlm` script may call that
  MCP name via `exec_mod` (`src/rlm_mcp.zig`). Unloaded names are
  refused. Deferral can only subtract. `GRAFF_RLM_MCP=0` restores
  today's structured-only gap. Lean/consent unchanged (`--no-lean` is
  still required to see MCP).
- Infer a small return schema after an MCP result; persist
  `.graff/mcp-shapes.json`; splice onto the next `load_tool_schemas`
  **result**. Never the always-on prefix (ADR 0011).
- `each(arr, tool, field)` maps a JSON array. Not a general language.
- Do not hide bash/edit/read_file. Do not add IPython/V8/QuickJS. Do
  not make `rlm` the only catalog tool.

## Live A/B (2026-08-25)

SuperGrok OAuth, grok-4.6, one rep, ReleaseSafe. `[usage]` is `$0.0000 ·
N subscription call(s), flat-rate`. Same prompt for A–D (8 issues +
comments + counts + latest authors). `tok_in` is ordinary+cache_read+
cache_write as graff reports it.

Rerun: `zig build -Doptimize=ReleaseSafe && python3 scripts/eval-mcp-shapes.py`

| var | harness | pass | wall | RSS | in | cached | out | calls | rlm retries |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| A `--old` structured MCP | graff-dev-old-nolean | ✓ | 36.7s | 10.6M | 167692 | 128000 | 2033 | 10 | none |
| B rlm, MCP structured-only | graff-dev-rlm-struct | ✓ | 43.3s | 10.8M | 179822 | 109312 | 2358 | 11 | 2 (host off, then `import`) |
| C rlm+MCP host, cold | graff-dev-nolean | ✓ | 56.7s | 10.6M | 147948 | 130048 | 3313 | 13 | 3 (`import` / `for` / `len`) |
| D rlm+MCP host, warm shapes | graff-dev-nolean + pre-seeded `.graff/mcp-shapes.json` | ✓ | 41.1s | 10.7M | **107213** | 83840 | 2253 | 10 | 1 (`len`) |
| E1 sidecar summarize | graff-dev-nolean / linear-sidecar | ✓ | 37.5s | 10.7M | 168164 | 120704 | 1998 | 11 | none (structured MCP on root) |
| E2 two sibling children | graff-dev-nolean / linear-split | ✓ | 75.5s | 12.3M | 149156 | 77824 | 5490 | 18 | children have no MCP; more expensive |

**B is the old gap, not papered over.** The model wrote
`each(issues, mcp__linear__list_comments, "id")` and was refused
(`GRAFF_RLM_MCP=0`), then fell back to 1+8 structured MCP.

**C each() worked** on the first script (host calls + map). Cold lost
on **wall** (+20s vs A) because `print(issues)` / `print(comments)`
dumped the fat payloads and the model retried Python `for`/`len`.
Token-in still beat A (−12%).

**D muscle memory was a real token win vs `--old`:** −36% input
(167k→107k), same 10 calls, −4s vs cold C. Wall still +4s vs A this
rep — the model still printed a fat bind. Shapes appeared on the
`load_tool_schemas` result (`return_shapes`), not on the catalog
prefix. No wrong MCP field names this rep; retries were missing
language (`len`/`for`), not `issue_id` vs `id`.

**E1** kept MCP on the root (ADR 0023) and matched A's wall; no token
win. **E2** passed but is the expensive split (18 calls / 75s).

Verdict: ship MCP-inside-rlm + shape cache. Do not copy Blacksmith's
V8 sandbox. SuperGrok $ is a wash; the 60k input cut on D is the
metered-key spend win.

## Consequences

- `--no-lean` remains the MCP one-shot. Lean still hides
  `load_tool_schemas`.
- `each()` is the only new control-flow helper. A later `len`/`for`
  would cut C/D retries; do not grow a general language without another
  measured A/B.
