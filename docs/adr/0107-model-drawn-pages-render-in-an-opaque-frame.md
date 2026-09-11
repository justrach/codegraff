# 0107. Model-drawn pages are private snapshots in an opaque frame

Status: accepted 2026-09-11

## Context

A result the model can only *describe* — a layout, a chart, a before/after — is worse than one it can show. The terminal has no room for it, and the desktop transcript renders text, markdown, images, and MCP app results, nothing else.

MCP Apps already solved the containment half ([0103](0103-mcp-apps-are-isolated-result-views.md)): a server's declared HTML becomes a private snapshot under `~/.graff/mcp-apps`, model context carries only an opaque link, and the GUI frames it. That path needs a `ui://` resource, an MCP handshake, and a tool that declares a UI — none of which a page the model itself wrote has.

Two shortcuts were available and both are wrong. Injecting the markup into the app's own document (`dangerouslySetInnerHTML`) hands model-authored script the desktop preload bridge and every local API route. Rendering any `.html` file already in the workspace would run third-party bytes inside the app too, and would put the transcript's trust in whatever happens to be on disk.

## Decision

`render_html` writes the page **verbatim** to one private snapshot — `$HOME/.graff/views/<32-hex>.html`, 0700 directory, 0600 file — and returns a result line carrying only the opaque path. One call, one view. No wrapper document, no host script, no handshake; nothing about the page re-enters model context.

The desktop's `/api/views` serves that file under a containing policy:

```
sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline';
style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:;
font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none';
form-action 'none'; base-uri 'none'; frame-ancestors 'self'
```

The CSP `sandbox` directive is the containment — not the iframe attribute — so the document gets an opaque origin: no app DOM, no cookies, no storage, no API reach. This also applies to direct visits to the desktop HTTP route. Opening the raw file from disk does not preserve the HTTP sandbox headers. `default-src 'none'` with `connect-src 'none'` keeps it off the network entirely; a page inlines its images as `data:`/`blob:` URIs. Inline script and style stay on, because a self-contained page is exactly what they are for.

The GUI matches the opaque link (`[Rendered view](…/.graff/views/<32hex>.html)`) the way it matches an app result and renders it in the transcript with close/open chrome, so the model decides when a turn gets a picture instead of a paragraph. A page that needs the network needs a different tool, not a weaker policy.

## Consequences

The model chooses presentation; it cannot choose privilege. Because the snapshot is the model's own bytes, the file stays openable and greppable on disk, and a view is not a screenshot — it keeps its own inline script and style.

What a page cannot do: fetch, load a CDN script or font or image, open a popup, post a form, or reach outside its frame. Its links navigate only its own frame. Rich remote-hosted content is out of scope by construction, not by a missing flag.

Views accumulate like MCP app snapshots; deleting `~/.graff/views` reclaims the space, and the transcript's link then 404s into ordinary "no longer available" text.

`render_html` writes to the host, so `--no-local-tools` strips it exactly as it strips `write_file`. Plan mode still allows it: a diagram is a better plan than a paragraph, and the write lands in the snapshot directory, never the workspace.

Verification is offline. `zig test src/html_view.zig` covers the snapshot itself (verbatim bytes, opaque id, 0600, size bound, no home, no id collisions). `bun test lib/mcp-apps.test.ts` covers the link matcher and the store's traversal/symlink/size guards. `bun run test:views` covers the containment in real Chrome: inline script runs, the network fetch is refused by CSP, `top.document` is unreachable, the route's policy and its 400/403/404 answers hold.

The desktop retains `create_html` as its explicitly static HTML/CSS tool (ADR
0106). `render_html` is the engine tool for a self-contained interactive page.
Their distinct result markers survive live updates and saved transcript replay.
Neither tool should manufacture a workspace diff. Offscreen interactive views
release their iframe and restart from the saved snapshot when brought back.
On Windows the snapshot directory inherits the user's profile ACL; POSIX
permission calls must not run on that platform.
