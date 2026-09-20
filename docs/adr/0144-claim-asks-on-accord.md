# 0144. Claim conflicts ask on Accord; they do not serialize the machine

Status: accepted 2026-09-20

## Context

Artifact claims are a durable file ledger (ADR 0100). Accord is already the
live duplex for co-resident sessions (ADR 0134). The gate still refused
unrelated `git add` / issue create / new-branch push, then dumped a long
"NOT performed… owner must handoff" string into the tool result. Models
pasted that essay into the user's chat instead of pinging the owner.

## Decision

The ledger still owns the artifact. On a real conflict the harness posts one
line to the owner's worktree room and the device room (JSONL + Accord). The
tool result is one line. The model does not broker the handoff in the
transcript. Staging is not a claim. Empty keys do not match named claims
(#1088).

## Consequences

A live owner gets a `[peer]` wake and can `handoff` / `release`. Unrelated
work proceeds. `GRAFF_ACCORD=0` still delivers on JSONL. Revisit if claims
should *live* as Accord state instead of a file; that is not this decision.
