# 0316. Rejected compaction restores exact input

Status: accepted 2026-11-08

## Context

Reanchoring a request cannot repair an opaque compaction item that the server
rejects even in full input. The prior failure diagnostic preserved that item
but left continuation blocked. A transcript is useful for recall, not proof of
an exact pre-compaction window: deduplication, rewrites and rotation can change
its ordering or coverage. Silently dropping opaque state loses context.

## Decision

Before replacing a durable root conversation with server-compacted input,
atomically retain its exact prior input and the complete replacement window
in a private, bounded checkpoint under the session's local artifact directory.
An automatic prune checkpoints the folded prefix; standalone compaction
checkpoints all input and all canonical output items. Checkpoint failure
prevents the destructive replacement. Files are immutable, content-checked,
and cannot follow symlinks outside the workspace.

After a full-input encrypted-state rejection, restore a checkpoint only if
its complete replacement window still exactly matches the current prefix.
Append all subsequent conversation verbatim. Reset transport and token-meter
anchors, then rebuild the request. At most eight checkpoint restorations are
allowed per request, independently of transport retries. Missing, changed or
invalid checkpoints preserve the live history and surface the blocked state.
This shared engine path applies to both REPL and ACP.

## Consequences

New compactions have a history-preserving recovery path across process restarts.
Older opaque state without a checkpoint cannot be reconstructed automatically;
a new process or model switch must not be described as restoring that state.
Checkpoints contain private conversation data, never appear in telemetry or
public reports, and follow the existing local session-artifact lifecycle.
Non-durable auxiliary agents do not acquire durable root-session checkpoints.
This adds local disk I/O at actual compaction boundaries, not ordinary calls.
