# 0101. GUI tests preserve desktop focus by default

Status: accepted 2026-09-10

## Context

Independent GUI suites created visible windows and repeatedly called native
show/focus methods, including while restoring fixture windows during cleanup.
Making one suite hidden did not protect other suites or launch-time activation
(#832). Native input injection also coupled tests to the user's focused app.

## Decision

All Electron test windows use one test-only policy. Background is the default:
windows start hidden and unfocusable, macOS application activation is prohibited,
and later native show/focus operations fail before executing. Cleanup destroys
every test window, including windows left by nested suites or failed steps.

Page-level tests send trusted Chromium protocol input and emulate page focus.
This keeps pointer routing and real Tab navigation testable without activating
the operating-system window. Background fixtures disable renderer throttling.

Only `GRAFF_TEST_FOREGROUND=1` opts into visible windows and native interaction.
Fullscreen, native computer input and native sheets require that opt-in. Reports
identify omitted native checks and benchmark window mode; background frame
timing must not be presented as foreground display timing.

The visual and benchmark launchers start a read-only macOS focus/window observer
before Electron. Activation or visible test windows fail the run. User switching
between other apps is allowed. A standalone background regression exercises
repeated windows, trusted input, screenshots, rejected activation and cleanup.
Unit and source-policy tests keep new fixtures from bypassing the shared helpers.

## Consequences

Ordinary GUI verification can run while the user works elsewhere. Foreground
native checks remain separately opt-in. The OS observer requires the macOS
command-line developer tools; other platforms use native-window assertions.
Production application window behavior is unchanged; packaged smoke mode alone
uses the test policy.
