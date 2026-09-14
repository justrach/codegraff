# 0111. Peer inbox retains bodies and reports loss

Status: accepted

## Context

The pull inbox stored clipped previews, silently evicted older messages, and
cleared unread state even when allocating the read result failed (#865).
A successful-looking read could therefore omit instructions or entire messages.

## Decision

- Keep the eight-message ring and advisory, bounded history wake from ADR 0004.
  Store owned, complete sender and body strings independently of delivery arenas.
  Only the wake may abbreviate a sender; inbox reads preserve message bytes.
- Count evictions and messages that cannot be allocated. Include the count in
  wakes and reads, and retain existing entries if allocating a new one fails.
- Build the entire inbox result before clearing entries or loss counts. A failed
  read returns an error and leaves the mailbox available for retry.
- Persist the loss count beside the existing `peer_inbox` array and include it
  in the save fingerprint. Legacy snapshots default to zero; oversized restored
  arrays add their evictions to the saved count. Resume wakes for loss-only state
  too. One-shot sessions continue to discard the mailbox (ADR 0014).

## Consequences

Memory remains bounded by message count rather than fixed preview bytes; long
messages cost more memory but remain readable. Evicted bodies remain in the
room log, not an unbounded in-memory queue. This preserves the pull design
without silently presenting a partial mailbox as complete. Old snapshots cannot
recover text already clipped before saving.
