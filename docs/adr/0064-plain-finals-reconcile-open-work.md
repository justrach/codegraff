# 0064. Plain finals reconcile open work once

Status: accepted 2026-09-05

## Context

A root turn can emit a plain final reply after starting tools while its current
checklist remains unfinished (#745). The `attempt_completion` gate does not run
on that path; empty-completion and named-source nudges do not cover it. A promise
to continue can therefore return control to the user without continuing work.

## Decision

Before accepting a plain final with live, current-epoch checklist items, offer
one reconciliation request per root turn. Include the actual open checklist and
instruct the model to continue independent work, collect required background
results with a blocking wait, or explain the real blocker. Status-only requests
and user instructions to pause must not be converted into permission to act.

Do not gate explicit accepted completion, review, text-only or child agents, or
paused/blocked goals. Preserve cancellation and model/tool budgets. Do not reset
the retry allowance after tools: a model repeatedly narrating progress must not
create an unbounded loop. If the turn still ends with open work, append a factual
notice that root execution has stopped; existing background jobs may still run.

## Consequences

- One extra model call is possible for a legitimate status answer with an open
  checklist. This is preferable to language-specific promise detection.
- The guard cannot force a model to finish. It provides a bounded recovery and
  makes the remaining stop explicit rather than silently implying continuation.
- No global worker wait: unrelated jobs and long-lived servers must not hold a
  turn open. The checklist, not process-wide job presence, owns the scope.
- Scripted tier-2 cases cover continuation and the retry limit; unit tests cover
  epoch scope, exemptions, wire shapes and cancellation/budget boundaries.
