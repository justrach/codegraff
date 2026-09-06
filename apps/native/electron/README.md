# Electron desktop trial

Run `./script/build_and_run.sh` from the repository root, or use the Codex Run
action. It builds the production UI with Bun, packages Chromium, Bun, graff,
and the SwiftUI Activity sheet, then opens `zig-out/electron/Codegraff.app`.
Builds currently target Apple Silicon macOS 14+; Liquid Glass uses macOS 26+.
Source builds are signed locally for development. The
[packaged v0.0.289 download](https://github.com/justrach/codegraff/releases/download/v0.0.289/Codegraff-macos-arm64.zip)
is Developer ID signed and notarized. Unzip it and move Codegraff.app to Applications;
the runtime, engine, browser and native components are included.

The application starts its own loopback server on port 3788 (a free port if
occupied). The stable origin retains local UI preferences; a fallback port has
separate preferences. An old Next
server on port 3000 is irrelevant. Opening the bundle directly uses the home
directory as its initial workspace; the Run action selects this checkout.

Coding remains in `graff acp`. The browser is a sandboxed `WebContentsView`:
normal typing, selection, scrolling, and navigation use Chromium directly.
Use **Pin element**, click the page, add a note, and **Ask graff**. The pinned
page's authenticated automation endpoint travels with the prompt. Electron
provides no model loop or coding tools of its own.

Blank browser panes and empty chats start no extra browser or coding renderer.
Hidden browser pages suspend after one minute; reopening reloads their URL.
This releases memory but discards unsaved web form state. Closing the browser
releases it immediately. At most three browser views remain live across chats.
The View menu can release every browser page.

**Codegraff → Activity…** (`⌘,`) opens a native SwiftUI sheet showing an on-demand
process-tree sample. macOS 26 uses grouped Liquid Glass surfaces. RSS sums may
double-count shared pages; CPU is the lifetime average from `ps`, not a sampled
instantaneous peak. Closing the application terminates its Bun/ACP process group.

Run checks with Bun from `apps/native`:

```sh
bun test electron/policy.test.cjs lib/browser/annotations.test.ts
bun x tsc --noEmit
```

After packaging, a real Electron smoke test needs no paid model calls:

```sh
GRAFF_CWD="$PWD" GRAFF_ELECTRON_SMOKE=/tmp/graff-electron-smoke.json \
  zig-out/electron/Codegraff.app/Contents/MacOS/Electron
```

The existing AppKit/Kuri shell remains a fallback through
`bash apps/native/desktop/build-app.sh`. Its release updater is not reused by
this local Electron trial. Browser permissions are denied by default; a
permission UI and release updater are follow-up distribution work.

## macOS computer use and agent browser tools

**Codegraff → Computer use…** enables or disables laptop control for this launch
and requests macOS Accessibility and Screen Recording permissions. Grant those
to Codegraff in System Settings; a relaunch may be needed. The agent cannot
enable this switch. App snapshots, screenshots and input are requested on demand.
There is no background screen recorder. Native snapshots use expiring element
IDs and actions target an explicit foreground app. Secure fields need user input.

With workspace MCP enabled, graff discovers
`mcp__codegraff_desktop__browser` and `mcp__codegraff_desktop__computer` through the
bundled Bun MCP adapter. This works without a browser pin. The browser tool uses
the embedded page for snapshots, images, form input, selections, hover, keys,
scrolling, navigation, find and zoom. The toolbar also provides find and zoom.
The computer tool discovers running apps, inspects Accessibility trees, activates
apps, presses elements, sets values, clicks, types, sends shortcuts, scrolls and
captures screens. Screen captures include display bounds and image dimensions.

Kuri cannot start through this desktop's legacy browser routes. The generated
MCP config omits Kuri entries from the global config, without editing the source
configuration. Independently configured project/plugin tools are separate from
the desktop browser and are not uninstalled.

## Profiler and feedback

The **Performance** menu starts/stops a bounded ten-minute recording, marks a
candidate phase, and exports a JSON feedback report through the native save
panel. Graff can perform the same measurements with
`mcp__codegraff_desktop__profiler`. Reports compare baseline and candidate RSS,
interval CPU, main-loop delays, renderer long tasks, navigation/action durations
and fixed failure categories. CPU can miss children that exit between samples.
Profiling is off by default and samples every two seconds while enabled.

Reports are assembled from an explicit field allowlist. They contain no prompts,
model names, page titles, URLs, file paths, account/session identifiers, raw
exceptions, screenshots or free-form labels. There is no upload endpoint or
automatic transmission. Review the local JSON before attaching it to feedback.

The model picker reads graff's live catalog through a short-lived ACP query
with MCP disabled, without creating a chat session. The selected model,
effort/fast state, supported levels and slash commands come from graff.
`/effort` opens the slider; `/effort high` and `/fast on` execute the harness's
normal persistent commands. Picker adjustments apply quietly, without chat messages,
conversation titles or a model turn. The picker confirms the saved state and
shows failures inline; a prompt waits for an in-flight settings save. The fast toggle appears for supported Codex models;
it is a priority-service request, not a promised speed multiplier.

## Shared review and response delivery

The toolbar's **Changes** panel refreshes every five seconds while open. It
shows staged, unstaged and untracked files, per-file diffs, recent commits and
a worktree selector. All actors editing the same working tree share that view;
uncommitted authorship is not inferred. This is local Git review, not remote
GitHub pull-request synchronization.

ACP clients can call `graff/changes` with `{ "action": "status" }` for Git
porcelain status, branch, worktrees and recent commits, or
`{ "action": "diff", "path": "relative/file", "scope": "all" }`. Scope can
also be `staged` or `unstaged`. Commands are read-only, bounded and run in the
harness workspace. The native GUI's ACP bridge uses one stdout reader and
routes replies by request ID so catalog refreshes cannot steal assistant text.

The macOS window keeps native close/minimize/full-screen controls in a reserved
draggable titlebar. For smoke runs while using another app, set
`GRAFF_SMOKE_SKIP_INPUT=1` to skip native keyboard injection; the report records
that omission.

The v2 profiler adds document LCP/FCP, maximum observed interaction duration,
recording-period layout shift, renderer heap and DOM size, GPU-process CPU/RSS
and allowlisted Chromium acceleration status. Unavailable metrics remain null.
It does not claim GPU utilization, dedicated VRAM, field INP/CLS or a Lighthouse
score. Chromium chooses its supported GPU backend; no forced driver flags or
custom Metal pipeline are needed for the current DOM-based interface.
See [repeatable performance scenarios](VISUAL-TESTS.md) for the model-free runner.
