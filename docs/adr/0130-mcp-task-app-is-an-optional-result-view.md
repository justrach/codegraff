# 0130. MCP task app is an optional result view

## Context

A text-only task answer obscures process failure, limits, and truncated output.
MCP Apps hosts can present an interactive view alongside the conversation.

## Decision

Negotiate the UI MIME type from the client's extension capability. Attach a
static `ui://` resource to `run_task` only for compatible clients. Bundle the
HTML into the executable, request no external origins or device permissions,
and render all task text through textContent. Expose only the exact template
URI through resource reads.

Return schema-described status, text, truncation and limits alongside the
ordinary text content for every task outcome, including execution failures.
The view shares the desktop palette from `apps/native/app/ui-theme.css`,
embedded at compile time, and follows its conversation layout. It follows host
theme changes, filters output lines, and toggles wrapping.
It receives task input/results but grants no app-initiated execution authority.
Host-side tool calls retain the launch-time execution contract from ADR 0129.

## Consequences

A single binary serves both ordinary MCP clients and Apps hosts, with no UI
build chain or CDN requirement. Completion means the process exited cleanly,
not that its claims were independently verified. The view is a final-result
inspector, not a live task manager. Progress, cancellation and retries require
an explicit execution lifecycle design before being added to the view.

Reference: [MCP Apps specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx).
