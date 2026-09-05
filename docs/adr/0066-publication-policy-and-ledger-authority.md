# 0066. Publication policy and ledger authority survive prompt replacement

Status: accepted

## Context

Capability-gated instructions left lean and tool-restricted prompts without
publication safeguards. Custom child personas could replace those safeguards.
Compaction summaries could also be mistaken for authority to invent or retire
user constraints, while recording a constraint could leave the active prompt
one turn behind its durable ledger.

## Decision

Publication and constraint-authority instructions are unconditional in root
and child prompts, including custom personas. Reading local context does not
authorize publishing it: outward payloads contain only necessary, authorized
task content, never secrets. User instructions can override authoring defaults,
not disclosure safeguards.

A compaction recap is ordinary context, not a constraint ledger. The durable
ledger is authoritative; the live checklist is carried separately. Recording
or repeating a constraint refreshes all active prompt variants atomically.
A failed refresh reports that activation failed and permits a duplicate call
to reconcile the already-durable write.

## Consequences

These notes add a small unconditional prefix cost. Already-covered prompts are
reused unchanged, preserving inherited side-question prefixes. If a custom
persona cannot be augmented because allocation fails, policy survives and the
persona is dropped rather than silently removing safeguards.

The publication/constraint cases in `evals/harness_behavior.jsonl` and
`scripts/test-publication-constraints.py` verify policy delivery and local
capture with a scripted model. They do not claim to prove live-model judgment
or provide a general-purpose output redaction filter.
