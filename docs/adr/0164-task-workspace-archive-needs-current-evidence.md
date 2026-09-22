# 0164. Task workspace archive needs current evidence

Status: accepted 2026-09-23

## Context

A merged pull request alone does not prove that later commits in its branch
were delivered. A clean checkout can still contain unique commits. Removing
the checkout before resolving its common Git directory also prevents branch
cleanup from running successfully.

## Decision

Task creation records its landing branch. Update uses that branch; landing
requires the destination to be on it and the source to remain on its owned
branch. Both checkouts must be safe before landing. Explicit discard requires
confirmation. Archive removes the checkout before deleting its branch.

The merged-archive CLI requires a clean checkout and a merged PR whose head
is exactly the checkout's current commit. Missing or stale evidence keeps the
checkout. Teardown runs only after the keep checks, and failure keeps the
checkout. Kept work is returned with its reason.

Age-based pruning is also distinct from an explicit discard. It retains the
current checkout, release/hotfix branches, experiment pools (ADR 0037), locked
trees, live or unverifiable
auto-session processes, and registered live owners. A legacy owner record with
no process start identity cannot prove the tree unused. Unreadable ownership
evidence retains the tree; age never overrides the dirty/unique-commit checks.

## Consequences

Old workspaces without recorded base metadata retain their existing explicit
landing behavior. Agent completion remains distinct from archive. Offline
Git fixtures cover script execution, current merge evidence, retention, and
branch cleanup.
