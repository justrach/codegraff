# 0178. Batched edits preflight before one replacement

Status: accepted 2026-09-23

## Context

`edit_file` already accepts an `edits` array, but its loop called the single-span
writer for every element. If a later span was missing or ambiguous, earlier
spans had already changed the file. A nine-span case with an ambiguous third
span left the first two edits behind, so retrying the corrected batch no longer
matched the original text. The loop also reread, wrote, and verified once per
successful span and discarded owned result strings without freeing them.

## Decision

Resolve and confine the selected worktree path as for a single edit, then hold
the same per-path lock from source read through final verification. Apply spans
in order to an in-memory draft, honoring `replace_all`, unique-match errors,
and the source-size ceiling after each span. Any invalid span returns its
one-based index before a snapshot or write. On a valid batch, record one root
snapshot, stage the complete draft in the destination directory, replace the
file once, and verify the resulting bytes exactly. Preserve existing mode and
reject symlink paths under the common file-tool confinement policy.

## Consequences and validation

This gives an all-span preflight guarantee and one committed replacement, not
a transaction across external writers. The lock serializes in-process edits;
the existing size/mtime drift check retries once and is not compare-and-swap.
The staged replacement prevents readers holding the old inode from seeing a
truncated batch. A failure after rename or during verification can report an
error after bytes have changed. Batched edits use the repository's native
replacement helper rather than invoking the optional splice companion for
each span. This retains staged replacement while avoiding per-span writes.

Unit coverage exercises dependent spans, invalid later spans,
selected worktrees, executable mode, open readers, symlink refusal, and
same-path lock contention. The offline `atomic-edit-batch-rejects-later-span`
tier-2 case proves the failed-then-corrected tool loop and fails against the
previous implementation. Independent review checked locking and replacement
semantics. No model-backed latency or token reduction is claimed by this fix.
