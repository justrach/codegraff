# 0012. Overflow handles, named prefix caps, and extra roots

Status: accepted 2026-08-19

## Context

fx (vercel-labs) keeps a fat tool result out of history with
`read_tool_result`, caps named prefix slices (`skill_catalog_bytes`, MCP
schema, AGENTS.md), searches MCP then selects, and adds extra workspace
roots with `--add-dir` (max 16) that do not contribute skills or sessions.

graff already spilled oversized results (#440) and folded MCP behind
`load_tool_schemas`. The missing pieces were a first-class pager for the
spill, discrete byte knobs instead of ad-hoc `desc_cap`, search-without-
load, and extra roots that are not a `workspace` cwd switch.

## Decision

- A result over the handle threshold is stored as `.graff/tool-results/tr_N.txt`.
  The model pages it with `read_tool_result` (`offset`/`limit` or `query`).
  `query` returns the whole matching line. The first payload also includes a
  bounded excerpt of error-shaped lines. The full blob does not re-enter history.
- `--context-limit name=N` (and `GRAFF_CONTEXT_LIMIT`) caps
  `skill_catalog_bytes`, `mcp_schema_bytes`, and `agents_md_bytes`. `apply`
  never grows. Defaults 4 KiB / 8 KiB / 8 KiB.
- `mcp_search_tools` lists deferred tools and does not enable them.
  `mcp_select_tool` loads chosen names. `load_tool_schemas` stays for bulk.
- `--add-dir` (max 16) is a PathConfine allow-list for file tools.
  Extra roots never contribute skills or sessions. `workspace` still
  switches cwd.

## Consequences

- One fat bash/codedb hit costs one preview plus later slices. The first
  payload includes a bounded excerpt of error-shaped lines (fail / error /
  panic / …) so "what broke?" does not need a pager turn; `query` returns
  the whole matching line, not an 80-byte pad.
- Named caps are prompt-cache-stable: shrinking a listing does not rewrite
  tool names or pin policy.
- Extra-root absolute paths become `confinedPath` when they stay under a
  registered root with no `..`. The Lean PathConfine fixtures stay the
  empty-roots jail; extra roots are the extension.
