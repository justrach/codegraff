# 0145. GPT-5.6 reasoning replays from local history; `reasoning.context` and pro mode are not sent

Status: accepted 2026-09-21

## Context

GPT-5.6 (`gpt-5.6` → `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`) adds
`reasoning.context` (`auto | all_turns | current_turn`, default `all_turns` on
5.6, `current_turn` on earlier models) and `reasoning.mode: "pro"` on the same
model slug. With `all_turns` the API wants prior reasoning carried forward:
either continue with `previous_response_id`, or resend every output item —
including encrypted reasoning items when `store:false`. It also accepts
`reasoning.effort` up to `max`, and may pause a stream for several seconds
mid-generation for classifier review.

Graff already sends `store:false`, includes `reasoning.encrypted_content`, and
appends every Responses output item to history verbatim; a full rebuild
re-sends that history, and the Codex/xAI held-socket path chains on
`previous_response_id` with only the delta. Reasoning items therefore reach
the model on every turn without any new field. Effort is part of the cached
prefix and only moves on an explicit `/effort` or worker pin (see the header
of `effort_route.zig`); OpenAI's maximum is shown as Ultra and wired as `max`.

## Decision

- Do not send `reasoning.context`. The default (`all_turns` on 5.6) matches
  what graff replays, and pinning `current_turn` would drop reasoning the
  history already carries. The field is understood as an echo on
  `response.completed` and nothing else. Revisit only with a measured win
  from `current_turn` on a stale-reasoning workload.
- Do not send `reasoning.mode`. Pro mode is a session-wide, billed opt-in that
  must land on the REPL, TUI, and GUI together (a live control, persisted
  setting, and SDK/ACP surface); a wire-only flag is a half feature.
- Keep `max` as the ceiling of the effort ladder for the family (picker tag
  Ultra), default `medium`, `xhigh` between. `none` is not exposed.
- Unknown Responses output items (`program`, `program_output`, program-issued
  `function_call`s) are kept as opaque history so `call_id`/`caller` pairing
  survives; Programmatic Tool Calling itself is not implemented.
- Stall budgets stay as they are: a several-second safety pause sits well
  inside the 30s between-lines budget (15s floor) and the 45s head ceiling.
- The model note in `prompt_guidance.zig` states the autonomy/approval
  boundary once and carries no brevity rule; the model is already concise.

## Consequences

Every rebuild replays encrypted reasoning bytes, which is the cost of
`all_turns` without server-side storage; the held-socket delta avoids it
where a chain exists. A future pro-mode toggle is one field on the request
builder plus the three-surface control; the capability gate is
`prompt_guidance.isGpt56`. If OpenAI changes the `all_turns` default, graff's
behavior is unchanged because it never relied on the server default.
