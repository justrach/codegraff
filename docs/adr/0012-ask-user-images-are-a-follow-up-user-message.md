# 0012. ask_user images are a follow-up user message

Status: accepted 2026-08-20

## Context

#580: the clarification UI accepted screenshots, but `ask_user`'s tool
result was literal `[Image]` placeholders. Responses `function_call_output`
and OpenAI `role:tool` content are strings. Anthropic `tool_result` can
carry image blocks, but a shared shape that works on every wire is a
user message with the same vision blocks a normal prompt already builds.

Putting base64 in `function_call_output.output` would also blow the
Responses 16k output cap (#95's sibling) and the per-output handle contract.

## Decision

- Stage every successful paste/drop/`@[path]` on a 16-slot queue (the last
  image still fills `pending_image` for history nav).
- `ask_user` returns text only. After that tool result is appended,
  `vision_queue.flushPending` adds one user message with the queued
  image blocks, same builder as the main prompt.
- If the reply has `[Image]` markers and the queue is empty, the tool
  result names path / paste-text / next-prompt fallbacks instead of
  implying the pixels arrived.

## Consequences

The next model request sees the text result and the pixels. Compaction
must keep that follow-up (and the opening user prompt of an unresolved
turn) verbatim — see #581. Revisit inlining images into Anthropic
`tool_result` only if a provider rejects the extra user message.
