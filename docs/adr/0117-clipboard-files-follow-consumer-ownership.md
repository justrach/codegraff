# 0117. Clipboard files follow consumer ownership

Status: accepted 2026-09-15

## Context

Clipboard exports are application-owned files, while copied file paths may name
user originals. Discarding a composer chip does not imply that prompt history,
a queued turn, a pending worker, or saved replay has stopped using its pixels.
An age-only attachment sweep can remove a live draft when another file uploads.

## Decision

The TUI transfers clipboard ownership explicitly across its callback boundary.
Only owned files without live consumers are released. Pending workers protect
staging inputs, and sent path markers preserve files for saved replay. Preview
conversion uses an exclusively claimed output and removes it on every outcome.

The native desktop records upload ownership and file identity. Discarding an
unsent draft releases its recorded upload; accepting a prompt retains referenced
uploads before dispatching to ACP. Sent files remain available for replay.
Recovery examines a bounded number of ownership records per upload and removes
pending files only when their known desktop owner has exited. The desktop owns
drafts independently of route-server restarts. Unknown owners and unrecorded or
replaced files do not grant deletion authority. Age alone never grants it.

The legacy desktop keeps clipboard exports in a private owner directory with
an operating-system file lease. Recovery takes a nonblocking exclusive lease
before removing recorded unsent exports from a stopped owner. Its prompt
dispatcher retains attachments before either queuing or staging them. Removing
a chip releases it only after other draft trays stop referencing it; uploads
that finish after their composer is disposed are discarded. Cleanup requires a
durable file identity, and remains conservative on platforms without one.

Saved-session deletion or archiving waits for every registered writer to exit,
including writers already closing after tab disposal. EOF gives the worker its
final save; a mutation gate prevents replacement writers until the file operation
finishes. Otherwise exit autosave can recreate a deleted reference and invalidate
the evidence used to decide that an attachment has no remaining consumers.

## Consequences

Conservative retention can keep files when their last consumer cannot be proved
gone. Removing saved replay artifacts and recovering older unrecorded exports
require separate evidence of ownership and references, rather than age guesses.
Tests cover real conversion, transfer/removal, history and queue references,
file replacement, recovery limits, and GUI upload through actual ACP staging.
