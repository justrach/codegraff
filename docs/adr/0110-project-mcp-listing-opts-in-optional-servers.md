# 0110. A project MCP listing opts in optional servers

Status: accepted 2026-09-13

## Context

Optional server names were filtered at startup even when the workspace
explicitly configured them. Adding one to `.mcp.json` appeared to succeed,
but the next session silently skipped its handshake.

## Decision

- A server listed in the project `.mcp.json` opts in that optional server.
- Optional entries inherited only from global or plugin configuration retain
  their environment opt-in requirement.
- Opt-in selects which configured servers may start. The existing startup
  consent gate still applies equally to project and inherited servers.
- The bundled `mcp` skill explains configuration and connecting tools in the
  current session; `mcp-config` remains the detailed schema reference.

## Consequences

Project configuration works without an additional environment switch. Imported
extras stay quiet by default, and merely writing configuration does not grant
permission to connect. The offline `scripts/test-mcp-optional.py` fixture
checks both optional server names, both configuration scopes, explicit opt-in,
and startup with and without consent.
