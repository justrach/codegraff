# 0314. nanocua is graff's computer use on macOS

Status: accepted 2026-11-04. Replaces the "no computer use" half of [0313](0313-graff-does-not-load-codex-computer-use.md).

## Context

ADR 0313 removed the last computer-use path, which depended on another
product's install layout and private service. Agents still sometimes need
another app's real UI. Two forces shape how graff provides it. macOS grants
Accessibility and Screen Recording to the app responsible for a process, so a
library inside `graff` would hand both to whichever terminal started it, and to
everything else running in that terminal. And ADR 0209 removed the desktop app's
`computer` tool because agents reached for it to show a local build, then turned
a missing permission into a setup task for the user.

## Decision

Computer use is nanocua: `apps/nanocua`, a signed macOS app with its own
permissions, a control panel and a kill switch. graff links none of it. Release
builds put `nanocua.app` beside `graff` in the macOS tarballs; `install.sh` and
`graff update` place it in `~/Applications`. When the app is there, graff adds
one MCP server, `nanocua mcp`, below every config file, so a server the user
named `nanocua` wins and `graff mcp disable nanocua` works.

That entry skips the startup consent gate, because it runs what graff shipped
and starting it does nothing: `nanocua mcp` answers handshakes and the tool list
itself, and only the first `tools/call` opens the app. What it may do is the
app's decision, not graff's or the agent's:

- input is off until the user turns it on in the panel, each launch;
- by default a call works inside one app in the background, with the user's
  pointer and keyboard untouched, and screenshots capture that app's window;
- the real pointer and keyboard and pictures of the whole display need a second
  switch; Stop refuses everything; agents cannot reach nanocua's own window.

Its instructions tell agents to prefer the project's own commands for showing
their work and not to chase permissions, which is ADR 0209's failure.

codegraff holds the original. nanoui's `apps/nanocua` is generated from it by
`scripts/vendor-nanocua.sh` and stays under codegraff's license, not nanoui's
MIT. nanoui does not import it, so nanoui itself stays MIT. Linking the other way
is fine: `apps/nanocua` depends on nanoui, pinned, like any MIT library.

## Who changes the switches

`nanocua ctl` is the one way in from outside the panel. `graff computer` and
`/computer` run it, and Harness runs it directly, because an older graff would
take `graff computer` for a prompt. Status, stop and turning things off happen at
once, for anyone on the user's socket. Turning something on (input, whole screen,
resume) only asks: a question appears in nanocua's window, and only a person's
click on Allow there answers it.

That split exists because Harness runs graff with `--yolo` and agents have shells:
a command that turned input on would let an agent turn on its own input, so the
switches would protect against nothing. Allow arms after 0.7s, so a click meant
for what was under the pointer can't answer it. A question goes away after 60s,
and a Deny refuses new ones for 15s. nanocua checks that a click came from
hardware, not a program, and only for turning things on: Stop works however it's
clicked. Switch Control and Voice Control post their own clicks, so they can't
turn things on. nanoui's `--nanoui-*` flags are refused outside debug builds,
since they drive the same window.

A process running as the user can still attack this in ways nanocua can't see,
such as editing what the app loads. The check closes the easy route, not every one.
macOS's own permissions stay in System Settings; nothing here can flip them.

## Consequences

- The desktop app runs `graff acp`, so it offers nanocua too once the app is in
  `~/Applications`, as every engine feature reaches every surface. ADR 0209's
  `computer` tool stays gone; this differs in living outside the desktop app,
  behind nanocua's own switches.
- Other platforms get nothing yet: the server is macOS-only, and the app there
  answers that each tool is unsupported.
- A release built without the signing secrets has no app, so that install has no
  computer use. An ad hoc app would lose its permissions on every update.
- Background input is delivered per process. Apps may ignore it, Chromium's web
  content most likely; agents fall back to refs or ask for the whole screen.
- Agents share one app, calls one at a time, but each connection has its own refs
  and target. Harness's graff chats and a terminal graff use the same app.
- Beta releases are not signed, so they carry no app.
