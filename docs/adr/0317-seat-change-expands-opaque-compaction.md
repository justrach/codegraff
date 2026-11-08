# 0317. A seat change expands opaque compaction state

Status: accepted 2026-11-08

## Context

A server compaction item is ciphertext. It decrypts for the backend that
minted it, and nothing in the item lets us tell whether the next seat can read
it. A provider or model switch used to keep that item and replay it, so a
valid conversation could be rejected with `invalid_encrypted_content` purely
because the ciphertext belonged to the previous seat. The history was never
wrong; only its provenance had moved.

The switch path already handled the wire-format case: translate the history,
or clear it. A same-format switch — another provider speaking Responses, or a
different model on the same one — walked through untouched, which is the case
that broke.

## Decision

Before a switch reaches the new seat, expand the newest opaque item back into
the exact input it was compacted from (the checkpoint 0316 already retains)
and drop the window fingerprint so it cannot be replayed.

Same-seat switching is untouched. A history with no opaque item is untouched.
A session with no checkpoint is left exactly as it is — the bounded recovery
path reports the blocked state rather than guessing.

This reaches the end state codex arrives at by stamping a compaction with the
producing model and re-compacting when that hash changes; it matches the rule
`subagent_history_copy` already enforces for forks, where a changed seat
refuses to carry an opaque window.

## Consequences

A switch after compaction costs a re-expansion of history the checkpoint
already holds: local disk read plus parse, no extra model call. The turn that
follows sees real messages, so the new seat can compact again in its own
terms, and the switch notice says the context was expanded rather than kept.

The protection is only as good as the checkpoint. State predating 0316, or a
checkpoint that is missing or corrupt, still fails closed: one rejected
request, history unchanged, and an explanation. That is the honest outcome —
nothing here can make a blob decrypt that the backend will not accept, and
dropping the item instead would silently destroy the conversation it *is*.

Revisit if a provider exposes a way to identify the encryption scope of an
opaque item, which would let the expansion be skipped when the seat did not
actually change.
