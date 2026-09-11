# 0097. An explicit `timeout` shortens root bash's foreground wait, never extends it

Status: accepted 2026-09-11

## Context

ADR 0026 promotes a still-running root foreground `bash` onto the job registry
after 120s (grok-build's number). `timeout` ms was documented as replacing that
wait — "waits up to 120s (or `timeout` ms, capped at 10h)".

[#850](https://github.com/justrach/codegraff/issues/850) is that clause used the
other way round. `rootWaitMs` returned `min(timeout, wait_cap_ms)`, so a model
that read `timeout` as a *command deadline* — the natural reading, since every
other `timeout` in the catalog kills — asked for an hour of foreground blocking
and got it. `waitForeground` cannot return `.running` before its deadline, so
the turn sat in the `· bash still running ·` pulse for the whole hour: exactly
the failure mode [#620](https://github.com/justrach/codegraff/issues/620) closed
(the model blocked 83 minutes, todos stuck at `0/5`), reachable again through a
parameter instead of through a missing deadline.

The schema invited it: "Optional foreground wait in milliseconds before
auto-background (default 120000, max 36000000)", alongside a tool line reading
"after 120s (or timeout ms)".

## Decision

- An explicit `timeout` may only make the foreground wait **shorter**. A larger
  value is clamped to the effective default: 120s interactive, 15s on lean `-p`
  (ADR 0055).
- The default still promotes at 120s / 15s and never kills (ADR 0026).
- `timeout` is therefore not a command lifetime. A command that genuinely has
  to be waited on either runs with `run_in_background: true` or is waited for
  with `bash_output(id, wait_ms>0)`, which blocks until exit (10h cap, ADR 0010).
- The tool descriptions state the clamp and that alternative, which means the
  generated SDKs change with them.

## Consequences

No `timeout` value can park a root turn in the pulse. The cost is one extra hop
for a command the model expected to watch for minutes: at the bound it gets a
job id plus partial output instead of the finished output, then either the exit
notification or one `bash_output(wait_ms>0)`.

Regression coverage in `src/exec_bash.zig`: a huge explicit timeout clamps to
the bound (and to 15s on lean), and the promotion path leaves the child alive
and reachable through `bash_output` / `bash_kill`.
