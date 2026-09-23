# 0154. Interactive parked shells yield the parent like subagents

Status: accepted 2026-09-21

## Context

Interactive `subagent` already backgrounds and yields the prompt (ADR 0118).
Root `shell` did not: `gh run watch` sat in the 120s foreground wait
(`· bash still running · 1m15s`), then the model polled `bash_output` with
`wait_ms` and the 15s pulse held the turn again. The user could not use the
REPL while CI ran.

ADR 0152 already makes parked jobs snapshot-only. The missing piece was
ending the parent turn so the model cannot immediately poll, and shortening
the interactive wait so a watch parks before a minute is gone.

## Decision

- Interactive root (REPL, TUI, GUI — `interactive_children`) uses the 15s
  foreground wait already used by lean `-p` (ADR 0055). Unattended non-lean
  stays 120s (ADR 0026).
- Parking a job — `run_in_background`, auto-promote, or follow-up promote —
  latches the same yield as ADR 0118. The next model request is replaced with
  a short "keep using the prompt" notice. Exit is an idle wake
  (`job_notify` / `takeIdleWake`). `shell action=output` remains a snapshot.
- Subagent bash still kills at 120s (#93).

## Consequences

`ls` and short tests still return inline. `gh run watch` parks by 15s, the
prompt comes back, and the harness revives when the run finishes. A 40s
`zig build` also parks; the wake carries the result. Models that still pass
`wait_ms: 30000` on a parked job get an immediate snapshot (ADR 0152).
