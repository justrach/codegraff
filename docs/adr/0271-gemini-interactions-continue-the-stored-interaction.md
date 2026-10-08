# 0271. Gemini continues the stored Interaction instead of replaying history

Status: accepted 2026-10-08

## Context

The direct Google provider speaks the Interactions API. graff sent
`store:false` and the whole step list on every request, so a long session paid
for its full history as input on every call; implicit caching only discounted
part of it. The endpoint can hold the conversation itself: a request that names
a stored Interaction in `previous_interaction_id` sends only the steps added
since, and the endpoint reports only those as `total_input_tokens` (the whole
prompt is reported separately as `raw_prompt_token`). In a probe, a 38k-token
history continued with a short question reported 134 input tokens.

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
- The context meter reads `raw_prompt_token`, so compaction still sees the real
  window size; cost reads what was billed; the held prefix shows as a cache read.

`GRAFF_INTERACTIONS_STORE=0` (or off/false/no) restores the stateless shape:
`store:false` and a full replay on every request.

## Consequences

Long Gemini sessions stop re-sending their history, which cuts input billed per
call to roughly the new steps. Interactions are now retained by Google under its
storage policy; users who must not have that set `GRAFF_INTERACTIONS_STORE=0`.
Hashing the history costs one serialization pass per request, which the full
replay already paid.
