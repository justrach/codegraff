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

## Consequences

Opening and refreshing history never bootstrap an ACP session. The composer
is replaced by Refresh snapshot and Continue here controls, including for empty
histories. Continue here enables composing; the first prompt resumes the saved
session. Saved turns keep unknown execution status after refresh, including
when reading older projected responses.

Continuation ownership is explicit before the user sends. Live attach, if
added later, needs a different endpoint than the saved-file GET.
