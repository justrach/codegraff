# 0120. Draft publication does not complete verification

Status: accepted 2026-09-15

## Context

A draft PR could bypass the persisted verification obligation even when its
checks failed. Replacing the checklist with a completed handoff item and
calling `attempt_completion` then recorded completion of a verified-PR task.
The unverified label did not protect the acceptance contract (#931).

## Decision

A publication still arms an obligation independently of checklist wording.
Every completion attempt reads fresh head evidence. A draft is insufficient
by default, even if its checks pass; failing base-branch checks explain a
blocker but do not waive the task's requirements.

The user may explicitly choose `/pr-acceptance draft` in the terminal or ACP
client, or `prAcceptance: "draft"` on a JSON user request. This permits only an
unverified draft handoff. `/pr-acceptance verified` or the matching JSON value
revokes it. The choice belongs to the current conversation and goal epoch;
it is not saved, inherited by workers, or reconstructed from model prose.
Resume and new conversations clear it. A new goal cannot reuse it.

Authorized draft handoffs remain labelled unverified and cannot count as
verified recipe success. Ready PRs still require passing checks. This tightens
ADR 0104's distinction between a draft handoff and verified task completion.

## Verification

Offline production-dispatch cases publish through a local GitHub CLI fixture,
replace todos, and repeat completion attempts. They cover failing head/base
checks, user authorization and revocation, and successful verified completion.
The failure cases reproduce on the preceding release build.
