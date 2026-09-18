# 0119. Historical completion requires green behavior and a clean exit

Status: accepted

## Context

A substantial historical feature is useful for exercising sustained coding,
but raw PR size includes generated files and release integration. A process
can also produce correct artifacts and then hang; grading artifacts alone
mislabels that outcome as completion.

## Decision

The opt-in completion suite uses a pinned historical package and an external
behavior grader. The RLM task is scoped to the feature introduced by PRs
619/621, with a documented tool-log lifetime patch applied identically to
parent and reference. Calibration must establish red parent, green reference,
rejection of a constant-output stub, preserved unit coverage, an exam with only an isolated baseline commit and no
upstream history or evaluator material, and rejection of an already-green start.

Strict setup failures stop the run. `requires_clean_exit` tasks pass only when
the process exits zero within its deadline and artifacts pass grading. Keep
`artifact_ok` separate so partial outcomes remain visible. Existing suites
retain their current scoring until they explicitly opt in.

## Consequences

One solving run is a smoke result; three repetitions are required before a
task-level completion score. Local exam directories are reproducible development
environments, not protection against a solver deliberately fetching a public
answer. Keep this reserve suite separate from the capped live 12 until its
coverage and execution isolation justify promotion.
