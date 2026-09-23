# 0179: Reserve durable shell handles before spawning

Status: accepted

## Context

A process-local counter reused shell handles after restart. A handle in saved history could then read or stop an unrelated new command, including after a crash before a session checkpoint.

## Decision

Shell handles are integer IDs from 2^32 through 2^53−1, disjoint from legacy u32 handles and exactly representable by JavaScript numbers. Subagent IDs are unchanged. Reserve each handle before spawning, using an exclusive advisory lock and an atomically replaced, synced high-water counter in HOME/.codegraff. Never reset initialized storage automatically. Keep the stable initialization marker separate from the replaced counter; malformed, missing initialized state, exhausted space or unavailable storage prevents spawning.

A fresh initializer syncs the parent directory, marker and counter before dispatch. Concurrent openers briefly retry an empty initialization marker without holding its lock. A crash during first initialization may leave a marker without its counter; this deliberately refuses further commands until the state is repaired, rather than risk reusing an ID. Ordinary later reservations recover the old or new atomic counter, and no command starts until its reservation is durable.

Unowned handles report an interrupted or unknown outcome and never target a different local process. They do not claim the old command never ran or recommend automatically repeating it.

## Consequences

Every shell spawn pays one durable counter replacement. State belongs to HOME, not an archivable worktree. Deleting all allocator state, restoring an older backup, or changing HOME loses the continuity guarantee; never recommend resetting the ledger as recovery. This change does not reattach surviving commands or provide durable terminal receipts or exactly-once side effects. Unix directory synchronization protects the initialization ordering; Windows retains the file-level guarantees available through the existing atomic writer.

Offline tests cover concurrent first and later reservations, hard termination after reservation, malformed/missing/exhausted storage, integer boundaries, and two actual harness processes showing stale output/kill cannot affect a new command.
