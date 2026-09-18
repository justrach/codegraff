# Graff Browser Connect — experimental native-messaging variant

Requires Google Chrome, Node 22+, macOS or Linux. No dependencies or build step.
This variant is isolated from the separate `apps/chrome-extension` sidecar.

1. In Chrome open `chrome://extensions`, enable Developer mode, choose Load
   unpacked, and select **apps/chrome-native-extension** from this checkout.
2. Copy its extension ID and run `node install.mjs EXTENSION_ID` in this folder.
   This writes a user-level native-messaging host restricted to that extension ID.
3. Add the printed MCP entry to Graff's existing MCP settings without replacing
   other servers. Keep the checkout at this location; the host references it.
4. Click the extension on a disposable HTTP(S) tab. The ON badge and Chrome
   debugging banner indicate connection. Use chrome_tabs, chrome_snapshot,
   chrome_screenshot, chrome_click, chrome_type, and chrome_scroll from Graff.

Only toolbar-connected tabs are exposed. Clicking again, navigation, tab close,
Chrome debugger detach, or loss of the native connection revokes access.
Navigation requires reconnecting, even on the same origin. No consent is saved.

The debugger permission is powerful; the implementation restricts it to selected
HTTP(S) tabs and fixed commands. No arbitrary evaluation or raw CDP tool is
exposed. The transport uses native messaging and a private Unix socket (directory
0700/socket 0600), not a web listener. Other processes under your OS account are
trusted. Page data passed to Graff can reach its configured model; avoid sensitive
pages. Page content is untrusted data, never instructions. A connected tab does
not authorize purchases, sending messages, deletions, or other consequential
operations; the harness still needs user authorization for those actions.

Only one connected Chrome profile is supported. An existing socket is never
replaced automatically. Normal shutdown cleans it up. After a hard crash, remove
`~/.graff/chrome/bridge.sock` only after confirming the native host is stopped.

Run `npm run check && npm test`. Tests exercise real MCP stdio and native/socket
transport plus mocked Chrome consent and revocation. Actual Chrome attachment
and interaction still require manual end-to-end acceptance before shipping.

To uninstall, remove the Chrome extension and Graff MCP entry, disconnect Chrome,
and remove the `dev.codegraff.chrome.json` user NativeMessagingHosts manifest and
`~/.graff/chrome` directory.
