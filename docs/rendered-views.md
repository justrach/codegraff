# Rendered views

The model can draw. When a result is easier to see than to read — a chart, a
timeline, a layout mock, a before/after — it calls **`render_html`** with one
self-contained page and the desktop app shows that page inline in the
transcript, right where the turn happened. Nothing is configured for this and
nothing opens automatically: the model chooses to draw, and the turn is still
the turn.

The view keeps its own inline `<style>` and `<script>`, so a page can be
animated or interactive. Close view / Open view disposes and restores the
frame without touching the conversation.

## Where the page lives

One call writes one private snapshot:

```
$HOME/.graff/views/<32 hex id>.html      0600 file, 0700 directory
```

The tool result carries only the opaque path (`[Rendered view](…)`), which is
what the desktop matches on to render it. The page appears in model context
once — as the argument the model wrote — and never again. Snapshots persist
across transcript reloads and are yours to delete: they are ordinary HTML
files, so you can also open one in a browser, or `rm ~/.graff/views/*` to
reclaim the space. The transcript's link then shows an ordinary "no longer
available" frame.

## What a page can and cannot do

The file is served by the desktop's `/api/views` route under a containing
policy ([ADR 0104](adr/0104-model-drawn-pages-render-in-an-opaque-frame.md)):

- **It can** run its own inline script and style, draw anything CSS can draw,
  and inline images/fonts/media as `data:` or `blob:` URIs.
- **It cannot** reach the network — no `fetch`, no CDN script, no remote image
  or font, no websocket. `default-src 'none'` and `connect-src 'none'`.
- **It cannot** reach the app: the CSP `sandbox` directive gives the document an
  opaque origin, so there is no app DOM, no `localStorage`, no cookies, and no
  call into the desktop's own API routes. Links navigate only the frame, and
  forms and popups are refused.

That holds whether the transcript frames the page or you open the file's URL
directly, so a snapshot is a portable artifact rather than a GUI-only trick.

## In the REPL

The tool result names the saved path; open it in your browser from there. There
is no `/view` shortcut yet.

`--no-local-tools` strips `render_html` like any other host-writing tool
(`src/no_local_tools.zig`), because the snapshot lands on the machine running
graff.

## Development and regression checks

All of these are offline and need no model:

```sh
zig test src/html_view.zig        # the snapshot: verbatim bytes, opaque id, 0600, size bound
python3 scripts/test-render-html.py zig-out/bin/graff   # the engine: marker, verbatim file, refusal
cd apps/native && bun test lib/mcp-apps.test.ts   # link matcher + store guards
cd apps/native && bun run test:views              # containment in real Chrome
```

The engine fixture (`scripts/test-render-html.py`) drives the real binary with
a scripted model: it asserts the saved file is the model's page byte-for-byte,
the directory is 0700 and the file 0600, the marker carries the saved path in
the exact shape the desktop matches, the page never comes back to the model a
second time, and an oversized page is refused without writing anything.

`test:views` starts its own Next dev server, writes a fixture page into
`~/.graff/views` through the same path the engine uses, and asserts that the
inline script runs, the network fetch is refused by CSP, `top.document` is
unreachable, and the route answers 200/400/403/404 as documented.
