# 0063. A cancel with no recorded source is the harness's, not the user's

Status: accepted 2026-09-03

## Context

`Agent.esc_cancel` is one process-wide flag with six setters — a lone Esc
on the line REPL's raw stdin, a double-Enter force steer, a `--json`
`cancel` line, an ACP `session/cancel`, the fullscreen TUI's cancel — and
the turn-ending marker always read `[response interrupted by user]`. #728
reports that marker twice on responses the user never interrupted, with no
Esc, cancel, or stall event anywhere in the trace. Whatever flipped the flag
(the report correlates it with a background-job exit notice), the label was
wrong in two ways: it blamed the user, and it left no trace of the real
source, so the next occurrence could not be attributed either.

## Decision

* Every setter goes through `cancel_source.cancel(source)`, which records
  who raised the flag. A fresh turn clears both together.
* Mainloop's `error.Interrupted` branch consumes the source. With a user
  source the transcript keeps `[response interrupted by user]`; with none it
  writes `[response ended early: cancelled by the harness, not the user]`,
  the chrome line and the `--json` error say the same, and the trace carries
  `interrupted source=<name>` either way.
* The raw stdin scanner swallows an OSC sequence (a terminal's colour or
  title *reply*) through its terminator instead of reading its leading ESC
  as a keypress — one of the few ways the flag can rise without a hand on
  the keyboard.
* A job exit the model already read no longer queues a wake (ADR 0061),
  which removes the injected notice the report describes.

## Consequences

* A false interrupt is now labelled honestly and named in the trace; the
  root cause of #728, if it recurs, is one trace line away instead of a
  guess. The user-facing behaviour of a real Esc is unchanged.
