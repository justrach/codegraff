# 0305. Cancelled checklist items carry a reason

Status: accepted 2026-10-28

## Context

Verification items stay on the checklist until the user changes scope (#844),
so a session whose user withdrew publication steps, or handed them to another
session, could not finish: leaving the items out of `todo_write` restored them,
and `attempt_completion` refused with "completion deferred: N unresolved
verification item(s) remain" (#1520). #1545 added a `cancelled` status, honored
for a verification item only after a newer user message. An answer given
through `ask_user` did not count, and a cancelled item said nothing about why.

## Decision

`cancelled` is the one status for work the user withdrew or delegated. Every
cancelled item needs a short `reason` (one line, capped at 160 bytes). A
`todo_write` that cancels an item without one is rejected whole and leaves the
list unchanged, so a client never shows a cancel that did not happen. An item
that was already cancelled keeps its recorded reason when re-listed without
one.

A verification item can be cancelled only after the user's latest word on the
task changed since the item was first written: a newer user message, as
before, or an answered `ask_user`. The request fingerprint folds in the count
of recorded answers.

A cancelled item stays in the list and in the saved session with its reason.
It no longer blocks completion or counts as open work, and it never counts as
verified (`goal_verify.taskVerified`). The checklist renders it as
`[-] content (cancelled: reason)`; the line REPL's WORKING block draws it as
`⊘ content (reason)`, outside the done/total count.

## Consequences

The model cannot drop a verification item silently: the item stays visible,
its reason is on the record, and verified-success telemetry still reads the
task as unverified. Any answered `ask_user` unlocks cancellation, the same
trust a newer user message already had.

ACP has no plan update. ACP clients see the `todo_write` call's raw input,
which now carries `reason`. A rejected write closes its row as failed. A
cancel refused for lack of a scope change is still applied per item (the item
keeps its previous status, and the reply says so), so that row's raw input can
overstate what happened.
