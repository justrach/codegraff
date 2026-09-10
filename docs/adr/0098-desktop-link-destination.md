# 0098. Desktop web links share one destination policy

Status: accepted 2026-09-10

## Context

Conversation links always opened in the system browser, even when users
wanted to keep pages beside their chat (#824). The desktop server's origin
can change between launches, so origin-scoped browser storage alone cannot
reliably preserve this preference.

## Decision

Store the explicit `system` or `graff` choice atomically in desktop user data.
Default missing or invalid preferences to the existing system-browser behavior.
Expose the setting through trusted app-frame IPC, not to browser pages.

Use Electron's shared navigation interception for both normal links and
new-window links rather than adding handlers to individual Markdown renderers.
Validate HTTP(S) URLs and reject credentials before routing either destination.
Same-origin app navigation stays in the app; same-origin popups are denied.

For Graff, send the validated link to the renderer, which resolves the focused
chat and reveals its existing isolated Browser pane. Never replace the main
application view or fall back to the system browser when Graff navigation fails.

## Consequences

The preference survives origin changes and restarts. All conversation renderers
use the same routing policy without coupling Markdown to Electron. The renderer
still owns chat focus and pane layout; Electron owns URL safety and OS opening.
Persistence, routing edge cases, and real Electron interactions are covered by
the desktop tests and `test:links`, also included in `test:projects`.
