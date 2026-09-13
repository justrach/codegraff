# 0105. Explicitly stop a selected legacy listener snapshot

Status: accepted 2026-09-11

## Context

ADR 0098 correctly refused to treat inherited environment variables as stop
authority. That left users unable to clean up pre-registry listeners through
the server command even after inspecting them.

## Decision

Keep discovery and automatic cleanup conservative. Add a separate explicit
`servers stop-suspect <pid> <identity-token>` action. Listing offers a token only
when start identity, executable metadata, and dedicated group leadership can
be observed. Stopping rediscovers a same-user orphan listener and requires the
current snapshot to match the token. The signal path rechecks start identity,
executable metadata, and group eligibility before TERM and KILL. Missing or
changed evidence refuses the signal. No ownership record is created.

This adds user-selected stop authority to ADR 0098. It does not infer ownership
from environment hints. A token is a stale-target check, not a credential.

## Consequences

Users can explicitly clean up a discovered legacy listener without weakening
automatic cleanup. Unsupported platforms or opaque processes remain read-only.
The native regression creates its own orphaned listener, verifies an invalid
token leaves it serving, then uses the displayed token and verifies its socket
closes. Port preflight remains a best-effort cross-family observation rather
than a socket reservation.
