# A separate identity for the development desktop

Status: accepted

## Context

A local rebuild previously used the installed desktop's bundle identity and
Electron profile. Its single-instance lock focused the installed app instead
of opening a development desktop, preventing side-by-side testing.

## Decision

`GRAFF_DEV=1 bash apps/native/electron/build.sh` produces
`zig-out/electron-dev/Codegraff Dev.app`, bundle ID `dev.codegraff.app`.
A bundled development marker selects the name `Codegraff Dev` and a separate
Electron user-data directory before acquiring the single-instance lock.
`scripts/build_and_run.sh` builds and launches this variant by default and only
stops this checkout's previous dev process. The release build remains unchanged.

Development startup does not automatically configure external MCP clients, and
its menus cannot replace the installed terminal launcher or MCP service. It has
no release update configuration. Browser profiles and desktop settings are
separate; harness credentials and repository session data are still shared.

## Consequences

Both desktops can run concurrently without sharing an Electron profile. macOS
may require separate permissions for the dev bundle. This intentionally retains
the production single-instance protection rather than disabling its lock.
