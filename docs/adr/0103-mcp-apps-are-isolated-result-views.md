# MCP Apps are isolated result views

## Context

Flattening tool output to text discards the UI resource and structured result that an MCP App needs. A desktop browser can display these results; a terminal needs a browser handoff. Rendering server-provided HTML inside the desktop's origin would grant it unrelated local application privileges.

## Decision

Keep an MCP App's declared UI resource URI during discovery, including the legacy metadata spelling. Exclude app-only tools from the model catalog. Advertise the UI extension on legacy and modern MCP connections.

After an app-enabled tool returns, read its declared resource with a bounded request. Accept only matching `ui://` resources with the MCP Apps MIME type, either text or base64 HTML. Save the resource, arguments, and complete tool result as a private, size-bounded local snapshot. Only a snapshot link and ordinary result text enter model context; resource HTML and result `_meta` do not.

The GUI recognizes the opaque snapshot id before bounding tool details and renders it in a sandbox. A different-origin proxy isolates the inner app, relays only messages from the expected windows, enforces declared CSP domains with restrictive defaults, and performs the MCP Apps handshake. `/mcp apps` opens the latest snapshot from the current REPL session. Nothing opens automatically in the terminal.

This is a result-view host. It supports input/result delivery, resizing, and user-visible source navigation. It does not execute app-initiated tools, read further resources, send agent messages, or update model context. Unsupported requests receive explicit errors. External links are presented for a user click; unsafe schemes are rejected. Clipboard controls remain host/browser-dependent; opaque sandbox origins can require an app's copy-link/manual fallback.

## Consequences

Existing text and image output continues when an app resource is absent, invalid, oversized, or unavailable. Snapshots persist for transcript replay and contain tool data; users can remove them to reclaim disk space. There is no live connection or live tool authority in a saved view. Supporting app-initiated actions later requires routing to the originating MCP session through the existing approval path, not a generic renderer-to-tool proxy.

Regression coverage includes metadata/visibility validation, native snapshot creation and private-metadata separation, ACP id retention, constrained file reads, actual GUI rendering, standalone browser rendering, source links, blocked tool requests, CSP, and iframe escape attempts. Fixtures are local and deterministic; no model API is needed.

Reference: [MCP Apps stable specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx).
