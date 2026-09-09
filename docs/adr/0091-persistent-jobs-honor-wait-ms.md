# 0091. Persistent bash jobs honor wait_ms as a timeout

Status: accepted 2026-09-08

## Context

ADR 0010 maps every positive `bash_output.wait_ms` to a 10-hour wait-until-exit
so models stop polling `wait_ms=30000`. That is correct for finite work
(a rebuild, a test suite) that was auto-backgrounded.

It is a footgun for a job started with `run_in_background: true`. Those are
servers. A caller that passes `wait_ms: 1000` meaning "snapshot in one second"
blocks until interrupt (#810).

## Decision

- Finite jobs (auto-backgrounded foreground bash): ADR 0010 unchanged.
  `wait_ms > 0` waits until exit (10h cap). Elapsed-time pulses keep the wait
  distinguishable from a hang (#807).
- Persistent jobs (`run_in_background: true`): `wait_ms` is a real millisecond
  timeout, then a running snapshot. `wait_ms = 0` is still an immediate snapshot.

## Consequences

Checking a long-lived server with `wait_ms: 1000` returns in one second.
A `wait_ms=30000` poll loop on a server also returns every 30s — that is the
cost of making the field mean what it is named for processes that do not exit.
Finite jobs still absorb the legacy 30s poll as wait-until-exit.
