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

Verdict (rep 1): MCP-inside-rlm + shape cache can cut tokens. Do not
copy Blacksmith's V8 sandbox. SuperGrok $ is a wash; the 60k input cut
on D is the metered-key spend win **when the model stays in `each()`**.

## Follow-up A/B (2026-08-25, same day)

Second live rep of A/D plus four new prompts. SuperGrok grok-4.6,
ReleaseSafe, one rep each. `python3 scripts/eval-mcp-shapes.py --only A,D,F,G,H,I`

| var | prompt | pass | wall | RSS | in | cached | out | calls | what it did |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| A-r2 | `--old` + each() hint (ignored) | ✓ | 36.4s | 10.4M | 145497 | 96896 | 2075 | 9 | structured 1+8 again; wall stable |
| D-r2 | rlm+MCP, warm, each() hint | ✓ | 60.5s | 10.8M | 158769 | 122752 | 3101 | 11 | rlm then `report_issues = []`; **D token win did not hold** |
| F | each() hint + never print() fat arrays | ✓ | 220s | 10.8M | 462379 | 426880 | 9944 | 29 | `def`/`for`/`len`/`import`; grepped graff src |
| G | F + warm shapes | ✓ | 156s | 10.9M | 279981 | 166528 | 7947 | 21 | same dialect hole, slightly less lost |
| H | **no each() recipe**, cold | ✓ | **28.0s** | 10.6M | 112073 | 85248 | 1607 | **7** | never used rlm; parallel structured MCP |
| I | no each() recipe, warm shapes | ✓ | 31.1s | 10.5M | **107284** | 81536 | 1865 | **7** | same as H; shapes on the load result unused |

**The `each()` hint is a footgun on grok-4.6.** It pushes the model into
a dialect that cannot map/filter without `print()`ing the fat bind
(C/D) or inventing Python (F/G). Telling it not to print made it
*worse* — mapping without print needs `for`/`len` we do not have.

**No-hint (H/I) beat `--old` on wall and tokens** by doing the classic
loop well: one `load_tool_schemas`, then `list_issues` + 8
`list_comments` in one batch. That is not code mode. Muscle memory did
not change the path (I still never called `rlm`).

D-r1 107k / 41s vs D-r2 159k / 61s: one-rep token wins are not a ship
signal. H/I 7-call structured is the stable cheap path today.

## Consequences

- `--no-lean` remains the MCP one-shot. Lean still hides
  `load_tool_schemas`.
- Keep MCP-inside-rlm + shape splice (the host path is real). Do not
  advertise `each()` on this task until a `len`/project helper exists
  and beats H in a new A/B.
- A later `len`/`for` would cut C/D/F/G retries; do not grow a general
  language without that measurement.
- Prompting "prefer one rlm script" is not free. Default no-hint.

## Pareto front (wall / tok_in / calls)

Minimize all three among passing SuperGrok grok-4.6 runs. `len(x)` /
`project(x, field)` landed in `src/rlm_reduce.zig` so a script can print
a slim summary. Rerun: `python3 scripts/eval-mcp-pareto.py`

A point is on the front if nothing else is ≤ on every axis and < on one.

| id | wall | in | calls | why it stays |
|---|---:|---:|---:|---|
| **H** | **28.0s** | 112k | **7** | fastest / fewest calls (no-hint structured) |
| **I** | 31.1s | 107k | 7 | same path, slightly fewer tokens |
| **D-r1** | 41.1s | 107k | 10 | rlm+each, one lucky rep |
| **J-live** | 47.3s | **84k** | 9 | `each` + `len`/`project`; first script printed ids only |

Everything else is dominated (including `--old`, sidecar, split,
quiet-print, K-live, and H-live's 70s variance rep).

J used rlm for real (`issues = list_issues(); comments = each(...);
print(len, project)`). It is the **token vertex**. H is the **wall
vertex**. There is still no point that wins both. Warm shapes (K) did
not help J. Do not ship rlm-as-default for this MCP task; keep
len/project so the token vertex is reachable.

## Learnt slim (the muscle, not another hint)

Shapes on the load result did not change grok-4.6's path (I still never
called `rlm`). The learnt part is therefore applied in Zig: after
`remember()` of the fat payload, `takeSlim` / `print()` drop
`description`/`body` and fold comment arrays to `{n, latest_author}`.
When two MCP shapes are stored, `annotate` adds a one-line `# muscle:`
playbook on the load **result** (never the catalog prefix). No new
`GRAFF_` knob. Live L–Q sweep: `eval-mcp-shapes.py --only L,M,N,O,P,Q`.

## Out of the box (default `-p`)

Lean used to **skip MCP connect** and **hide** `load_tool_schemas` even
when a workspace `.mcp.json` was present. That forced `--no-lean` for
every MCP one-shot (ADR 0024 leftover). Default `-p` implies lean +
yolo: now it **connects** and **folds** (names + one-liners, full
schemas a load away). Empty `-p` (no deferred MCP) still hides the meta
tool. Consent is unchanged. `--no-lean` is the eager-schema opt-out, not
the MCP on-switch.

Prove with variant **R**: `graff-dev` (no `--no-lean`) + `linear-nohint`.
