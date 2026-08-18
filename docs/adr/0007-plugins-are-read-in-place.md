# 0007. Plugins and foreign MCP are read in place

Status: accepted 2026-08-18

## Context

Grok-build feels like it "just works" with Claude/Codex/Cursor because it
**reads their trees where they already live**. graff's first-run `adopt` copies
MCP and skills into `~/.codegraff/` once, then ignores anything installed
after that marker. A skill cannot see a plugin that was never copied. MCP
added to `~/.claude.json` after the first `graff` session never connected.

Copying also duplicates secrets and drifts from the other harness's live
config.

## Decision

- Discover plugin roots in place: `~/.cursor/plugins/`, `~/.claude/plugins/`,
  `~/.grok/plugins/`, `~/.codex/plugins/`, `~/.codegraff/plugins/`, and the
  project `.cursor/.claude/.grok/.codex/.harness/plugins/` trees (including
  Cursor/Claude `plugins/cache/…`). A directory is a plugin if it has
  `.cursor-plugin/plugin.json`, `.claude-plugin/plugin.json`,
  `.grok-plugin/plugin.json`, `plugin.json`, `.mcp.json`, `mcp.json`,
  `skills/`, or `agents/`. The listing name comes from the manifest when
  present (Cursor cache folders are content hashes). Skip `marketplaces/`.
  Cap 32. A directory is also a plugin if it has Claude's `commands/` or a
  root `SKILL.md`.
- Skills from those trees (and `~/.agents/skills`, `~/.grok/skills`,
  `~/.codex/skills`, `~/.cursor/skills-cursor`, `~/.cursor/skills`) join the
  existing on-demand `skill` catalog. Claude `commands/*.md` and a plugin-root
  `SKILL.md` (when there is no `skills/` tree) load the same way. Manifest
  `skills` / `commands` / `agents` paths and inline or path-valued
  `mcpServers` are honored; `${CLAUDE_PLUGIN_ROOT}` and
  `${CLAUDE_PROJECT_DIR}` expand in MCP strings. Bodies still load only when
  the model calls `skill`. Project `.harness/skills` still wins.
- Plugin `agents/` join the fleet after personal `~/.harness/agents` and
  before project `.harness/agents`.
- Plugin `.mcp.json` / `mcp.json` plus Claude/Cursor/Grok MCP files
  (`~/.claude.json`, `~/.cursor/mcp.json`, `.cursor/mcp.json`, …) fill
  **missing** server names only. graff's `~/.codegraff/mcp.json` and
  `.mcp.json` still win. Consent is unchanged (`/mcp trust` / `--yolo`).
- `GRAFF_NO_PLUGINS=1` disables the scan. `/plugins` and `graff plugins`
  list origin; `/plugins load <name>` shows one tree. Do not vendor
  grok-build. Do not auto-run plugin hooks. Do not add plugin `bin/` to PATH.

## Consequences

- A plugin installed after first-run adopt is visible next session.
- Project plugin MCP is not more trusted than project `.mcp.json`; it is less.
- Revisit if a user needs to disable one plugin without `GRAFF_NO_PLUGINS`.
