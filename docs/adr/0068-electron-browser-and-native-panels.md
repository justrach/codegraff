# 0068. Electron renders browser pages; graff owns coding

Status: accepted 2026-09-06 for the local desktop trial

## Context

The desktop interface already uses React and ACP. Its browser pane ran a
separate Chrome through Kuri and displayed repeated JPEG screenshots inside
WebKit. That duplicated rendering engines and required forwarding input.

## Decision

The local Run entrypoint builds an Electron application. The existing React
interface and Bun-hosted production routes remain; coding and tool execution
remain in `graff acp`, over the existing JSON-RPC transport. No agent loop moves
into Electron. Release packaging for the earlier shell remains available.

Browser pages render directly in sandboxed, isolated `WebContentsView`s using
a separate persistent session from the application. There is no browser
prewarm and no screenshot polling. Empty chats do not start coding agents.
Closed views are destroyed. Hidden views release their renderers after one
minute and retain their URL; rapid switching retains at most three live views.
Reopening a suspended page reloads it, so unsaved page forms are not preserved.

The renderer's IPC surface permits browser navigation, geometry, picking,
and Activity only. External pages never receive that surface or the desktop
API token. Graff can act on a pinned page through an authenticated loopback
endpoint; page content remains untrusted. Browser snapshots are on demand.

SwiftUI is limited to a native Activity sheet hosted through a small Node-API
bridge. Standard SwiftUI controls and availability-gated macOS Liquid Glass
provide the native surface. The sheet samples on opening, not on an idle timer.

## Consequences

Electron owns Chromium distribution and process integration. Bun remains the
build tool and route-server runtime; Electron itself uses its bundled Node.
The app needs Chromium updates and a macOS native build step. Memory and CPU
claims require measurements with matching pages, tools, and active work; RSS
sums include shared pages. A browser engine change alone is not a memory bound.

Validation covers direct navigation, isolated page code, rejected unauthenticated
requests, pins, browser automation, suspend/reopen/close, real ACP initialization,
and native sheet loading. No provider calls are required for these checks.
