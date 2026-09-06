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
`.graff/sessions/<name>.session.json` (`--resume <name>`). `/api/sessions`
peeks each file's header (not the messages array), lists the current
workspace then `~/.graff/sessions` (ADR 0059), and pages 24 at a time
(`?limit=&cursor=&q=&scope=`). The sidebar shows a dated preview; Conversations
is the full library — grouped by day, searchable, infinite-scroll. Opening
a past session renders its transcript at once and spawns the tab's agent
with `--resume`, so a follow-up continues with the model's memory intact.
`?root=` scopes any of it to one workspace, and `DELETE` archives a chat
(the file moves into an `archived/` directory beside it) or removes it.

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

- **Open a folder…** (also the caret beside the tab bar's folder chip)
  opens a folder picker (`/api/workspaces` walks one level at a time,
  marks git roots, takes a typed or pasted path) and switches to the
  folder you pick.
- **Workspace settings…** edits the active workspace: display name, the
  model new tabs spawn with, whether tools are auto-approved
  (`graff acp --yolo`), and whether each tab's agent starts the MCP
  servers from `~/.codegraff/mcp.json` (off runs it with `GRAFF_MCP_CONFIG`
  pointing at an empty config: with a typical config every tab otherwise
  costs a gigabyte or more of server processes). *Forget* removes it
  from the switcher only.
- Switching workspaces moves the tab you are looking at when nothing has
  been asked in it yet: picking a folder should change the folder in
  front of you, so its agent is respawned there rather than a second tab
  appearing. A tab that already holds a conversation keeps its own
  folder, because its agent is bound to that folder at spawn — the chip
  in the tab bar and each split's header name the folder that tab runs
  in, and the switcher names the one new tabs will use.

`/api/acp` bootstrap, `/api/sessions`, `/api/fs` and `/api/git` all take
the workspace root (`cwd` / `?root=`) and fall back to the default from
`GRAFF_CWD` or the repo root.

## Split view and tab names

`⌘D` (or the split button in the tab bar) opens another chat beside the
ones on screen, up to four columns. Each has its own transcript,
composer, model and scroll position, and each split names the chat and
the folder it runs in, since a split can be in a different workspace
from the tab beside it. The × in a split's header closes that one; the
split button closes them all. Clicking a tab that is already a split
swaps it with the main column, so the same chats stay on screen.

A tab is named by the model, not by chopping up the prompt: the first
message of a tab goes to `graff title` through `/api/title`, which
answers with a short phrase on a small model without touching the chat's
own session. The prompt's first words stand in until it answers, and
stay if it cannot. A session open in a tab shows that name in the
sidebar too.

## Managing chats

Hovering a chat in the sidebar reveals two controls. **Archive** moves the
session file under `.graff/sessions/archived/`, so the chat leaves the list
but the conversation stays on disk and can be moved back by hand.
**Delete** removes the file. Either way the chat's tab closes with it, and
the row goes at once rather than after the next poll of the session
directory.

## Keyboard and commands

Type `/` in any composer to search the complete command catalog advertised by
Graff, including `/compact`. New tabs inherit it before starting a coding session.
Command behavior belongs to the engine; terminal display settings retain their
terminal meaning. Menus remain inside the window and scroll independently.

The desktop adapts familiar Ghostty bindings to chats and split panes:

| Keys | Action |
|---|---|
| `⌘N` / `⌘T` | New chat |
| `⌘W` | Close the active chat |
| `⇧⌘T` | Reopen the last closed chat |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous chat |
| `⇧⌘]` / `⇧⌘[` | Next / previous chat |
| `⌘1`…`⌘8` / `⌘9` | Select a tab / select the last tab |
| `⌘D` / `⇧⌘D` | Split right / down, up to four panes |
| `⌘]` / `⌘[` or `⌥⌘` + arrow | Focus the next / previous split |
| `⇧⌘Enter` | Zoom the active split / restore all splits |
| `Ctrl+⌘` + arrow | Resize the active split |
| `Ctrl+⌘=` | Equalize split sizes |
| `⌘\` | Toggle splits |
| `⌘O` | Open a workspace folder |
| `⌘J` | Show / hide the workspace terminal |
| `⌘K` in the terminal | Clear the visible terminal |
| `⌘Enter` / `Ctrl+⌘F` | Toggle fullscreen |
| `⌘+` / `⌘−` / `⌘0` | Increase / decrease / reset interface zoom |

The File menu lists the main actions. Standard copy, paste, undo and text selection
remain native. Terminal-only actions such as sending escape sequences have no
chat equivalent. A web browser reserves some shortcuts for its own tabs.

The macOS workspace terminal opens your login shell in the active folder. Drag
its top edge to resize it. Hiding it preserves the session; **End session** stops
it. Up to four workspace shells can stay open, with bounded output history.

Native `read_file` accepts PNG, JPEG, GIF and WebP images up to 5 MiB when the
active model supports vision. Read one image at a time: its pixels reach the
next model request in the same turn. Unavailable images produce an explicit
result instead of silently claiming that the model saw them.

Click the workspace name to search by name **or folder path**. The current
workspace is first; full paths distinguish folders with the same name. Arrow keys
browse results, Enter selects, and Escape returns to the previous control.

## GUI regression checks

Run these from this package with Bun:

```sh
bun run build
bun run test:desktop
bun run test:visual
```

The visual runner uses isolated synthetic data and makes no engine or model API
calls. It checks turn progress, interruption states, large tool groups and output,
long history, reading position during streaming, fullscreen transitions, command
menus, keyboard splits, workspace search and the Agents panel. Tool groups start
collapsed; expanded groups page their rows, and large output previews preserve
the beginning and end with an explicit omission marker. Older messages load on
request. These bounds limit rendering; they do not cap stored conversation size.

For a separate, opt-in real coding trial, run `electron/gui-coding-smoke.cjs` with
the package's Electron executable. It uses configured credentials in a disposable
workspace, checks the resulting code independently with Bun, then runs `/compact`.
Keep its logs and screenshots local. `bun run test:performance` adds synthetic
workload measurements; startup paint alone does not measure conversation UX.

## Browser sidecar (experimental)

The **Browser** button in the tab bar (or the sidebar's Browser item)
opens a pane showing a live Chrome tab that belongs to the chat. It is
[Kuri](https://github.com/justrach/kuri)'s managed headless Chrome, driven
over `/api/browser`; install Kuri (`curl -fsSL https://kuri.trilok.ai/download | sh`)
or set `KURI_BIN`. Nothing runs until a pane is opened, and a browser that
sees no requests for `GRAFF_BROWSER_IDLE_MINS` (default 20, `0` = never) is
stopped again. Its footprint is capped: when Kuri and its Chrome tree pass
`GRAFF_BROWSER_MAX_RSS_MB` (default 3072, `0` = no cap) they are stopped
and the next request starts a fresh browser. Kuri is started with
`KURI_ALLOW_LOCAL=1` so dev servers on this machine open; a Kuri older
than that flag refuses localhost.

- **Browse** forwards clicks, scrolling and typing to the page.
- Drag the pane's left edge to resize it (double-click the edge for the
  default width, arrow keys when it has focus); the width is remembered
  and the page's viewport follows, so pins stay on their elements.
- The address bar takes `localhost:3000`-style addresses; Cmd/Ctrl+L
  focuses it from the page. The width control next to it shows the page
  at the pane's own width (1:1) or a wider layout (768, 1024, 1280 px)
  scaled down, so a desktop layout can be pinned as it will ship. A
  workspace's pane remembers its last page and goes back there when it
  opens on a blank tab (after a reload, or a browser restart).
- **Annotate** pins the element under a click, instantly: the page's
  pinnable elements (boxes, names, selectors, Kuri refs) are fetched as
  one map and hit-tested in the pane, so hover and click never wait on
  the network; the map refreshes after a scroll and every few seconds.
  A note is optional (Enter keeps it). Pins keep page coordinates and
  follow the page as it scrolls; the wheel scrolls in both modes and, in
  Annotate, so do the arrow keys, Page Up/Down, Space, Home and End. Nothing is injected, so any
  page works. Pins go behind the chat's next prompt as a block naming
  each element (role, name, selector, box), the note, and — when Kuri's
  snapshot names the same element — its `@eN` ref, plus the tab's address
  so the agent can snapshot, act on, and highlight the very page the user
  is looking at. **Ask graff** in the pane sends them right away, and
  the tab reloads by itself once a turn that carried pins has finished,
  so the result is on screen without a click.

The design and what is deliberately left out are in
`plans/2026-09-03-browser-sidecar.md`. The sidebar footer names the tab's graff
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
