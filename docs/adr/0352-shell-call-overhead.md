# 0352. Cut per-shell-call overhead without weakening crash safety

Status: accepted 2026-11-26

## Context

A 30-call instant-model loop spent ~9 ms per shell on waiting to notice exit
and on durable writes. The first foreground poll step was 5 ms; the shell-id
counter, session journal, job registry, and `.graff/.gitignore` each fsynced or
rewrote on every spawn; each model request dialed a new TCP connection because
stream end poisoned the keep-alive socket.

## Decision

- `pollStepMs` uses 1 ms for the first five ticks (then 10/20/65/100). Linux
  waiters poll a pidfd for child exit and wait on `Jobs.progress` for the pump
  to set `done`. Other platforms wait on the Condition with the same timeout.
  Pulse alignment at 100 ms is unchanged.
- Shell IDs reserve a durable block of 64 per high-water rewrite (ADR 0179).
  In-process issues stay consecutive; cross-process blocks do not overlap.
- `.graff/.gitignore` is created only when missing. Quiet foreground jobs skip
  `jobs/N.json` until auto-background. Session WAL still syncs the journal
  before publish, the directory after journal rename, the snapshot file, and
  the directory after journal unlink. The extra directory sync after in-place
  snapshot pwrite is omitted (the inode is already synced).
- After a clean SSE terminal event, drain the HTTP body with a short bound and
  keep the connection. Interrupt, stall, and error paths still poison it.

## Consequences

Short foreground commands return closer to process exit. A process that dies
after reserving a block skips unused IDs in that block. Quiet in-flight jobs
are absent from `graff servers` until promoted. Gateways that hold SSE open
after `[DONE]` wait up to 20 ms then drop the socket instead of hanging.
Rerun `bench/shell/` after changing any of these paths.
