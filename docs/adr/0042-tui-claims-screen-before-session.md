# 0042. TUI claims the alt-screen before session construction

Status: accepted 2026-08-28

## Context

`GRAFF_BOOT_DEBUG=1 graff tui --yolo` on this tree is ~12ms of Zig
phases (args → credentials → MCP → prompt → root agent), then
`tui.run` writes `\x1b[?1049h`. The user stares at the leftover shell
for the whole of `main()` before that. Fat `AGENTS.md`, plugin consent,
and companion spawn (see the deferred-companion hang) make that gap
seconds on a real machine. Pi paints the pager first.

ADR 0021 keeps the welcome empty. An essay on the first frame is not
the steal — leaving the shell is.

## Decision

When the command is `tui` or `repl` (and not `--json` / `-p`),
`startup.runSubcommand` claims the alt-screen (`tty.enterRaw` +
`?1049h`/`?25l` wipe + `restore.arm` + stderr mute) before credentials.
Kitty/mouse/paste stay on `run`'s single `enable_seq` write — they are
a stack, and a second push fails PTY mode-balance. `tui.run` takes the
claim, re-asserts raw after boot, and does not re-arm over already-raw
termios. If we never
reach `run`, `restore.releaseIfOwned` on the shutdown stamps plus the
panic hook / fatal signals restore the shell. No libc `atexit` — Zig
exits via syscall and would skip it.

Welcome stays empty. Off a TTY the claim is a no-op.

## Consequences

Boot diagnostics during `graff tui` land in `.graff/tui-stderr.log`
(`muteStderr` at claim time), not on the leftover shell. A crash
between claim and `run` must hit `restore.emergency` or the shell is
stranded — same contract as a crash inside `run`.
