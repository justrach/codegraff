# 0045. Session-end `learn init` is detached

Status: accepted 2026-08-30

## Context

After five API calls, `learn_auto` claims a one-shot bootstrap and
`autoInitLearning` used to run `learn_init.zeroConfig` **in process**.
Pinning the binary is cheap once it is a hardlink (ADR 0044). Suite
generation is not: a live `graff learn init` in `/tmp/graff-pin-proof`
took **37.7s**, almost all CPU on generating the kit, not the copy.
That tax sat on `-p`, piped `graff repl`, and TUI teardown alike — the
surfaces now share one learn-auto path, so a sync init would show up
on every one of them.

A background trial already uses `std.process.spawn` in its own process
group (`learn_auto.maybeStart`). Init was the remaining foreground wait.

## Decision

`autoInitLearning` starts `graff learn init` detached (`initArgv` +
`startInit` in `learn_auto.zig`), same process-group isolation as a
trial. Session end does not wait. The next session that finds a store
starts the trial cadence. Logs go to `.graff/learn-auto-init.log`.
Do not skip bootstrap on `-p` to hide the wait (that split is retracted).

## Consequences

- First-session teardown is milliseconds plus a spawn, not ~38s of
  suite generation. `-p` and the REPL stay on one path.
- The session that triggered bootstrap does not count toward a trial;
  the store may not exist yet when it exits.
- A machine that cannot spawn simply does not learn; the exclusive
  marker still prevents retry-forever.
- `graff learn init` typed at a prompt stays synchronous — only the
  automatic session-end path is detached.
