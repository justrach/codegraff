# 0111. Informational asks are not mutation work

Status: accepted 2026-09-14

## Context

#884: a default interactive turn treated "go through the codebase and
summarize what it does" as implementation work. The same prompt on the
same snapshot finished in 39s in a Codex trajectory and 251s here,
because orchestration, todos, `work_note`, and `path:line` closing
guidance all assumed a change to apply and verify.

`Match the verification to the ask` was already in `work_note`; the
stronger completion language won.

## Decision

- Prompt text gates todo, fan-out, test, and citation-pass requirements
  on explicit summarize/explain/map/inspect verbs **and** the absence of
  a requested mutation. Mutation tasks keep read-before-edit, root-cause,
  and in-project verification.
- The harness classifies that intent, writes it on the JSONL trace
  (`ev=task_intent`), and after six model rounds on an informational
  turn injects one checkpoint asking whether the model can answer now.
- Lean `-p` fake_done bounce (ADR 0052) does not fire for an
  informational ask: a prose summary is done.

## Consequences

Informational turns stop after a bounded map. Mutation turns are
unchanged. Classifier false positives default to mutation. Evals:
`src/task_intent.zig` unit tests, prompt pins in `prompt_lean_tests.zig`,
scripted `evals/harness_behavior.jsonl` cases, and the
`readonly-summary` graff-eval trap (no test/build marker, no edits).
