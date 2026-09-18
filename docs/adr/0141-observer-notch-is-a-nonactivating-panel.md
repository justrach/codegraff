# 0141. The session observer is a non-activating SwiftUI edge panel

Status: accepted

## Context

ADR 0070 limited SwiftUI to the Activity sheet. Codegraff already runs several
chats at once; once the window is behind Xcode or a browser, there is no
glanceable answer to "is it still working, or waiting on me?"

[Codenotch](https://github.com/vinzdg/codenotch) solved the same glance
problem for other coding tools with a borderless `NSPanel` welded to a
screen edge: `.nonactivatingPanel`, `hidesOnDeactivate = false`,
`.statusBar` level, all Spaces. Copying that *panel contract* is the
feature. Copying its usage meters, palette, or provider stack is not.

An Electron `alwaysOnTop` `BrowserWindow` would still activate the app on
click and is a Chromium surface, not a bezel.

## Decision

The desktop hosts a right-edge SwiftUI observer through the existing
Node-API dylib (`updateNotch` / `hideNotch`). Cells show live ACP work
(tool / think / write / ask), not chat titles. Idle chats leave the
notch. Working ACP agents share the four activity slots. Usage rings
(`kind: "usage"` plus a percent) are merged in the main process; tokens
never go to Swift or the renderer. At most six cells. Hovering expands a
label; clicking focuses the main window and that chat. The panel cannot
become key or main. It is off until Settings or View → Session observer
turns it on. Smoke and hidden GUI tests pass `allow: false` so the notch
never appears on the host desktop.

SwiftUI is therefore the Activity sheet **and** this observer. The
renderer only publishes a bounded snapshot; graff still owns coding.

## Consequences

A rebuild of the native dylib is required before the notch is visible.
The preference lives in `observer-notch.json`. Visual screenshots of the
Chromium window are unchanged because the notch is a separate AppKit
panel.
