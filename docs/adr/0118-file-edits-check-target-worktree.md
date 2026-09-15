# 0118. File edits checkpoint the target worktree

Status: accepted 2026-09-15

## Context

A file tool can run from one checkout while editing a nested linked worktree.
Using only the caller's presence identity incorrectly warns about parent peers
and misses peers that actually share the target tree.

## Decision

Resolve file-tool paths using the same session-relative rules as the write.
Find the nearest existing parent directory for new files and resolve its Git
worktree identity. For a different Git worktree, checkpoint that identity's
live peers. For the caller's tree, preserve its announced identity, including
when Git was initialized after startup. Unresolved and non-Git targets retain
the conservative caller checkpoint. Approval and path-confinement checks stay
in place.

## Consequences

Disjoint nested worktrees no longer consume parent-peer acknowledgments.
A target with its own live peer still warns before the first write. The two
`peer-checkpoint-file-target-*` behavior cases use real linked worktrees and
live harness peers to verify both directions; both fail on the former path.
