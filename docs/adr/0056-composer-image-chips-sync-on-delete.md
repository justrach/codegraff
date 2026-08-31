# 0056. Composer image chips sync on delete; paste traces wait for send

Status: accepted 2026-08-31

## Context

#634 already drops composer pixels at submit if the chip is gone. The
line composer still numbered the next `[Image #N]` from the unpruned
queue, so deleting `#1` and pasting again showed `#2`. Staging also
wrote `clipboard_paste` with MIME and byte count immediately (#350),
so an abandoned draft left content-derived metadata in `.graff/traces`.

## Decision

Deleting a composer chip drops that queue slot and remaps remaining
`#N`s to 1..k. The next paste reuses the next live number. A successful
stage records `clipboard_paste` without MIME or bytes; those fields
are written only when the image is actually sent. Failures may still
carry a size. `/image` and `/paste` stay sticky (not composer chips).

## Consequences

#350 still has a receipt for every paste attempt. Abandoned drafts no
longer disclose what was staged. TUI already numbered from its live
array; the line REPL now matches.
