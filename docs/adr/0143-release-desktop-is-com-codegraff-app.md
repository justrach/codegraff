# 0143. Packaged Codegraff.app is com.codegraff.app

Status: accepted 2026-09-20

## Context

`apps/native/electron/build.sh` stamped the Electron trial identifier
`dev.codegraff.electron.local` onto every non-`GRAFF_DEV` build. That ID
shipped in `/Applications/Codegraff.app`. macOS TCC and the single-instance
lock then treated a production install as a development bundle. ADR 0132
says the release identifier must stay stable; the leaked `dev.*` value was
not that identifier.

## Decision

A packaged, notarized `Codegraff.app` uses `CFBundleIdentifier`
`com.codegraff.app`. `GRAFF_DEV=1` remains `dev.codegraff.app` with a
separate Electron user-data directory. `distribute.sh` and
`publish-updates.sh` refuse any other identifier. Unit tests fail if
`build.sh` defaults to a `dev.*` id or still contains `electron.local`.

## Consequences

The next signed build is a new macOS identity: TCC grants from
`dev.codegraff.electron.local` do not carry over. Old and new copies can
run side by side until the previous app is replaced. Release signing is
Developer ID + notarization; this identity change does not add a
provisioning-profile step.
