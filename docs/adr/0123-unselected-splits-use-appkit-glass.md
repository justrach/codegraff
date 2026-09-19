# 0123. Unselected split panes use AppKit glass, not SwiftUI chat

Status: accepted

## Context

Split chats are React in Electron. macOS 26 Liquid Glass lives in AppKit
(`NSGlassEffectView`) and SwiftUI (`glassEffect`). ADR 0070 limits SwiftUI to
the Activity sheet. CSS `backdrop-filter` can fake frost inside Chromium but
is not the system material, and Chromium's out-of-process compositor usually
will not feed AppKit a within-window backdrop.

## Decision

Install one window-backed glass view behind the web contents through the
existing Node-API bridge: `NSGlassEffectView` on macOS 26+, `NSVisualEffectView`
(`.underWindowBackground`) otherwise. Unselected split panes reveal the native material through a 90%-opaque
page-colored canvas, keeping the effect subtle over bright desktops. The focused
pane, sidebar and toolbar stay opaque. CSS fallback blur applies behind the pane,
never through an overlay above transcript text. SwiftUI remains the Activity sheet and the session observer (ADR 0126).
Production macOS windows are transparent so the material can sample the
desktop; test/smoke windows stay opaque so screenshots do not.

## Consequences

Native glass is a window material, not per-pane overlay geometry synced to
split drags. Reduce Transparency skips install and uses an opaque CSS surface.
Non-macOS stays on CSS. A rebuild of the Electron native dylib is required
before the material is visible.
