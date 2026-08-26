---
name: mcp-config
description: Inspect or change this workspace's MCP servers, or the user-level global ones - use when adding, removing, or authenticating an MCP server, when MCP tools are missing or a server did not connect, or when the user asks how MCP config works here.
---

# MCP configuration

MCP servers are configured per workspace in `.mcp.json` at the project root, and
per user in `~/.codegraff/mcp.json` for the servers you want in every project.
The two files use the same schema and are merged; a project entry wins over a
global one with the same name. Their tools reach the model as
`mcp__<server>__<tool>`.

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
- Invalid JSON in one file means zero servers load from THAT file; the other one
  still loads. If tools vanished after an edit, check the file parses first.
- `~/.mcpconfig.json` is not read - that path belongs to other MCP clients.
  Startup says so once if it exists.

## Prefer the CLI for writes

```sh
graff mcp                                            # list configured servers (global ones tagged)
graff mcp add <name> -- <command> [args...]          # local server
graff mcp add <name> --env KEY=VALUE -- <command>    # with env
graff mcp add <name> --url https://host/mcp          # remote server
graff mcp add <name> --url https://host/mcp --header KEY=VALUE
graff mcp login <name>                               # OAuth for a remote server
```

`graff mcp add` and `/mcp add` always write the project `.mcp.json`, never the
global file - adding a server to one repository must not edit every other one.
Editing either file with `edit_file` or `write_file` is equally valid, and it is
how you remove a server (drop its key) or rename one. Do not commit a secret
into it: prefer `graff mcp login` (OAuth credentials are stored outside the
repo) or a token the user supplies at runtime.

## In-session, no restart

- `/mcp` - connected servers, tool counts, and any workspace servers still
  pending consent
- `/mcp add <name> <command> [args...]` and `/mcp add <name> --url <URL>` -
  connect one live and persist it
- `/mcp trust` - connect the servers that were skipped at startup, project and
  global alike

## When a server is not connected

Either config file launches arbitrary local commands, so graff never auto-spawns
untrusted entries: it asks at startup, and without consent (or `--yolo`) it
starts with an empty but live registry. A global entry gets no extra trust for
being global - it just follows you into every project. `/mcp trust` is the
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
