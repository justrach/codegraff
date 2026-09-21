# 0148. A mid-stream provider "internal error" is a transient 500, not overflow

Status: accepted 2026-09-21. Reverses the `#1019` classification.

## Context

xAI (grok-4.6 on the Responses wire) sometimes ends a streamed response with a
`type:error` frame whose message is `Internal error during token parsing`.
`#1019` read that as the tokenizer rejecting an over-window prompt and put
`"during token parsing"` in the overflow table, with a matching carve-out so
the gateway-flake ladder would never retry it. The remedy was emergency-trim
and resend.

The frame does not behave like an input-size rejection:

- It arrives after the model has already streamed output text, on requests
  well under the advertised window. A rejection for size arrives before any
  output, with no partial answer.
- Trim-and-resend hit the same error again; resending the same body sometimes
  succeeded. Both are the signature of a server-side fault, not a size limit.
- The provider's own reference harness classifies a streamed `error` /
  `response.failed` as a retryable HTTP 500 with bounded backoff, discarding
  the partial output; "token parsing" is not in its context-length list.

Treating it as overflow had a second cost. `applyOverflowRecovery` pins the
context meter to the window before it decides whether it can trim (`#174`), so
the between-turn compaction still engages after a genuine rejection that
returned no usage. On a misclassified frame in a small conversation there was
nothing to trim, the pin stayed, and the next turn force-compacted a
conversation that was nowhere near the window.

## Decision

- A streamed provider "internal error" that lands after output began is a
  transient server error. It rides the bounded transient ladder in
  `agent_gateway_retry.zig` (3 attempts, 1·2·4 s backoff), with partial text
  cleared and, on the WS arm, the socket already retired so the rebuild
  reconnects with full input. The user sees
  `[provider error mid-response — retrying in Ns (i/3)]`; the overloaded
  wording is kept for overloaded cases.
- Overflow classification requires a size or length phrasing, or a structured
  overflow code. An "internal error" with neither is never overflow, whatever
  else the message says.
- The context meter is pinned only on a real overflow rejection. The pin-first
  order in `applyOverflowRecovery` is unchanged: for a genuine overflow that
  cannot trim in-turn (a compaction summary request, a second overflow after
  one trim, nothing left to drop) the pin is what lets the outer
  `compactOrRecover` path recover, and existing tests hold it there. Removing
  the misclassification removes the stale pin.

## Consequences

A transient mid-stream fault costs one to three resends of the same body
instead of a destructive trim, and a repeat surfaces as the provider's own
error text after the ladder is spent. A real xAI over-window rejection still
classifies through `"maximum prompt length"`. Tier 2
`midstream-provider-error-retries-not-trims` scripts the frame after text
deltas and asserts a retry, a `text` event with the retry line (ACP renders it
as `agent_message_chunk`; a bound TUI sink gets `session_notice`), no error
event, no partial text in history, and no extra compaction call on the following
turn. ACP has no replace/reset update, so a client that already painted the
first stream will append the retry. If xAI ever returns this message
for an oversized prompt before any output, add a size-bearing phrasing to the
overflow table rather than reinstating this needle.
