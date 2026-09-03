# Browser sidecar with built-in annotations

Branch `feat/browser-sidecar`, off `release/v0.0.285`. Throwaway by design:
everything lives under `apps/native` plus one plan file, nothing touches the
Zig harness, so the branch can be deleted without a trace if the idea does
not earn its keep.

## What it is

A pane beside the transcript that shows a live Chrome tab, one per chat,
driven by [Kuri](https://github.com/justrach/kuri) (managed headless Chrome
over CDP, a single Zig binary). Two modes:

- **Browse.** The pointer, wheel and keyboard are forwarded to the page.
- **Annotate.** A click pins the element under it with a note. Pins are
  drawn over the frame from geometry the page reports, and the next prompt
  carries them ahead of the user's text: element identity (role, name,
  selector, size, position), the note, the page, and — when Kuri's snapshot
  names the same element — the `@eN` ref the agent's own actions take.

The block also tells the agent where the tab is (Kuri's port, the tab id,
the bearer token) and the four calls that matter: snapshot, action, evaluate,
highlight. The agent drives the very tab the user is looking at, and can
highlight an element back at them.

This is the agentation idea moved into the browser: no package in the app
under test, works on any page, and the output is actionable rather than
descriptive because it carries Kuri refs.

## Why the annotation layer is not injected into the page

The first design put an overlay script into every document via Kuri's
`/script/inject` (`Page.addScriptToEvaluateOnNewDocument`) and a
`Runtime.addBinding` channel (`/expose`, `/expose/calls`). Both work, and
the binding survives navigation. Two things argued against it for v1:

- Kuri reads a request head into an 8 KB buffer and takes the script in the
  query string, so an overlay bundle does not fit in one request, and a
  loader stub would need a fetch the page's content security policy may
  block.
- Everything the overlay needs — the element under a point, its accessible
  name, a stable selector, its box — is one `Runtime.evaluate` away, and
  drawing the outline and pins in the pane is trivial.

So the page is never modified. The first cut evaluated one expression per
hover and per click; that made the outline lag the pointer and a click
feel dead for a round trip, and it did not survive the first real try.
Annotate now fetches an *element map* — every interactive or text-bearing
element on screen with its box, name, selector and Kuri ref, one
`/evaluate` plus one `/snapshot`, about 50 ms for a Hacker News page —
and hit-tests it in the pane. Hover and pin are local and instant; the
map refreshes 350 ms after a scroll settles, every 2.5 s, and on
navigation. Pins are stored in page coordinates against the map's scroll
offset, so they stay on their element when the page scrolls, and the
wheel is forwarded in both modes. The injected overlay stays the right
answer for a *headed* Chrome window the user clicks in directly; that is
a later step.

## Lazy loading and resources

- Nothing runs until the pane is opened: `GET /api/browser` (status) and
  the frame endpoint never spawn. `POST open` is the only spawner.
- `lib/browser/kuri-supervisor.ts` starts one Kuri per dev server on the
  first free port from 8091, `HEADLESS=true`, its own profile under
  `~/.codegraff/browser`, a random bearer token, telemetry off. Kuri kills
  its Chrome when it is stopped.
- Idle stop after `GRAFF_BROWSER_IDLE_MINS` (default 20, 0 = never) of no
  requests. Frames count as use, so an open pane keeps it; a closed pane
  lets it go. The dev server's exit stops it too.
- Frames are JPEG (`/screenshot`, quality 55) requested one after another;
  a hidden tab drops to one frame every two seconds rather than stopping,
  so the picture is fresh the moment the tab comes back. (Stopping outright
  was tried first; Chrome's automation tabs report `document.hidden` even
  while visible, and a stopped loop looked like a broken pane.)
- The viewport is set to the pane's size, so frames are 1:1 and small.

## Pieces

| Piece | File |
|---|---|
| Kuri lifecycle, HTTP helper | `apps/native/lib/browser/kuri-supervisor.ts` |
| Element lookup expressions | `apps/native/lib/browser/inspect-script.ts` |
| Pin types, ref matching, prompt block (tested) | `apps/native/lib/browser/annotations.ts` |
| Route: status, frame, open/navigate/input/hover/inspect/snapshot/highlight | `apps/native/app/api/browser/route.ts` |
| Browser-side client | `apps/native/lib/browser-client.ts` |
| The pane | `apps/native/components/site/BrowserPane.tsx` |
| Harness wiring: tab-bar button, sidebar item, pins chip, prompt block | `components/site/GraffHarness.tsx`, `SidebarNav.tsx` |

## Not in v1, in order of value

1. **Agent tools instead of curl.** A stdio MCP shim that proxies to
   `/api/browser` would give the agent `browser_snapshot` / `browser_act` /
   `browser_highlight` without the bearer token in the prompt. Kuri ships a
   `kuri-mcp` binary, but it owns its own Chrome; the shim keeps one tab
   shared between the user and the agent.
2. **Headed mode.** `HEADLESS=false` gives a real window the user can click
   in; the pane becomes optional. That is where the injected overlay earns
   its place (pins made in the window, not the pane).
3. **Screenshot crops per pin** in the prompt block, for models that read
   images (`/screenshot` takes a clip).
4. **Ref stamping in Kuri.** Have `/snapshot` write `data-kuri-ref` on the
   nodes it numbers; then `inspect` reads the ref straight off the element
   instead of matching by accessible name.
5. Per-workspace start URL (a dev server per project) and a "tab is
   loading" indicator from `ready_state`.

## Abandon criteria

Frame polling too heavy on a laptop, or the pane too narrow to be useful at
1:1, or the annotation block not moving the agent's behaviour in practice.
Any of those, and the branch goes; the release branch is untouched.
