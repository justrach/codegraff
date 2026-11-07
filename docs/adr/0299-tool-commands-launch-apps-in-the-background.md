# 0299. Tool commands launch apps in the background

Status: accepted 2026-10-22

## Context

ADR 0101 kept the in-repo desktop app's automated tests off the user's
desktop. That app and its tests have since left this repository; GUI
verification now happens through the agent's own shell commands. On macOS a
command that runs `open` (a URL, a built app, `open -a Simulator`) brings the
app to the front and takes keyboard focus from whatever the user is doing,
and each later verification step takes it again (#832).

## Decision

On macOS, tool children (`tool_env.zig`) get a directory first on `PATH`
whose `open` passes `-g` to `/usr/bin/open`: Launch Services starts the app or
opens the document without bringing it to the front. graff writes that shim
at startup under `~/.codegraff/shims/background-gui/` (`gui_background.zig`).

Foreground is an explicit opt-in. `GRAFF_GUI_FOREGROUND=1` on one command lets
that command activate the app; in graff's own environment it leaves the shim
off for the whole session.

## Consequences

Apps the agent opens appear behind the active app; windows can still overlap
it. The shim does not cover an app that activates itself once running,
`osascript` `activate`, `/usr/bin/open` by its full path, or synthesized input
posted to the HID event tap, which moves the user's own pointer whatever app
is in front. Those still need the user's consent before they run. Other
platforms are unchanged.
