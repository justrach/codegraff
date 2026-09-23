# 0156. Linux desktop uses system chrome and a sandbox fallback

Status: accepted 2026-09-21

## Context

The packaged desktop copied `Electron.app`, called
`setWindowButtonVisibility`, and compiled only the Darwin PTY helper. That
path cannot start on Linux. Chromium's sandbox also aborts when
`chrome-sandbox` is not setuid and user namespaces are blocked, which is the
usual case for an unpacked tree before a deb install.

## Decision

- Linux packages are an unpacked directory, a `.deb`, and an AppImage when
  `appimagetool` is on `PATH`. The macOS `.app` build is unchanged.
- The window uses system decorations. The inset titlebar and traffic lights
  stay on Darwin.
- `codegraff` execs `codegraff.bin` with the setuid helper when `chrome-sandbox` is mode 4755. Otherwise it uses a user namespace (`--disable-setuid-sandbox`) when `unshare --user` works, and `--no-sandbox` when it does not. The deb `postinst` sets the helper setuid.
- The workspace terminal is the POSIX PTY helper and `$SHELL`. macOS-only
  activity, glass, and computer use stay unloaded.

## Consequences

An unpacked Linux build opens without a root step. A deb install can turn
the sandbox helper setuid. The tag workflow uploads that unsigned `.deb`
(ADR 0157). Signing remains a later replacement of the same asset, not a
reason to skip the upload.
