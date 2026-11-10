# 0320. Session saves reuse immutable message chunks

Status: accepted 2026-11-09

## Context

Backgrounding a snapshot write did not remove the work of serializing and
rewriting the entire retained history after every tool batch and turn (#1859).
The recall transcript cannot replace the snapshot: it deliberately preserves
superseded messages and is not an exact log of compaction or other mutations.
Loaders, fork sources, session discovery and existing clients directly read
ordinary `.session.json` objects, with listing metadata before `messages`.

## Decision

Keep that JSON contract and change how its bytes are produced and published:

- Observe every message's content fingerprint. Reuse immutable serialized
  chunks for unchanged messages, and serialize only new or changed ones.
  Counts, pointers and last-message anchors are not sufficient evidence.
- Each queued job owns an independently complete chunk vector and fresh
  metadata. The writer never traverses live Agent state. Atomic references
  keep shared chunks alive through coalescing and cache replacement. An
  unchanged-state skip is valid only with no pending or active save, so a
  reverted state cannot be overwritten by an older queued snapshot.
- Pad the JSON header with whitespace so ordinary metadata changes do not
  shift retained message bytes. Under the session write lock, validate the
  previous inode, size and modification time before replacing the header and
  changed history suffix. Unknown bases or header growth use a full write.
- Publish a complete checksummed write-ahead transaction before changing the
  snapshot. It contains before/after digests and both old and new changed
  ranges. File and directory synchronization order journal publication,
  snapshot application and journal removal where the platform supports them.
- Recovery validates the original inode, unchanged bytes and recorded changed
  ranges before replay. Corruption and incompatible external edits fail closed.
  An incomplete staging file is not committed state. Recovery runs before
  CLI/ACP loads, fork reads and session metadata discovery.
- Resolve save destinations before queuing. Saves for different destinations
  must not supersede one another. Preserve drain and per-ticket error reporting;
  release retained snapshot state at process teardown.

## Constraints and alternatives

Content hashing and transaction digests still scan retained memory. This is
not a claim that all save CPU work is constant or proportional to one turn;
repeated JSON escaping, full snapshot allocation and retained-history disk
writes are what ordinary appends avoid. Caching retains a serialized copy of
current history, shared with pending and committed snapshots rather than
copied for each job. Rewrites such as compaction may require larger transactions.

A checkpoint plus a semantic delta log would make existing direct readers see
stale conversations unless every consumer migrated. Retaining canonical JSON
avoids that format change. A bare in-place patch without a recovery record
would instead leave interrupted writes unrecoverable. Atomic snapshot rename
alone would also break the existing inode-based advisory-lock boundary.

The JSON format version is unchanged because field meanings and the complete
snapshot shape are unchanged. Journal staging and recovery have their own
versioned binary framing. Device/filesystem guarantees still bound power-loss
safety; directory synchronization is not portable on Windows.

## Verification

Regressions cover immutable chunk reuse, earlier in-place edits, compaction,
coalescing, destination changes, bounded append transactions, stale-base
fallback, lock contention, partial-application recovery, repeated recovery,
and rejection of corrupt journals or incompatible external changes. The same
save and recovery engine serves the line REPL and ACP.
