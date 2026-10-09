# 0271. Gemini continues the stored Interaction instead of replaying history

Status: accepted 2026-10-08

## Context

The direct Google provider speaks the Interactions API. graff sent
`store:false` and the whole step list on every request, re-uploading the
conversation each call. The endpoint can hold the conversation itself: a
request that names a stored Interaction in `previous_interaction_id` sends only
the steps added since, and Google recommends that path for implicit caching of
the history.

On such a request the flat usage totals (`total_input_tokens`,
`total_cached_tokens`) cover only the new steps, while
`model_invocation_token_counts` and `raw_prompt_token` report the whole prompt
the model read and the part served from cache. Google documents the continued
history as input, so graff meters the whole prompt.

The earlier writer skipped this because the id had to stay consistent with
graff's own history through compaction, trims and edits.

## Decision

Interactions requests are stored (the endpoint's default) and continue the last
stored Interaction whenever graff's history is a clean extension of what the
server holds. `interactions_chain.zig` owns the rule:

- When an answer arrives, graff records its id, how many messages the server
  now holds, and a hash of those messages' wire form.
- A request chains only if the same prefix still hashes the same under the
  same model and there is at least one new step to send. Anything else — a
  /clear, a rewind, a compaction or trim, an in-place edit of an earlier step,
  a model switch, a message appended while a request was in flight — sends the
  full history, which anchors a new chain.
- A chained request the endpoint rejects (expired or unknown id) is resent once
  with the full history.
- `system_instruction`, `tools` and `generation_config` are sent on every
  request, as the endpoint does not carry them over.
- Usage reads the per-invocation counts (`promptUsage`): the context meter and
  the cost both use the whole prompt, with its cached part at the cache rate.

`GRAFF_INTERACTIONS_STORE=0` (or off/false/no) restores the stateless shape:
`store:false` and a full replay on every request.

## Consequences

Long Gemini sessions stop re-uploading their history, and the server-held prefix
stays stable for implicit caching (a 107k-token stable prompt read 102,400
tokens from cache). Interactions are now retained by Google under its
storage policy; users who must not have that set `GRAFF_INTERACTIONS_STORE=0`.
Hashing the history costs one serialization pass per request, which the full
replay already paid.

The same change brings the wire in line with what Gemini 3 supports:

- `tool_choice` is `validated` (auto with constrained decoding of calls), and
  `any` when a tool is forced.
- `thinking_level` is never `minimal`, which Gemini 3.1 Pro and 3.7/3.8 Flash
  reject; the lightest effort sends `low`.
- `thinking_summaries: "auto"` is sent explicitly (without it no summaries
  stream, despite the documented default), and `thought_summary` deltas feed
  the reasoning panel.
- Requests with tools on `gemini-3.1-pro-preview` go to
  `gemini-3.1-pro-preview-customtools`, Google's variant that prefers the
  harness's own tools over shell, at the same price. The chain keys on the wire
  model, so a request without tools on the other variant replays in full.
- Chat-shaped user/assistant text turns that shared paths append (the
  REPL/--json/ACP user turn, interrupt markers, the compaction request) are
  rewritten as `user_input` / `model_output` steps before each send
  (`history_wire.prepare`); the endpoint rejected the whole request on one, so
  only `-p` worked on this provider.
