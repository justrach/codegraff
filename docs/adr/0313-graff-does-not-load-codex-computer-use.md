# 0313. graff does not load Codex's computer-use plugins

Status: accepted 2026-11-04. Supersedes [0036](0036-computer-use-keeps-the-signed-codex-bridge.md) and [0119](0119-computer-tools-receive-caller-context.md).
Computer use came back as nanocua: [0314](0314-nanocua-is-grafts-computer-use.md).

## Context

ADR 0209 took computer use out of the desktop app and left one path: graff
loaded Codex's computer-use plugins and adapted to them. That path was an
adapter to another product's private surface. It launched a process from that
product's install layout, sent the turn metadata its service requires, carried
an elicitation policy written for its JavaScript API, added a skill addendum,
and rewrote its error text. All of that lived in graff's general MCP client for
the benefit of one plugin family.

## Decision

Graff has no computer use of its own and does not offer Codex's. `plugin_codex`
skips the `computer-use` and `unified-computer-use` plugins even when they are
enabled, so neither their MCP servers (`node_repl`, `cua_repl`, the raw client)
nor their skills reach the catalog. The signed-sandbox launcher, turn metadata,
skill addendum and error rewrites are removed.

A server the user configures under any name remains an ordinary MCP server,
with no host metadata (ADR 0007). Graff shows no forms, so every elicitation is
declined, including the defaults it used to fill for read-only requests.

## Consequences

- MCP dispatch has no per-vendor branch, and no state on the agent for it.
- `cua_repl` also served Codex's browser surface; that goes with it. The desktop
  browser pane (ADR 0071) is separate and stays.
- The test-only native input driver (ADR 0209) stays; agents cannot reach it.
- graff still advertises form elicitation in its handshake. Whether it should,
  given that it declines, is a separate decision for every MCP server.
- Computer use in graff, if it returns, is a new decision and a new record.
