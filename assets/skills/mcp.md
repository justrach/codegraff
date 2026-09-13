---
name: mcp
description: Add, connect, or invoke an MCP server in this workspace — use when the user says "using the MCP skill", asks to add/connect/enable/turn on an MCP, pastes an MCP URL or npx package, or wants DeepWiki/Mobbin tools this session.
---

# Add and invoke an MCP server

This is the invocative half. `mcp-config` is the schema reference; load it
only when you need field-level detail. Do the add here.

## Choreography

1. Name the server (short, lowercase, no spaces). Infer from the URL or
   package when the user did not pick one (`deepwiki`, `playwright`, …).
2. Classify the entry:
   - Remote / hosted: a `https://…/mcp` URL (Streamable HTTP). Prefer `/mcp`
     over legacy `/sse`.
   - Local / stdio: a `command` plus `args` (`npx -y @playwright/mcp`).
3. Persist to the **project** `.mcp.json` (never the global file unless the
   user said "every project"):

```sh
graff mcp add <name> --url https://host/mcp
graff mcp add <name> -- <command> [args...]
graff mcp add <name> --env KEY=VALUE -- <command> [args...]
```

`edit_file` on `.mcp.json` is equally valid. Do not commit secrets; OAuth
is `graff mcp login <name>`.

4. Connect **this** session. Editing the file does not attach tools to the
   running harness. Ask the user to run one of:

```
/mcp add <name> --url <URL>
/mcp add <name> <command> [args...]
/mcp trust
```

Then `load_tool_schemas` with `server` set to that name (or the exact
`mcp__<server>__<tool>` names) before calling anything.

5. If the tools still do not appear after a restart: the command is not on
   PATH, the URL is not HTTPS (localhost excepted), a token is missing, or
   consent was declined. Fall back to native tools and keep going.

## DeepWiki and Mobbin

When configured, boot skips a `deepwiki` / `mobbin` entry inherited from
global or plugin configuration unless `GRAFF_DEEPWIKI` / `GRAFF_MOBBIN`
is set, or `GRAFF_MCP_OPTIONAL=deepwiki,mobbin`.
A workspace `.mcp.json` that lists them is the project opting in. Startup
consent (`/mcp trust` or `--yolo`) still applies.

DeepWiki's public server is `https://mcp.deepwiki.com/mcp` (no auth). Tools
are `read_wiki_structure`, `read_wiki_contents`, and `ask_question`. Do not
webfetch DeepWiki pages; use those tools once loaded.

## Examples

User: "using the MCP skill, add this MCP: https://mcp.deepwiki.com/mcp"

- `graff mcp add deepwiki --url https://mcp.deepwiki.com/mcp`
- Ask them to `/mcp add deepwiki --url https://mcp.deepwiki.com/mcp` so this
  session can `load_tool_schemas` `server=deepwiki`.

User: "add playwright MCP"

- `graff mcp add playwright -- npx -y @playwright/mcp`
- Then `/mcp add playwright npx -y @playwright/mcp`.
