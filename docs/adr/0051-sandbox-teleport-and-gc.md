# 0051. Sandbox leftover of #554 is teleport plus snapshot GC

Status: accepted 2026-08-29

## Context

#554 shipped the Docker CLI seam, `/snapshot`, and `/rewind <id>`. Two exo
misses stayed open: restoring a `docker_image_tar` on a *different* backend,
and deleting leftover snapshot trees. ADR 0037 still pointed experiment-pool
Docker snapshots here.

## Decision

`/teleport <id> [docker|container]` restores a captured tar onto another CLI
backend. Apple Container (`container`) is the second backend — same wire as
`docker`, different `bin_name`. Dest defaults to `container` when the live
backend is docker or nothing is attached. `/snapshot gc [n]` keeps the newest
n snapshots (default 1) and deletes the rest. The conversation is never
rewound. Missing CLIs stay explanations, not crashes.

## Consequences

Daytona is still not a backend. There is no `graff registry` client. A
snapshot's kind stays `docker_image_tar` even when the dest CLI is
`container`. Experiment-pool isolation is still opt-in worktrees (ADR 0037).
