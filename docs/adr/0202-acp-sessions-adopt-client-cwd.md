# 0202. ACP sessions adopt the client cwd and report worktrees in `_meta`

Status: accepted 2026-09-25

## Context

ACP requires an absolute `cwd` on `session/new` and `session/load`, and the
agent must use it regardless of where it was spawned. Graff ignored it on
`session/new` and ran in its launch folder. It reported an isolated checkout
as a top-level `cwd` in the reply, which ACP does not allow: extensions belong
in `_meta`. `session/load` accepted only the exact folder the process was
running in, so a host that relaunches `graff acp -w <name>` for every turn and
names the repository root was refused, and a save made inside a linked tree
could not be reopened from the main checkout.

## Decision

`session/new` and `session/load` make the client's `cwd` the session's
working directory: tools, relative paths, `.graff/` storage and path
confinement follow it. A relative or missing directory is an invalid-params
error. When the client names the checkout that owns the process's `-w` or
auto-isolated tree, the process keeps that tree.

Both replies carry `_meta["graff/worktree"]`. It is an object with `name`
(the `-w` name: branch minus `worktree-`, else the folder name), `path`,
`branch`, `base` (the recorded landing branch or null), `baseSha`, `root`
(the owning main checkout) and `generated` (an auto-isolated `session-*`
tree), or an explicit `null` in a main checkout. A missing key means an older
build. The top-level `cwd` field is removed.

`session/load` from a main checkout also finds a save inside one of its own
`.graff/worktrees/*` trees and re-enters it, matching CLI resume (ADR 0155).
No other folder is searched.

When `/workspace use` or the `workspace` tool moves the root session, the
prompt reply is preceded by `session_info_update` whose `_meta` carries the
new value.

`graff worktree` exits 1 when it refuses or fails and 2 when it does nothing
(`kept`), so hosts can branch on the status instead of the text.

## Consequences

Hosts learn the worktree and branch from the protocol and can pin a chat to a
named tree (`-w`). Auto-isolated `session-*` trees are reaped once their
process is gone (ADR 0147), so hosts that relaunch per turn should pin named
trees, not generated ones. The system prompt's project instructions and repo
map are still read from the launch folder; a `session/new` in an unrelated
folder keeps them until that is rebuilt per session. This supersedes the
ADR 0146 line about reporting the checkout as `cwd`.
