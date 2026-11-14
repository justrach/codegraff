# 0341. Verification matches the requested application

Status: accepted

## Context

Issue #1899 showed that passing tests and screenshots of a retired frontend
can be mistaken for proof of a current application change. The checkout can
be valid Git history while still being the wrong implementation for the task.

## Decision

When a current-application request conflicts with visible source/release
metadata or frontend architecture, reconcile the manifest and packaging entry
point before editing or expensive verification. Resolve genuine target
ambiguity with the user. Explicit historical-version work remains supported;
never automatically upgrade, switch branches, or discard changes.

Verification claims must identify their implementation scope and limitations.
Historical tests prove historical behavior, not the current packaged frontend.
This guidance is shared by full and lean root prompts on REPL and ACP.

## Consequences

A version difference alone is not an error and does not force remote lookups
on every task. Targeted reads are required only when visible evidence conflicts
with the requested application. Prompt/eval coverage checks that this guidance
survives composition; scripted evals do not prove autonomous target selection.
