# Kernel: tool catalog

Source of truth: `spec/lean/Graff/ToolCatalog.lean`.
Executable model: `spec/ref/tool_catalog.py`.
Exported cases: `spec/kernels/tool_catalog.json`.

The catalog a model is allowed to see is a **composition of three gates**,
always in this order:

1. **Choose** the root universe (`clock_sleep`, `learn_candidate` are the
   two compile-time optional rows).
2. **Add** every `#352` optional whose flag is on (`imagegen` today).
3. **Subtract** `#330` `--no-local-tools` (host-touching built-ins).
4. **Keep** `--lean` (`attempt_completion` + `load_tool_schemas`;
   `rlm` is a session overlay, not this cube). Description compaction does
   not change names.

A subagent starts from `base_specs` only (no meta, no `subagent`), then
applies (2) and (3). `--lean` is a root-prefix concern; children do not
run the keep-list.

## Universes

| Set | Names |
|---|---|
| base | `bash` `bash_output` `bash_kill` `read_file` `edit_file` `write_file` `webfetch` `skill` `codedb` `read_tool_result` |
| meta (root) | `todo_write` `todo_read` `eval` `note_constraint` `ask_user` `attempt_completion` `load_tool_schemas` `mcp_search_tools` `mcp_select_tool` `clock_sleep` |
| root extras | `subagent` `workflow` `agent_output` `learn_candidate` `peer_message` `workspace` |
| optional | `imagegen` |
| local (`#330`) | `bash` `bash_output` `bash_kill` `read_file` `edit_file` `write_file` `codedb` `read_tool_result` `imagegen` |
| lean keep | `attempt_completion` `load_tool_schemas` |

`webfetch`, every meta tool except the lean keepers, and every `mcp__*`
name are **not** local. MCP is outside this kernel.

## Dispatch (layer 2)

Advertising is not enough. A hallucinated name must be refused **before**
anything runs when:

- `#330` is on **and** the name is local, or
- the name is optional **and** its flag is off.

`--lean` has **no** layer 2. A lean-dropped name is simply unknown.

## Properties

- **Unique.** A catalog never lists a name twice.
- **Order.** Filters preserve relative order; optionals append in gate order.
- **Optional iff.** `imagegen` is advertised iff it is available, not
  `#330`-gated, and (on the root) not dropped by lean.
- **Subtractive wins.** `#330` removes `imagegen` even when the skill is
  installed.
- **Lean ⊆ full.** Same other flags, lean catalog is a subsequence of the
  full catalog.
- **`#330` ⊆ full.** Same other flags, the gated catalog is a subsequence
  of the ungated one.
- **Sub never spawns.** A subagent catalog never contains `subagent`.
- **Webfetch survives `#330`.**
- **Layer 2 matches the gates.** `blocked(name)` iff `#330.blocks` or
  `tool_gates.blocks`. Lean-dropped names are not blocked.
