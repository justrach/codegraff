---
name: mcp-config
description: Inspect or change this workspace's MCP servers - use when adding, removing, or authenticating an MCP server, when MCP tools are missing or a server did not connect, or when the user asks how MCP config works here.
---

# MCP configuration

MCP servers are configured per workspace in `.mcp.json` at the project root.
Their tools reach the model as `mcp__<server>__<tool>`.

## The file

```json
{
  "mcpServers": {
    "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp"] },
    "sentry": {
      "command": "npx",
      "args": ["-y", "@sentry/mcp-server"],
      "env": { "SENTRY_AUTH_TOKEN": "..." }
    },
    "mobbin": { "url": "https://api.mobbin.com/mcp" },
    "internal": {
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer ..." }
    }
  }
}
```

- Local (stdio) server: `command` plus optional `args` and `env`. `env` values
  are literal strings - there is no `${VAR}` expansion.
- Remote server: `url`, Streamable HTTP. HTTPS is required except for
  localhost, and `headers` is for static tokens.
- `smolify` is a reserved core server; a workspace entry cannot shadow its
  pinned endpoint.
- Invalid JSON means zero servers load, quietly. If tools vanished after an
  edit, check the file parses first.

## Prefer the CLI for writes

```sh
graff mcp                                            # list configured servers
graff mcp add <name> -- <command> [args...]          # local server
graff mcp add <name> --env KEY=VALUE -- <command>    # with env
graff mcp add <name> --url https://host/mcp          # remote server
graff mcp add <name> --url https://host/mcp --header KEY=VALUE
graff mcp login <name>                               # OAuth for a remote server
```

Editing `.mcp.json` with `edit_file` or `write_file` is equally valid, and it is
how you remove a server (drop its key) or rename one. Do not commit a secret
into it: prefer `graff mcp login` (OAuth credentials are stored outside the
repo) or a token the user supplies at runtime.

## In-session, no restart

- `/mcp` - connected servers, tool counts, and any workspace servers still
  pending consent
- `/mcp add <name> <command> [args...]` and `/mcp add <name> --url <URL>` -
  connect one live and persist it
- `/mcp trust` - connect the workspace servers that were skipped at startup

## When a server is not connected

A workspace `.mcp.json` launches arbitrary local commands, so graff never
auto-spawns untrusted entries: it asks at startup, and without consent (or
`--yolo`) it starts with an empty but live registry. `/mcp trust` is the
in-session fix and `/mcp` shows what is pending. Remote servers pass the same
gate, because their arguments leave the machine.

After that, in likelihood order: the command is not on PATH, the package name
is wrong, the server needs a token that is not set, the URL is not HTTPS, or
the server needs an OAuth login (`graff mcp login <name>`).

## After changing config

Tools appear as soon as a server actually connects, which live `/mcp add` and
`/mcp trust` both do. Editing `.mcp.json` alone changes nothing in the running
session - connect the server live or restart.

MCP tools are accelerators, never requirements. When a server is missing or a
call fails, fall back to the native tools (`bash`, `read_file`, `webfetch`) and
keep going.
