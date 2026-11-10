# 0328. Linux bwrap PID namespace isolation, Landlock ABI probing, and read-only sandbox denial tagging

Status: accepted 2026-11-09

## Context

Read-only subagents and review sessions execute commands inside an OS sandbox (`sandbox-exec` on macOS per ADR 0232, `bwrap` on Linux). On Linux, mounting `--proc /proc` inside `bwrap` without `--unshare-pid` exposed host PIDs to the sandboxed process, and when a read-only command hit an OS write denial (`EROFS`, `EACCES`, `EPERM`), the raw stderr looked like an ordinary filesystem error, causing models to waste turns retrying the write with `chmod`, `sudo`, or alternate paths (`e1a6625d`).

## Decision

- `readonly_sandbox` passes `--unshare-pid` alongside `--proc /proc` on Linux `bwrap` invocations.
- `linux_landlock` provides a zero-dependency Linux Landlock ABI v1–v3 syscall probe (`landlock_create_ruleset`) and denial classifier (`annotateSandboxDenial`).
- When a read-only sandboxed command exits non-zero with an OS write-denial signature (`Read-only file system`, `EROFS`, `Operation not permitted`, `Permission denied`), `exec_bash` appends an explicit `[sandbox policy boundary: read-only mode denied a write/mutation ...]` note to the tool result so the model stops retrying mutations inside a read-only worker.

## Consequences

Linux read-only workers run in an isolated PID namespace, and sandbox write refusals are immediately recognized as intentional policy boundaries rather than transient command errors.
