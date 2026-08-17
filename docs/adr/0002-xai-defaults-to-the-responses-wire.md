# 0002. xAI defaults to the Responses wire (WS + server compaction)

Status: accepted 2026-08-15

## Context

grok support (#502) landed with the Responses wire behind
`GRAFF_XAI_WIRE=responses` while a harder-recall A/B decided the default.
The A/B (24 planted identifiers in ~13k-token conversations, 12 quizzed,
both compaction paths): with salience cues both arms recalled 12/12; with
facts buried as incidental asides the server blob stayed 12/12 while the
client summary dropped the earliest fact (11/12, blank rather than
hallucinated). Wall-clock and cost were equivalent per turn (blob replay
costs more input tokens than a summary but is lossless by construction).
The one blocker was #505: duplicate MCP tool definitions (a deferred server
start racing the eager codedb-pro companion) made strict Responses
endpoints reject every request; fixed alongside the flip.

## Decision

`g_xai_responses` defaults to true: xAI sessions run on
api.x.ai/v1/responses, which gives WebSocket turns (with the WS→SSE
fallback ladder), first-party server-side compaction for both
autocompaction and manual `/compact` (#503), and structured outputs.
`GRAFF_XAI_WIRE=chat` (any value other than `responses`) opts a session
back onto chat completions.

## Consequences

- Lossless compaction by default; the intent-aware client summary remains
  the fallback when the endpoint refuses or fails, and the chat wire keeps
  it as primary.
- WS eligibility stays an explicit provider list (codex, xai, and Codegraff
  when its selected alias is Responses-kind) — Platform OpenAI has no WS
  server and must never probe one.
- Chaining via previous_response_id stays codex-only: xAI's store:false +
  previous_response_id stalls server-side (probed live), so xai rides
  full-resend over the held socket.
- Revisit if xAI's wire diverges from OpenAI Responses semantics or the
  compact endpoint's blob replay pricing changes the cost picture.

Evidence: #502, #503, #505, the recall A/B kit (session scratchpad
recall-ab/), ADR [0001](0001-structured-outputs-are-a-formatting-step.md)
for the structured-outputs half of the wire.
