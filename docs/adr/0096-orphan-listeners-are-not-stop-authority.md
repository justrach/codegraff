# 0096. Orphan listener evidence is not stop authority

Status: accepted 2026-09-10

## Context

Ownership records introduced by ADR 0062 cannot describe servers that were
started before the registry existed or whose record write failed. Inherited
environment variables and an orphaned process group can help discover those
listeners, but cannot prove that Graff may safely terminate them. Separate
IPv4 and IPv6 listeners can also use the same numeric port.

## Decision

Discover probable legacy listeners as read-only candidates. Never adopt them
into the ownership registry or signal them based on an environment marker.
Permission failures and incomplete probes remain explicit uncertainty.

For recorded jobs, stopping requires a nonzero matching process start identity
and a verified dedicated process group. Revalidate before escalation; failed
signals are not successful cleanup. PID-only compatibility for display does
not grant stop authority.

Recognizable server launches receive a bounded cross-address-family TCP port
preflight. It must never stop the incumbent. Shell syntax that cannot be
classified safely remains outside the preflight guarantee; a check is not a
socket reservation and cannot eliminate a subsequent bind race.

Silence is not proof that a browser tab is closed. Automatic idle and session
cleanup must preserve a listening job, or one whose listener state cannot be
verified, when browser visibility is unknown. Explicit user stop remains
available. This conservative rule supersedes ADR 0062's assumption that a
silent server can always be stopped. It intentionally retains some unused
servers rather than terminate one still in use; full external-browser tab
inventory is not claimed.

## Consequences

Discovery improves visibility without expanding kill authority. Unknown
browser state sacrifices automatic cleanup for safety. A future complete tab
observer can make a server eligible after its last tab closes, but an empty or
failed partial inventory must never stand in for that evidence.

Related: #817.
