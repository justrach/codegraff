# 0356. Compound Simulator tests check pasteboard sync

## Context

The shell preflight guards Simulator pasteboard writes when the Simulator
app is open with automatic synchronization enabled. A command can pass that
check with the app closed, then open it and execute pasteboard-changing tests
within the same shell call.

## Decision

For recognized pasteboard-changing shell commands with an explicit
`open` of Simulator, check the synchronization preference even if Simulator
is currently closed. An unset preference is treated as on. Keep the ordinary
headless test path when the app is closed and the command does not open it.
The guard never changes the preference or reads or restores clipboard data.

## Consequences

The guard covers explicit Launch Services opens in the same shell
command. It cannot inspect the behavior of arbitrary scripts and binaries
or prevent a separate process from opening Simulator after preflight.
The test fixture exercises the Bash tool boundary without opening a window
or touching a real clipboard.
