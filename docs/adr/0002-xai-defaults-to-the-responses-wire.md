# 0002. xAI defaults to the Responses wire (WS; client compact)

Status: accepted 2026-08-15; compaction arm amended 2026-09-05; WS chaining on 2026-09-19; WS chaining off again 2026-09-25

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
fallback ladder) and structured outputs. Compaction does **not** use
xAI's `POST /v1/responses/compact` blob — the client summarizer
(`agent_compact.zig`) outperformed it, so `/compact` and autocompact stay
on that path. `GRAFF_XAI_WIRE=chat` (any value other than `responses`)
opts a session back onto chat completions.

## Consequences

- Grok compaction is the inspectable client summary on both the Responses
  and chat wires. xAI's compact endpoint remains in the tree unused
  (`xai_compact_url`); do not wire it back without a new recall A/B.
- WS eligibility stays an explicit provider list (codex, xai, and Codegraff
  when its selected alias is Responses-kind) — Platform OpenAI has no WS
  server and must never probe one.
- xAI WS chaining is off by default (`GRAFF_XAI_WS_CHAIN=1` opts in). The
  published contract says `previous_response_id` + delta input works on the
  held socket with store:false via the per-connection cache. Live, a chained
  store:false `response.create` gets one frame and then nothing until the
  stall watchdog fires (about two minutes), both after a normal turn and after
  a `generate:false` warmup; the same requests with store:true complete in
  seconds. graff sends store:false, so every chained turn stalled and paid a
  re-anchor. Unchained turns (full input every turn) are unaffected. When on:
  a not-found, 25-minute cap, or drop re-anchors with full input
  (append-only history; compact rewrites drop the chain). Turning it back on
  needs a live probe showing store:false chaining completes.
- The `generate:false` warmup (prewarm) is off by default for every provider
  (`GRAFF_WS_PREWARM=1` opts in). It runs after the user's prompt, in series,
  and measured slower on turn 1 than a cold turn, with no turn-2 gain.
- Revisit if xAI's wire diverges from OpenAI Responses semantics or the
  compact endpoint's blob replay pricing changes the cost picture.
- Hosted `x_search` rides this wire by default (ADR
  [0031](0031-xai-hosted-x-search.md)); chat completions cannot host it.

Evidence: #502, #503, #505, the recall A/B kit (session scratchpad
recall-ab/), ADR [0001](0001-structured-outputs-are-a-formatting-step.md)
for the structured-outputs half of the wire.
