---
name: mcp
description: Add or adjust MCP servers when selected with $mcp or @mcp in the GUI composer.
---

# GUI MCP

This skill is supplied by the GUI for this request. It is not an engine skill.
Use ordinary file tools to edit MCP config JSON; do not patch the app or engine.

MCP is a host/client talking to local stdio servers or remote Streamable HTTP
servers. Adding a server means writing a `mcpServers` entry. The harness starts
those servers with new chats when **Start MCP servers** is on in Project settings.

If the user only invoked the skill, ask whether they want a local command or a
URL, a name, and whether it should apply to all folders or just this workspace.
If they already named a server, add it.

## Config files

Paths are supplied below these instructions.

- **User** (`~/.codegraff/mcp.json` unless overridden): every folder.
- **Workspace** (`.mcp.json` in the current folder): this folder only; it wins
  on a name conflict.

Read the target file first if it exists. Merge. Do not drop other servers. Do
not print env values or auth headers. Create the file if it is missing:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]
    },
    "docs": {
      "url": "https://example.invalid/mcp"
    }
  }
}
```

Names: letters, digits, `_` or `-`, start with a letter or digit, at most 64
characters. Stdio entries need `command` and optional `args` / `env`. HTTP
entries need `url` (HTTPS, or HTTP only for localhost). Do not invent `env`
keys. Do not disable unrelated servers.

## Validate and deliver

Parse the JSON after writing. Confirm the new name is present. Tell the user:

- Settings → MCP servers lists it (Active if Start MCP servers is on).
- Open a **new** chat to start it. A running tab keeps the agent it spawned with.
- Untrusted servers may need `/mcp trust` in the terminal the first time.

Do not restart the app. Do not rewrite the engine catalog.
