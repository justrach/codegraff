# 0152. Persistent shells snapshot once and stay in the job list

Status: accepted 2026-09-21

## Context

ADR 0091 made `wait_ms` a real millisecond timeout on `run_in_background`
servers so `wait_ms: 1000` would not block for 10 hours (#810). Models still
pass `wait_ms: 15000` / `180000` on a server. The wait pulses every 15s
(`bash_output · job N still running · … unread byte(s)`) and floods the
transcript. The tool result already called `wait_ms` a snapshot timeout.

Background subagents already return one id and continue. A persistent
server should match that: one "running" result, then the model works. Exit
is a later wake (ADR 0010 notify).

## Decision

- Persistent jobs (`run_in_background` or auto-parked after the foreground
  wait) return an immediate running snapshot from `action=output` /
  `bash_output`. `wait_ms` is ignored.
- The job stays in `/jobs`. Unread bytes are read by a later snapshot.
  Do not poll.
- Finite (non-persistent) jobs keep ADR 0010: `wait_ms>0` waits until exit
  (10h cap). REPL, TUI, and GUI share this engine path.

## Consequences

A `wait_ms: 30000` call on a server returns now, not in 30s, so the 15s
pulse cannot fire. A model that wanted "sleep 1s then snapshot startup
logs" no longer can through `wait_ms`; it snapshots now and reads again
later if needed. Finite CI watches are unchanged.
