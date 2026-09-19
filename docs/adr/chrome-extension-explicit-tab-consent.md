# Explicit tab consent and native messaging

Status: experimental implementation; real Chrome acceptance pending.

The existing desktop browser pane uses a separate managed browser. Access to a
user's already signed-in Chrome profile needs a different, visible consent boundary.
This package uses a toolbar-selected tab, a fixed debugger command allowlist,
Chrome native messaging, and Graff's existing stdio MCP integration.

Native messaging avoids a web-accessible localhost control endpoint and its
cross-origin authentication surface. A private Unix socket allows Graff's MCP
process to talk to the host Chrome starts. It trusts processes under the same OS
account and supports one connected profile. It does not expose remote control.

Disconnecting on every navigation is intentionally less convenient than keeping
an origin allowlist: a previous page's consent never silently covers a new page.
The debugger permission is broader than the implemented tools, so executable
allowlist and revocation tests are the boundary, not the manifest warning alone.

Rejected for this prototype: all-tabs auto-attachment, a raw CDP/evaluate tool,
a public or unauthenticated localhost WebSocket, and changes to the existing
browser-pane implementation. This keeps the prototype removable and avoids
coupling it to ongoing desktop work. Promote this decision into docs/adr when
real-browser acceptance establishes a shipping integration.
