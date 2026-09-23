# 0193. Jev selects effort only

Status: accepted 2026-09-23

## Context

An optional general judgment tool could assess arbitrary actions but did not
change the harness's effort. A small decision evaluation saw correct first
actions with and without that tool; it did not establish a benefit from
generic judging. Effort is already a session setting shared by CLI, TUI, and
ACP (ADR 0191).

## Decision

Expose only `jev_effort` to eligible root sessions with a separate Codegraff
login. Accept a short task summary, then build a fixed choice from the active
model's supported effort levels. Reject arbitrary questions or judgments.
Queue a validated selection per agent and apply it on the owning thread at
the next request boundary, only if the provider, model, and effort allowlist
still match. A failed or invalid response leaves the setting unchanged.
Explicit user `/effort` and ACP settings remain available. No automatic Jev
call is made.

## Consequences

Changing effort may miss cached prefixes or reset a WebSocket reasoning chain;
the explicit tool call is the opt-in boundary for that cost. ACP publishes the
same thought-level update as a manual change. Billing and independent login
rules from ADR 0187 remain in force.
