# 0036. Computer Use keeps the signed Codex bridge

Status: accepted 2026-08-26

## Context

The OpenAI Computer Use plugin declares `bundledContentVariant: node-repl`.
Its skill imports `@oai/sky` through Codex's `node_repl`, but Graff previously
advertised only the plugin's raw MCP client. Both that client and a directly
spawned node_repl reached the macOS service and failed with `Sender process is
not authenticated`; the service authenticates the signed process chain.

Launching the same configured node_repl through the sibling signed `codex
sandbox` binary, with the Computer Use Unix socket explicitly allowed, passed
authentication. A live read-only call returned the installed app catalog; a
later locked-screen run returned the service's normal lock guard rather than
the sender-authentication error.

ADR 0023 rejects an embedded V8 / Code Mode runtime because RLM already owns
that product role. Weakening or spoofing the Computer Use check is not an
acceptable compatibility layer.

## Decision

On macOS, when an enabled Codex plugin selects the `node-repl` content
variant, do not advertise its raw Computer Use MCP launcher. Read the configured
node_repl executable from `~/.codex/config.toml`, accept only the ChatGPT
Resources `cua_node/bin/node_repl` layout, and synthesize one consent-gated
`node_repl` MCP server:

- the command is the sibling signed `codex` binary;
- `codex sandbox -P :danger-full-access` launches node_repl with only the
  Computer Use socket allowlisted;
- the environment contains the minimal trusted `@oai/sky` module/service
  paths and process basics; and
- the skill addendum maps `node_repl` calls to Graff's qualified
  `mcp__node_repl__js*` names without changing confirmation policy or image
  handling.

If the signed layout cannot be proven, retain the plugin-declared MCP fallback
for custom hosts. A Graff/global/project `node_repl` entry still wins.

## Consequences

- Computer Use is usable without adding a Graff-owned JS runtime or crossing
  the service's authentication boundary.
- Plugin MCP remains subject to the existing `/mcp trust` / `--yolo` consent
  gate (ADR 0007).
- This adapter is intentionally macOS/Codex-layout-specific. A future public
  cross-harness Computer Use protocol should replace it; an unsigned direct
  launcher should not.
