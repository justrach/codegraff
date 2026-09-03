# Codegraff native app (merjs + Beautiful UI)

The Tauri desktop app in `gui/` is unchanged. This directory is a new native
surface:

- **Shell:** merjs `examples/desktop` — Zig → ObjC → `NSWindow` + `WKWebView`
  (no Electron). merjs is a separate repo; we copied only the window pattern.
- **UI:** [Beautiful UI](https://github.com/slev12397/beautiful-ui) primitives
  (MIT) + design tokens, composed as a graff harness.
- **Backend:** this repo's `graff acp` (Agent Client Protocol over stdio).
  Mid-turn `session/update` notifications render thinking and tool use from
  the first call (ADR 0032). `graff serve` is not required.

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
browser  →  Next.js /api/acp  →  graff acp --yolo   (stdio JSON-RPC)
                (this app)         session/update → thought / tools / text
```

The Next.js route owns one `graff acp` child **per chat tab** (the agent
holds a single live session per process and has no `session/load`, so a
tab's conversation memory is its child). The browser never speaks stdio; it
POSTs ACP methods with its `<page>:<chat>` handle and reads an NDJSON
stream of the same JSON-RPC lines the agent wrote. Closing a tab or leaving
the page reaps its agents; tabs run turns concurrently.

| ACP `sessionUpdate` | primitive |
| --- | --- |
| `agent_thought_chunk` | `ThinkingState` |
| `agent_message_chunk` | `StreamingText` |
| `tool_call` / `tool_call_update` | `ToolChips` (+ diff chips for edits) |
| `todo_write` in `rawInput` | `TaskRows` in the side pane |

`session/cancel` sets the agent's Esc interrupt. A model change respawns
the child with `--model`. Approvals (`ask_user` / `session/request_permission`)
are not on this path: the child runs `--yolo` so tools execute from the
first turn.

The model picker is live, not a hardcoded list: `graff/models` (a vendor
JSON-RPC method on the same stdio agent) returns the catalog with
per-provider credential state in the REPL's election order (signed-in
plan, then local, credits, api). The UI shows only authenticated seats
and re-reads `current` after every respawn, so the picker reflects what
graff's fuzzy `--model` resolution actually chose.

History is graff's own: every tab's agent autosaves to
`.graff/sessions/<name>.session.json` in the workspace (`--resume <name>`),
and the sidebar lists that directory — grouped by day, searchable — via
`/api/sessions`, which peeks each file's header rather than parsing it.
Opening a past session renders its saved transcript at once and spawns the
tab's agent with `--resume`, so a follow-up continues the conversation with
the model's memory intact.

The workspace itself is walkable: `/api/fs` (list/read, plus macOS
`open`/`open -R` passthroughs) is sandboxed to the tab's cwd and backs
a files pane — the folder chip in the tab bar or the sidebar's
Workspace item opens it. Tool-row chips and path-looking inline code in
answers (`src/acp.zig`) jump straight to that file; markdown files
render, code shows mono, binaries hand off to Open.

## Workspaces

A workspace is a folder graff runs in. The switcher at the top of the
sidebar lists every workspace this browser knows (`localStorage`; the
server only validates a root it is handed) with the active one checked:

- **New workspace…** opens a folder picker (`/api/workspaces` walks one
  level at a time, marks git roots, takes a typed or pasted path) and
  switches to the folder you pick.
- **Workspace settings…** edits the active workspace: display name, the
  model new tabs spawn with, and whether tools are auto-approved
  (`graff acp --yolo`). *Forget* removes it from the switcher only.
- Switching workspaces changes the sidebar's session list and where new
  tabs open. A tab's agent is spawned in the workspace that was active
  when the tab opened and stays there — the folder chip in the tab bar
  names the tab's own workspace, the switcher names the active one.

`/api/acp` bootstrap, `/api/sessions`, `/api/fs` and `/api/git` all take
the workspace root (`cwd` / `?root=`) and fall back to the default from
`GRAFF_CWD` or the repo root. The sidebar footer names the tab's graff
session (`native-…`, the `--resume` target); clicking it copies the
command that continues the same conversation in a terminal.

## Run

```bash
# 1. agent binary (repo root)
zig build

# 2. UI — it spawns zig-out/bin/graff acp itself
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

`npm test` runs the ACP and `--json` event-mapper unit tests (no provider
calls).

Set `GRAFF_BIN` if the binary is not at `zig-out/bin/graff`. Set
`GRAFF_CWD` / `GRAFF_ACP_CWD` to pin the workspace (defaults to the repo
root when the app is started from `apps/native`). `GRAFF_YOLO=0` opts out
of auto-approve (tools will be denied; ACP has no permission UI yet).
