# 0209. The desktop app has no computer use

Status: accepted 2026-09-28. Supersedes the `computer` half of ADR 0071.

## Context

ADR 0071 gave the desktop MCP server two tools: `browser` for the embedded
Chromium pane and `computer`, a user-enabled bridge that let the agent list
macOS apps, read their Accessibility trees, click, type and capture screens.
In practice the agent reached for `computer` to show a local build, then turned
a missing permission into a setup task for the user (#1334). Showing a build is
the project's job: its own launch, preview or render command, or the browser
pane for a localhost page.

## Decision

The desktop app no longer offers computer use. The `computer` tool, its
`/computer` automation endpoint, the **Computer use…** menu item and its
consent dialog are removed. The desktop MCP server offers `create_html`,
`profiler` and `browser`.

The native Accessibility/CGEvent bridge stays in the Activity module as a
test-only driver (`native-input.cjs`): the GUI suites use it to send real OS
clicks and keystrokes to Codegraff's own window. Nothing in the app or the MCP
server can reach it, and it never requests permissions.

graff's bridge for the Codex Computer Use plugin (ADR 0036, 0119) is separate
and unchanged. (Since removed: ADR 0313.)

## Consequences

The agent cannot drive other macOS apps from the desktop app. GUI tests keep
native input coverage.
