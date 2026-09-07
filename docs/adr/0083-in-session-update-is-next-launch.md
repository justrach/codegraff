# 0083. In-session `/update` installs for the next launch

Status: accepted 2026-09-07

## Context

Updating from a live terminal session must not require a second terminal, and
must not interrupt the conversation. Automatic restart and launch-flag replay
(#770) would activate new code in a way that looks like `/new` or `/resume`
had switched binaries. The existing `graff update` CLI is process-fatal and
delegates to `curl | install.sh`, which inherits a TTY and is not safe to
call from the pager.

## Decision

`/update` (line REPL and TUI) uses a nonfatal in-process service: pin a
GitHub release tag, download that tag's tarball and `SHA256SUMS`, verify,
and atomically replace the resolved user install. Installation requires an
explicit human confirm in this process (TTY picker or `/update install`
after a human `/update` check). Model output, tool calls, saved
conversations, and yolo/always-approve are not authorization.

The live process, conversation, and permissions stay on the original binary.
`/new` and `/resume` only change conversation state. A later normal launch
uses the installed executable. Package-managed and zig-out paths are
explained, not overwritten. Fail closed if verification is missing.

## Consequences

Activating new code without a restart stays out of scope (same boundary as
ADR 0079). `graff update --check` shares the running/latest comparison in
`version_status.zig`. Isolated fixtures cover install, already-installed,
offline/malformed, verify, permission, cancel, and concurrent requests.
