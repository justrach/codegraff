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

## Consequences

Conservative retention can keep files when their last consumer cannot be proved
gone. Removing saved replay artifacts and recovering older unrecorded exports
require separate evidence of ownership and references, rather than age guesses.
Tests cover real conversion, transfer/removal, history and queue references,
file replacement, recovery limits, and GUI upload through actual ACP staging.
