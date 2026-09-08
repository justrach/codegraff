# 0088. Project constraints require explicit scope

Status: accepted 2026-09-08

## Context

The constraint capture prompt treated every rejection as a standing project
rule. `note_constraint` accepted a model-authored imperative with no scope and
stored it in the project ledger, so wording such as “right now” or “for this
task” could survive compaction and reach unrelated future sessions. Legacy
records carry no scope metadata, and the fullscreen TUI did not expose the
existing `/never` review and retirement path.

Graff has no single reliable boundary for an inferred “task” or “session” across
follow-up questions, goals, resume, branch and frontend-specific `/new`
semantics. Substring classification would also widen quoted, negated or
qualified language.

## Decision

Temporary, task-limited, session-limited and ambiguous steering remains local
conversation context. It is followed as written and is not copied into the
project ledger. Durable capture is allowed only when the user clearly states a
standing project rule. The root then calls `note_constraint` with the explicit
`project` scope and exact text copied from the current user message. Missing or
non-project scope, paraphrased text and overlong text fail before any write.

New durable records carry `scope: project`. Existing records without scope stay
active for compatibility but parse as `legacy_unscoped`; prompt authority and
review output identify them as needing user review rather than silently
confirming project scope. Recorded-state JSON includes scope, provenance and
creation time.

Constraint capture is visible in normal transcripts and reports the exact text,
scope, origin and text-based undo command. The fullscreen TUI exposes `/never`
(`/constraint`) through the existing user-owned command implementation. It
refuses constraint mutation while a model turn, compaction, bash command or file
operation is active rather than racing prompt refresh or cancelling the work.

## Consequences

A plain correction no longer becomes cross-session policy. Explicit project
rules still refresh all prompt variants in the same turn and retain the
append-only, user-only retirement guarantees from ADRs 0033, 0066 and 0067.

Legacy constraints require review but are not silently dropped during upgrade.
Graff deliberately does not persist inferred turn/task/session scopes: adding
those scopes later requires a stable lifecycle identity shared by every
frontend, not natural-language heuristics. Tests cover fail-closed capture,
legacy labeling, visible metadata, same-turn refresh and every fullscreen TUI
runtime trajectory.
