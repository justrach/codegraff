# 0057. peer_message addresses a session by its visible title

Status: accepted 2026-08-31

## Context

Presence records carried pid, opaque `session_id`, worktree identity, and
goal. Users refer to a live session by the title in `.session.json`.
`peer_message session:"Fixing login recovery"` missed. Goal substring is
the wrong substitute: goals can be absent, stale, or shared.

## Decision

Device-local presence stores `title` and `session_base`. Resolve in this
order: exact title, exact saved-session base, unique normalized
title/slug, then the existing id/pid/name/goal path. Duplicate titles
are ambiguous (return candidates). Refresh on announce, `/rename`,
AI title, `/resume`, `/save`, `/new`, `/clear`. Older records without
the fields still parse. Presence stays device-local.

## Consequences

`action=list` leads with title and base. Cross-laptop discovery is still
not implied. Title is not a global name.
