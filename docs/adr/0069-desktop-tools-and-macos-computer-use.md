# 0069. Desktop tools use the app's browser and a native macOS bridge

Status: accepted for the local desktop trial

## Decision

The Electron desktop contributes a Bun stdio MCP server to graff's generated
runtime configuration. It offers `browser` and `computer`; graff retains the
model loop, tool orchestration, and existing MCP consent policy. Disabling MCP
for a workspace disables these tools too. User configuration files are not
rewritten. The endpoint and launch token are inherited by the ACP process,
not exposed to browser pages. Images remain MCP image content blocks.

Browser actions target the embedded Chromium view. Agent-opened pages reveal
their matching chat's browser pane. Kuri startup and the legacy browser API
are disabled inside this desktop host; the older web/AppKit host remains
separate. Find and zoom are available in the browser toolbar.

macOS control uses public Accessibility and Core Graphics APIs through a
small Swift/Node-API bridge inside the application. This is independent of
the signed external Codex plugin adapter in ADR 0036, which is unchanged.
Computer use starts disabled each launch. Only the app's native menu can
enable it or request OS permissions; agent tools can report permission status
but cannot grant access. The menu can disable it without restarting graff.

Snapshots are bounded and assign expiring element references. Input actions
require an explicit frontmost target PID; coordinate actions verify the app
under the point. Secure fields require user interaction. App and page text
are untrusted data. Screenshots are on demand, with display/image geometry
for coordinate scaling. There is no recording loop or persistent capture
worker. Native Accessibility references are bounded to the latest snapshot.

## Validation and limitations

Packaging compiles the bridge against the macOS SDK. Tests cover MCP discovery,
chat routing, image content, rejected actions, browser interaction, legacy
browser rejection, and native app discovery. Full input/capture verification
requires the user to grant macOS Accessibility and Screen Recording permissions.
Locally signed rebuilds can require renewed OS permission approval. Other
operating systems and distribution signing remain outside this trial.
