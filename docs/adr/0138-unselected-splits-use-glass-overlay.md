# 0138. Unselected split panes recede with a wash, not a hole

Status: accepted

## Context

Split chats are React in Electron. Unselected panes looked identical to the
focused one except for an accent border. Punching CSS holes onto a window-backed
`NSGlassEffectView` sampled the desktop and hid the other transcript.

## Decision

Keep unselected pane content opaque and readable. A light `::after` wash recedes
them; the focused pane stays `bg-page` with the accent border. Empty Enter while
a turn runs arms a 3s force-steer; a second Enter steers. Send is a circle.
Updates in the toolbar matches Tools/More, not a filled CTA. ⌘B toggles the
sidebar.

## Consequences

This is a CSS overlay, not a SwiftUI chat rewrite. `NSGlassEffectView` remains
available on the native bridge for later, but it is not the split-pane material.
Non-macOS and Reduce Transparency keep the same wash.
