# 0106. Desktop HTML explanations are private static result views

Status: accepted

The desktop MCP adapter exposes `create_html` through ordinary deferred tool
discovery. Each call validates and saves a private immutable title/source snapshot
and returns an opaque result reference. Live ACP, ordinary result decoding and
saved transcript projection retain that reference before truncating tool details.
No new always-on terminal tool or external site is created.

The GUI retrieves snapshots through a same-origin JSON route with validated ids,
no-follow file reads and bounded source size. Its host owns Preview/HTML, Copy
and Hide. Original source remains copyable; a missing snapshot has a readable
fallback. Hidden and offscreen results release their frames and fetched content,
while retaining layout space to avoid scroll jumps.

Render only a supported HTML/CSS subset in an opaque iframe with no sandbox
permissions. Remove unsupported elements and attributes using an inert template,
bound markup size and nesting, and enforce a restrictive CSP. Scripts, external
resources, links, forms, popups, parent-document access and app/tool authority are
unavailable. Native details/summary controls still work. Unsupported original
markup remains available in source view and Copy; the host discloses the static
preview limitation. This deliberately does not inherit MCP App script, popup or
network capabilities (ADR 0103).

Snapshots persist for replay and consume local disk. Writes stop at the bounded
snapshot count rather than silently deleting saved results. Explicit revision
updates, automatic retention management and JavaScript execution are future work.

`bun run test:html-tool` covers real model-protocol tool discovery/selection,
Bun desktop MCP execution, Graff ACP, the production GUI, original-source copying,
iframe interaction/isolation and saved conversation replay after reload. The
model replies are scripted offline. Store tests cover source limits, invalid ids,
private permissions and symlink rejection; GUI concept tests cover restricted
markup. Nothing in this feature uploads telemetry.
