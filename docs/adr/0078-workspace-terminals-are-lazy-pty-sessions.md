# 0078. Workspace terminals are lazy PTY sessions

Status: accepted 2026-09-06

## Context

Desktop users need an interactive shell beside their conversation, including
interrupts, terminal resizing and a session that survives hiding the panel.
A command runner without a PTY cannot provide those behaviors.

## Decision

The macOS desktop starts a small native PTY helper only when the terminal is
opened. The main process owns one shell per canonical workspace, up to four.
The renderer uses xterm with bounded scrollback. A bounded output ring preserves
recent output across workspace switches; acknowledgements apply backpressure
while a renderer is attached. Hiding a panel preserves its shell. Explicitly
ending the session, reloading the desktop, or quitting closes its PTY.

Terminal IPC is restricted to the trusted application renderer. Embedded browser
pages receive no terminal bridge. Shell input and output remain outside feedback
reports and do not become conversation messages.

## Consequences

The terminal remains useful without a model session. The helper is built and
signed with the desktop bundle. Other operating systems need their own PTY
backend before this desktop terminal is available there.
