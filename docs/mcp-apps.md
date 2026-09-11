# MCP Apps in Codegraff

Call a connected MCP tool that declares an MCP Apps UI. In the native GUI, its tool result includes an **Interactive MCP result** view. Close/reopen controls dispose and restore the view. Text and image output stays available in the transcript.

In the REPL, run **`/mcp apps`** after the tool completes to open its latest saved view in the default browser. The link in the tool result also identifies the standalone HTML file. This works with the existing MCP server configuration and consent process; it does not install or authorize additional servers.

Views can display results, scroll, resize, and offer source links. Clicking a source exposes an **Open source** link in trusted host chrome for a user click. Image-copy features depend on browser permissions; the isolated view may need the app's copy-link or manual-selection fallback. This version does not run app-initiated tool calls or inject messages into the agent conversation; those requests fail explicitly.

Snapshots are stored in the user's `.graff/mcp-apps` directory with private file permissions and opaque ids. They include the tool result and its view metadata, remain available across transcript reloads, and can be deleted when no longer needed. The REPL shortcut tracks the latest view in its current session; old snapshots remain openable by their saved links.

## Development and regression checks

Build the engine and run its offline integration fixtures:

```sh
zig build
zig build test --summary all
python3 scripts/test-mcp-apps.py
```

The Python fixtures start local MCP and scripted-model servers. They verify text and base64 resources, saved results, exclusion of private UI metadata from model requests, private snapshot permissions, and invalid-resource fallback. The scripted model uses its established local test port; no provider API is called.

Run simulated apps in Chrome against the actual native GUI component and API route:

```sh
cd apps/native
bun install
bun run test:mcp-apps
```

The browser tests start an isolated Next development server and clean up only their own snapshots. They exercise handshake/result delivery, close/reopen, source and unsafe links, blocked app tool calls, cross-frame access, CSP network blocking, and standalone REPL snapshots. Store tests cover path traversal, symlinks, and oversized files. The visual fixture route is available only when `GRAFF_VISUAL_TESTS=1`.

For GUI development, run the native app with the rebuilt engine. Packaged desktop copies embed their own engine and frontend and need a new package before these changes appear there.

See [the architecture decision](adr/0103-mcp-apps-are-isolated-result-views.md) for the isolation and capability boundary.
