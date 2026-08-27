# 0039. Agent-authored local tools are project scripts, not skills

Status: accepted 2026-08-27

## Context

#555 asked for exo's `install_agent_tool` loop: the agent writes a tool at
runtime, the harness validates it, and later sessions see it as a first-class
tool. Graff already has skills (instruction playbooks) and MCP (out-of-process
servers). A third thing that is "just a skill with a shebang" would blur both.

`schema.zig` is at the 600-line cap and feeds the 64-cell
`spec/kernels/tool_catalog.json` cube. Putting every installed name into
`effectiveRootSpecs` would force an SDK regen on every project script.

## Decision

- A local tool lives at `.graff/tools/<name>/` with `manifest.json` plus a
  script. Runners are `python3`, `bun`, or `sh`.
- `install_agent_tool` validates the manifest, dry-runs `argv --dry-run`
  (exit 0 required), then registers `local__<name>`. Live calls pass the
  JSON args as argv[2] — `process_runner.runCapped` has no stdin.
- Skills stay instructions. MCP stays consent-gated servers. This is the
  executable, project-local half.
- Catalog extras are concatenated in `agent_catalog.ensureRootTools`, not
  added to `schema.effectiveRootSpecs`. `--no-local-tools` / `--lean` hide
  them. Subagents do not see them. Plan mode refuses install and live calls.

## Consequences

- A script that ignores `--dry-run` fails install. A script that reads stdin
  for args will see nothing.
- Do not grow `schema.meta_names` or the SDK cube for these names.
- Revisit if a project needs MCP-shaped stdin JSON or a fourth runner.
