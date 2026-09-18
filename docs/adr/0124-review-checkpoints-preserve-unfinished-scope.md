# 0124. Review checkpoints preserve unfinished scope

Status: accepted 2026-09-15

## Context

A long explicit review could perform many reads without an interim checkpoint
(#306). Review mode already rejects mutation and delegation, and deliberately
supports more than forty tool calls. Stopping after an arbitrary number would
confuse incomplete coverage with a completed review.

## Decision

Every twenty model calls, an explicit root review receives an append-only,
harness-tagged checkpoint asking for verified findings, remaining uncertainty,
and the next inspection. When work remains, progress narration must accompany
the next tool call rather than terminate the review. The checkpoint records an
incomplete protocol event and trace note; it cannot mark the task complete,
change the human request, rewrite the stable prefix, or grant capabilities.
Short reviews, ordinary coding turns and subagents receive no review checkpoint.
The existing opt-in call and tool limits keep their behavior.

This addresses periodic call-count checkpoints only. Review wall-time controls
and entrypoint coverage remain separate requirements; it does not close all of
#306 or introduce a default hard review budget.

## Verification

Unit checks cover milestones, duplicate suppression, provenance and user-text
preservation. The production review regression still completes a forty-six-call
review, observes exactly two checkpoints, rejects edits/workflows, enforces
explicit budgets and restores parent context. A Tier 2 fixture verifies the
incomplete event and unchanged workspace.
