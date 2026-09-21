# 0157. Linux desktop releases ship the unsigned deb

Status: accepted 2026-09-21

## Context

The tag workflow publishes CLI tarballs from Linux. The desktop download is a
separate step: `publish-updates.sh` attaches a notarized macOS DMG and update
zip, and refuses anything that fails Gatekeeper. Linux packaging already
writes a `.deb` (and an AppImage when `appimagetool` is installed) from
`apps/native/electron/build.sh`. Package signing is still open, and there is
no notarization gate to satisfy on Linux.

## Decision

- A tag release also uploads `Codegraff-linux-<arch>.deb` and
  `Codegraff-linux-<arch>-SHA256SUMS`. An AppImage produced by the same
  packager is uploaded beside them as `Codegraff-linux-<arch>.AppImage`.
- The bytes are the unsigned package `build.sh` writes. Do not skip the
  upload because it is unsigned, and do not publish a `GRAFF_DEV=1` bundle.
- macOS stays on `publish-updates.sh`. An unsigned macOS build is still not
  a release asset.

## Consequences

Linux users can install the desktop from the GitHub release. The package is
not signed. When signing exists, replace these assets with the signed bytes
under the same names; do not add a second upload path.
