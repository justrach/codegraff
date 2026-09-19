# 0142. Zigzag is not a frontend

Status: accepted 2026-09-19

## Context

`graff repl` started as a zigzag TUI spike (`spike/zigzag-repl`). The Grok-style
pager in `TUI/` replaced that surface: TTY `graff repl` is `tui_launch`, the
same as `graff tui`. Bare `graff` stays the line REPL. The desktop app is the
graphical client. Vendoring zigzag kept a second fullscreen toolkit in the
release binary for a path no TTY user hits.

Piped `printf … | graff repl` still needs the scripted Model for CI. That Model
only needed ANSI paint, a rounded box, and a line buffer — not zigzag's
Program/TextInput/mouse loop.

## Decision

Do not vendor zigzag. Scripted `graff repl` styles with `src/repl_style.zig`.
TTY fullscreen UI is `TUI/` only. Drop the standalone `graff-repl` exe.

## Consequences

`zig build repl` / `zig build repl-test` are gone; Model tests run under
`zig build test`. Historical release notes may still mention zigzag.
