# 0131. MCP HTTP shares task execution and installs additive client entries

## Decision

Offer `graff mcp serve --http` as a loopback-only Streamable HTTP adapter to
the same bounded task executor as stdio. Require a bearer token, validate Host
and Origin, cap request bodies, and keep each client's initialization state
separate. A bounded handshake table returns 404 for retired sessions. Task
execution remains serial; HTTP does not create shared model conversation state.

`graff mcp install` owns service setup and client registration for both the
shell installer and packaged GUI. Use launchd or user systemd, private token
and service files, and readiness verification before changing client configs.
Register detected HTTP-capable clients additively. A private ownership receipt
allows unchanged generated entries to refresh on upgrades; preserve user-edited
entries, unknown settings, comments in TOML, and malformed files. Serialize
installer runs with a local lock. An environment opt-out skips automatic setup.

The install default is the user's home workspace and approval-gated execution.
Explicit project/port choices persist across repeated installs. A service
restart can interrupt active work; installation is not a live-task migration.

## Consequences

Multiple clients share one listener with the same embedded app and task
contract. Installation needs Python and an available user service manager.
Unsupported clients keep the manual stdio path. Installer tests operate only
on temporary configurations and mock the service manager; transport tests use
an isolated loopback listener and scripted model.

GUI launches refresh the managed bundled-engine launcher and shell PATH.
MCP setup runs once per app version, so newer GUI downloads refresh the service
and client registration. Existing unmanaged launcher files are preserved.
