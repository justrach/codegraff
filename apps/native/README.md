# Codegraff native app (merjs + Beautiful UI)

The Tauri desktop app in `gui/` is unchanged. This directory is a new native
surface:

- **Shell:** merjs `examples/desktop` — Zig → ObjC → `NSWindow` + `WKWebView`
  (no Electron). merjs is a separate repo; we copied only the window pattern.
- **UI:** [Beautiful UI](https://github.com/slev12397/beautiful-ui) primitives
  (MIT) + design tokens, composed as a graff harness.
- **Backend:** this repo's `graff serve` HTTP/NDJSON bridge (same `--json`
  events the TypeScript SDK already speaks).

## What was copied, what was dropped

Copied from Beautiful UI:

- `components/primitives/*`
- `components/atoms/*` (primitives depend on them)
- `app/globals.css` (`:root`, `.dark`, `@theme`, radii, shadows, motion)
- Inter + JetBrains Mono via `next/font` in `app/layout.tsx`
- IceCreamHarness chrome (tabs, sidebar, prompt bar, window radius 14)

Dropped:

- **posthog** / `instrumentation-client.ts` / email capture
- **cuelume** interaction sounds
- **dialkit** tuning overlay
- **`@central-icons-react`** — commercial; `CENTRAL_LICENSE_KEY` is not set
  here, so SidebarNav uses the free stroke set in `lib/icons.tsx`
- Ice-cream `SCENARIOS` / `matchScenario` demo data

Kept (free): `tailwindcss` v4, `shadow-plugin`, `glimm` (prompt-bar sweep),
`iconoir-react`, `liveline`.

## How the harness talks to graff

```
browser  →  Next.js /api/graff/*  →  graff serve  →  graff --json child
                (this app)           :8787           NDJSON events
```

The proxy exists because `graff serve` only opens CORS when a Bearer token is
set. Same-origin `/api/graff` keeps the browser simple.

| graff event | primitive |
| --- | --- |
| `reasoning` / `model_call_started` | `ThinkingState` |
| `text` | `StreamingText` |
| `tool_call` / `tool_result` | `ToolChips` (+ diff chips for edits) |
| `ask_user` | `ApprovalCard` → `{"type":"answer"}` |
| `todo_write` | `TaskRows` in the side pane |
| `turn` / `error` | settle / error line |

Live-control (`set_model`, `cancel`) uses the same protocol as
`sdk/ts/remote.ts`.

## Run

```bash
# 1. agent backend (repo root)
zig build
./zig-out/bin/graff serve --port 8787

# 2. UI
cd apps/native
cp .env.example .env.local   # optional
npm install
npm run dev                  # http://127.0.0.1:3000
```

macOS window (after the UI is up):

```bash
zig build-exe apps/native/desktop/main.zig -O ReleaseSmall \
  -femit-bin=zig-out/bin/graff-native \
  -framework AppKit -framework WebKit
GRAFF_NATIVE_URL=http://127.0.0.1:3000 ./zig-out/bin/graff-native
```

Linux has no WKWebView in the merjs shell — use the browser, or `xdg-open`
from `desktop/main.zig`. See `desktop/README.md`.

`npm test` runs the event-mapper unit tests (no provider calls).

Offline UI check (not the real agent): `npm run mock-serve` on :8787 streams
the same NDJSON shapes so the page can be clicked without a provider key.
