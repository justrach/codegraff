# 0307. Resumed sessions keep their compaction-state count

Status: accepted 2026-10-29

## Context

A Responses compaction item carries opaque encrypted state. Its byte size is a
poor proxy for its token cost, so graff estimates it at bytes/16 until the
provider counts a full request carrying it; that count then replaces the
estimate (#1686, `opaque_state_usage.zig`). The count lived only in
process-global slots in `context_tokens.zig`.

A new process restoring the same session therefore went back to bytes/16. In a
controlled reproduction, an 8,000,000-byte state counted at about 80k tokens
was restored as about 508k in a 270k window. The ACP meter showed 188%, and the
next ordinary prompt paid for a forced compaction that the warm process did not
need. Saving the paired meter counters was not enough, because restore
recomputes the local component without the count.

## Decision

The session file records the count as `opaque_state_count`:

- `provider` and `model` the count was made under,
- `state_bytes`, the history's total compaction-state size (the calibration key),
- `state_digest`, an order-independent digest of every state blob, in hex,
- `tokens`, the provider's count for that state.

It is written only when the process has a count for the saved history's state.
`loadSession` reapplies it before rebasing the context meter, and only when the
restored history has the same size and digest and the session's provider and
model match. A changed state, a different model or provider, or a missing or
malformed record leaves the bytes/16 estimate in place.

The count is learned from every Responses reply that carries usage, chained
or not. With `previous_response_id` (the WebSocket delta, chatgpt-new's
default transport) OpenAI bills every earlier input token in the chain as
input, so `input_tokens` covers the whole context, which is how graff's meter
and Codex's own occupancy already read it. Learning only from unchained
requests left a WebSocket session uncounted until a compaction forced a full
resend, so its reload still fell back to bytes/16.

## Consequences

A resumed session reports the occupancy the provider last counted, and does not
compact solely because the process restarted. Genuine overflow protection is
unchanged: the compaction threshold and the near-limit gate still apply to the
restored estimate, and history added after the count is still counted locally.
Sessions saved before this change, or whose state was never counted, restore as
before and recalibrate on their next full request.
