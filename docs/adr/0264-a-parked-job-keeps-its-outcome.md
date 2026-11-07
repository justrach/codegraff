# 0264. A parked foreground job keeps an answer for its handle

Status: accepted 2026-10-07

## Context

ADR 0218 made background jobs durable but kept parked foreground commands on
pipes, because their `cmd &` idioms depend on pipe EOF. Their handles outlived
them: after a session continued in another graff process, `action=output` or
`action=kill` on the handle found no owner and could only say "interrupted or
unknown outcome", even when the command had finished (#1486).

## Decision

- When the foreground wait parks a command, graff writes
  `.graff/job-parked/<id>.json` with the command and the owning graff's
  identity.
- When the pool frees the job, the record is rewritten with its final state:
  the exit code and the unread output tail (16 KB), killed, stopped at session
  end, or left running at session end.
- A handle this process does not own is answered from that record. If the
  owner is still alive, the answer says the job belongs to that graff. If the
  owner died without a final state, the answer says so and does not claim the
  command finished.
- Records older than a week are swept when a new one is written.

## Consequences

A continuation gets an explicit result for every parked handle instead of
"unknown". The command itself still dies with its owner's pipes; making it
survive would need ADR 0218's file capture from the start, which would break
the pipe-EOF idioms. Revisit if parked commands need to survive a crash.
