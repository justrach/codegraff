# 0099. GUI saved sessions are snapshots, not live REPL attach

Status: accepted 2026-09-10

## Context

Opening a `.graff/sessions` file in the GUI while the same conversation is
still running in the REPL painted an idle transcript and a normal follow-up
composer (#839). The saved JSON has no live execution field, and the GUI
derived "finished" from local turn status plus a successful load.

Attaching to the REPL process from the desktop is a different product path
and is not what `/api/sessions` returns.

## Decision

A GET of a saved session is a snapshot with unknown live status
(`view: "snapshot"`, `execution: "unknown"`). The GUI must label that view
and must not infer that commentary or a successful load means the other
surface finished. A follow-up in the GUI starts a GUI session; it does not
claim the REPL turn.

Unmatched tool calls in the last restored turn stay running so the snapshot
can still show in-progress work. That is display state, not a live attach.

The checklist comes from the saved session’s top-level `todos` field when
present, including an empty list. Historical `todo_write` arguments may be
stale or rejected proposals and must not override that saved state. Older
files without the field retain history-based reconstruction. This does not
turn a saved checklist into live execution status.

Harness-authored budget, compaction, and completion reminders use the same
notification provenance as generated wakes; they never become the latest human
request. Actual one-shot prompts retain their human provenance.

Generated wakes retain `_graff_origin: "notification"` in saved message objects.
Their provider role remains `user`, but wire serializers omit this internal field.
The GUI renders these as expandable session notices and excludes them from prompt
recall and title recovery. Text prefixes are not evidence of notification origin;
older unmarked job notices retain their historical presentation.

Before enabling continuation, the GUI reads fresh saved metadata and compares
the selected model and workspace. Changes flag cache reuse as at risk; matching
metadata remains unverified. No agent or model request is started by this check.
Saved settings cannot establish prefix equality or provider cache retention.

The saved view shows one compact status notice beside its continuation controls;
transcript headers and individual turns do not repeat it. Saved turn status remains
unknown after continuation.

## Consequences

Opening and refreshing history never bootstrap an ACP session. The composer
is replaced by Refresh snapshot and Continue here controls, including for empty
histories. Continue here enables composing; the first prompt resumes the saved
session. Saved turns keep unknown execution status after refresh, including
when reading older projected responses.

Continuation ownership is explicit before the user sends. Live attach, if
added later, needs a different endpoint than the saved-file GET.
