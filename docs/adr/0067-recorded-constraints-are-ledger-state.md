# 0067. Recorded constraints are ledger state, not recap prose

Status: accepted 2026-09-05

## Context

Issue #738 exposed two distinct failures: a compaction recap invented a
recorded prohibition, and a recorded user override did not reconcile the
active instructions until another human turn. A model-written summary is
not evidence that an append-only ledger operation succeeded (ADR 0033).
ADR 0066 already makes publication and constraint-authority instructions
unconditional; this record is the structural half: the prefix carries the
live ledger as data, not as generated prose.

## Decision

The root prefix carries a deterministic `recorded_user_constraints` JSON
array derived from the live ledger, including ids, exact text and provenance.
The empty array is explicit. Learned advice and retired records are excluded.
Generated handoffs are labelled fallible context, not recorded-constraint
authority; the summarizer must not regenerate a recorded-constraints section.
This distinction does not erase explicit user instructions that were never
recorded, and does not grant permission to override safety requirements.

Successful `note_constraint` writes and duplicate calls rebuild all active
prompt variants before the next model request in the same turn. Changed
instructions invalidate the Responses continuation. If rebuilding fails, the
tool reports durable success separately from unavailable prompt refresh,
rather than falsely promising immediate reconciliation. Duplicates retry the
refresh without appending another record. Bookkeeping stays out of normal UX.

## Consequences

The root prefix pays for the structural ledger even when it is empty, and
constraint changes intentionally invalidate the cached continuation. Summary
prose can still be factually wrong, but is never the source of recorded rules.
Built-in style guidance must separately yield to explicit user overrides;
actual safety requirements remain non-overridable. Tests exercise ledger
serialization/retirement, duplicate recovery, same-turn refresh, and handoff
authority boundaries in the existing playbook and compaction suites.
