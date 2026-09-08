# 0088. Constraint scope is ledger state

Status: accepted 2026-09-08

## Context

`note_constraint` recorded every reject/forbid/veto as an unscoped project
rule (ADR 0067). "I don't want this right now" became hard policy for every
later session. #789.

## Decision

Each user item has a scope: `turn`, `task`, `session`, `project`, or
`legacy`. Implicit rejections default to `session`. Durable `project` scope
requires standing language ("never … in this project") or an explicit
`scope=project` argument. `turn` items are not injected after the turn.
Existing records without a scope field are `legacy`: still injected, listed
as review-needed. `/never` shows scope. ADR 0067 authority JSON gains `scope`.

## Consequences

Temporary steering no longer widens into project policy. Users review legacy
items with `/never` rather than discovering them months later.
