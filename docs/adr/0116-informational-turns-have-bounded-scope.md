# 0116. Informational turns have bounded scope

Status: accepted

## Context

The coding prompt applied edit completion, testing, orchestration, and
evidence collection requirements to simple repository summaries (#884).
The named-file nudge could explicitly demand an edit to a file the user
only wanted explained. A lean first answer could also be treated as an
unapplied change regardless of the actual request.

## Decision

Keep informational and implementation instructions together in the stable
prefix. The informational branch asks for a broad map and targeted reads,
then a concise answer when purpose, architecture, and constraints are clear.
It does not require a checklist, delegation, exhaustive reads, test commands,
or a separate citation pass. Requested changes keep the existing edit,
root-cause, and project-local verification requirements.

A conservative per-turn hint recognizes explicit informational verbs.
Mixed requests containing execution or mutation verbs keep general handling.
This hint never grants permission, changes tool availability, or completes
an existing goal. Ambiguous requests retain general handling; the model
still has to follow the actual user request and its context.

Informational answers are exempt from the edit-oriented first-answer bounce.
A named-file nudge requests evidence without demanding an edit. After four
model rounds or six tool calls, an informational turn gets one soft checkpoint asking whether
existing evidence suffices, rather than a forced stop. The checkpoint is an
append-only history item marked with harness provenance. It does not rewrite
the stable prefix or impersonate a human message in saved-session views.
The inferred intent and checkpoint are visible in the trace.

## Verification

Regression fixtures cover summary completion, checkpoint insertion, and mixed
mutation requests. Live terminal and GUI runs verify bounded representative
reads, an evidence-based answer, no unrequested edits or test execution, and
saved notification provenance. A live mixed request still applies the root
fix and runs the project tests. A first GUI run exposed a broad read batch
followed by exhaustive shell reads; the tool-count checkpoint covers that
case as well as long sequential runs.
