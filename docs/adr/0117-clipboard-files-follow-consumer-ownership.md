# 0117. Clipboard files follow consumer ownership

Status: accepted 2026-09-15

## Context

Clipboard exports are application-owned files, while copied file paths may name
user originals. Discarding a composer chip does not imply that prompt history,
a queued turn, a pending worker, or saved replay has stopped using its pixels.
An age-only attachment sweep can remove a live draft when another file uploads.

## Decision

The TUI transfers clipboard ownership explicitly across its callback boundary.
Only owned files without live consumers are released. The TUI captures file
identity without following symlinks and preserves replaced or edited exports
before attachment removal or teardown. Pending workers protect
staging inputs; worker completion retries deferred draft cleanup. Accepting a
user history entry retains its owned image paths independently of later visible
history or recall clearing, because saved replay can still need those files. Preview
conversion uses an exclusively claimed output and removes it on every outcome.

On supported temporary storage, TUI pending exports have private recovery records
held under exclusive file locks. Each paste scans a bounded number of records
using a rolling cursor. Recovery can reclaim a matching, unchanged export only
when its record can be locked, so live drafts remain protected. Submission must
remove recovery authority before accepting the user history entry; failure stops
the handoff and allows prompt recall/retry. Unknown or malformed records and
changed exports are preserved. Unsupported locking or unavailable temporary
storage disables recovery registration rather than granting deletion authority.

The native desktop records upload ownership, file identity, size and a content digest.
Deletion verifies unchanged bytes; replacing or editing an export never grants
cleanup authority. Older records without content identity remain preserved. Discarding an
unsent draft releases its recorded upload; accepting a prompt retains referenced
uploads before dispatching to ACP. Sent files remain available for replay.
Recovery examines a bounded number of ownership records per upload and removes
pending files only when their known desktop owner has exited. The desktop owns
drafts independently of route-server restarts. Unknown owners and unrecorded or
replaced files do not grant deletion authority. Age alone never grants it.

New native submissions also enroll their canonical session directory in
immutable per-image reference records. Multiple workspaces accumulate records
without overwriting one another. An unscoped submission permanently records
uncertainty; older exports cannot acquire complete scope knowledge retroactively.
A bounded read-only scan covers checkpoints, both transcript generations and
archives, decoding JSON before checking names. Missing, malformed, symlinked,
changed or over-budget data is unknown. This evidence is scoped: it does not
by itself authorize deletion or exclude active consumers.

Native prompt handoff also appends a worker process record before dispatch.
The originating desktop and every enrolled worker protect in-memory consumers
across route-server restarts. Process termination, rather than completed output
or tab disposal, releases that evidence; unknown records and reused live process
identifiers preserve files. Older exports cannot gain complete consumer knowledge
retroactively. This process inventory still requires cross-surface enrollment
and collection serialization before it can authorize submitted-file cleanup.

Native worker startup enrolls its canonical session-directory scope, including
resumes that load image history without submitting a new attachment. The backend
registers before spawn and the worker registers before bootstrap completes.
Every scoped live process conservatively protects that workspace's retained
images; unknown or absent scope records cannot prove inactivity. This may retain
extra images while another chat in the same workspace is open.

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
The resumable checkpoint and both current and rotated companion transcripts are
one saved-chat lifetime: deleting removes all, while archiving moves them under
a shared archive name without overwriting or mixing with an older bundle. An independent archive remains
a consumer of its image references.

## Consequences

Conservative retention can keep files when their last consumer cannot be proved
gone. Removing saved replay artifacts and recovering older unrecorded exports
require separate evidence of ownership and references, rather than age guesses.
Tests cover real conversion, transfer/removal, history and queue references,
file replacement, recovery limits, and GUI upload through actual ACP staging.
