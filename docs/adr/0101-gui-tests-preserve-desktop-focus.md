# 0101. GUI tests preserve desktop focus and report native coverage gaps

Status: accepted 2026-09-11

## Context

#832 persisted after adding a window helper: individual visual suites still
called `show()`/`focus()`, a browser fixture implicitly displayed its host,
and packaged smoke tests could present native UI or inject OS input.
A hidden-window helper test could pass while those entry points took focus.

## Decision

Automated Electron entry points install a process policy before readiness.
Default windows are hidden and non-focusable; both hidden and visible-inactive
modes use macOS [prohibited activation policy](https://www.electronjs.org/docs/latest/api/app#appsetactivationpolicypolicy-macos). Unexpected show/focus/fullscreen calls fail
instead of silently activating a test window. Constructor overrides cannot
turn presentation on. Packaged smoke tests use the same policy, including
reopen events. Normal interactive app launches retain their usual behavior.

`GRAFF_ELECTRON_VISIBLE=1` allows visible, non-focusable windows without app
activation, and enables embedded-browser pin input and captures. It can still
overlap the current application: no activation does not mean no obstruction.
Only the default hidden mode keeps test windows off the desktop.
`GRAFF_ELECTRON_FOREGROUND=1` explicitly permits activation. Native fullscreen,
Activity sheets, and OS input checks still need that foreground opt-in.
Skipped checks are printed and visual runs record them in `test-run.json`; they must not be described as passed.

CI runs a separate native job on a hosted macOS graphical session. That job
explicitly enables foreground mode and requires real window focus, production
Activity sheet presentation and default-button dismissal, plus fullscreen and
reload coverage from the visual suite. A missing graphical session or skipped
fullscreen check fails CI. The normal local command remains hidden.

Accessibility and Screen Recording permission are checked without requesting
consent. OS input and display capture run when permitted; otherwise the native
report and CI summary list them as skipped. A preconfigured runner can set
`GRAFF_NATIVE_REQUIRE_OS_INPUT=1` to make those permissions mandatory. An ordinary
hosted-runner pass does not establish OS input coverage when permission is absent.

## Consequences

The hidden renderer can exercise composer input, Tab traversal, split resizing,
link routing and screenshots. Embedded WebContentsView pin input did not pass
while hidden, including a page-targeted DevTools input experiment. Showing the
host inactive allows those checks to pass without activation. Accessory policy
was insufficient: embedded-page focus activated the app despite non-focusable
windows. Prohibited activation policy preserved both visibility and the active
application in an OS-observed browser run. Hidden tests do not establish native
presentation or real desktop input correctness.

`test:focus` observes actual macOS app activation and visible windows around the
runner. `test-window-probe.cjs` covers repeated windows, reopen events, input,
capture and cleanup. The observer reports other-app switches without causing
them; zero observed switches does not verify a manual app-switch scenario.
The native observer currently verifies macOS only.
