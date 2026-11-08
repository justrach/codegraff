# Message types in session history

The `messages` array of a session file (see [session-format.md](session-format.md))
holds the conversation in the **wire shape of the session's provider**. graff
does not keep a provider-neutral form: what a request sent and what the
provider returned are appended as-is, and resume restores them verbatim
(`session.zig::queueSave`, `session.zig::loadSession`).

The shape is chosen by the provider's `Kind` (`provider.zig`):
`anthropic`, `openai` (Chat Completions), `responses`, or `interactions`.
The `provider` field of the session file decides which one applies; restoring
under the same provider id guarantees the same kind. A history moved to a
different kind (a model switch, or an imported session) is translated first
(`history_translate.zig`, `adopt_conversation.zig`).

Text content written by graff is always a JSON string and always valid UTF-8
(`messages.zig::sanitizeUtf8`, `messages.zig::sanitizeMessagesUtf8`). An
empty tool result is written as `(no output)` (`messages.zig::empty_result`).

## Common: role-shaped text

`messages.zig::textMessage` builds the plainest message, used for typed
prompts, harness notes, and compaction summaries on every wire:

```json
{ "role": "user", "content": "text" }
```

`role` is `user`, `assistant`, `system`, or `developer` depending on the
caller. Responses and Interactions histories rewrite these into their typed
items before sending (below).

## `openai` (Chat Completions)

| Message | Shape | Code |
|---|---|---|
| User prompt | `{ "role": "user", "content": string }` | `messages.zig::textMessage` |
| User prompt with images | `{ "role": "user", "content": [ {"type":"text","text":…}, {"type":"image_url","image_url":{"url":…}} ] }`; the URL is a `data:` URL for inline images | `vision.zig::imageMessages` |
| Assistant reply | `choices[0].message` from the response, echoed verbatim. `content` may be `null`; `tool_calls[]` entries carry `id` and `function: { name, arguments }`, where `arguments` is a JSON-encoded string | `agent_chat_step.zig` |
| Tool result | `{ "role": "tool", "tool_call_id": string, "content": string }`; an error result has `[error] ` prepended to the content | `chat_message.zig::toolResult` |

An assistant reply cut off at the length limit with neither content nor tool
calls is not added to history (`agent_chat_step.zig`).

## `anthropic` (Messages)

| Message | Shape | Code |
|---|---|---|
| User prompt | `{ "role": "user", "content": string }` | `messages.zig::textMessage` |
| User prompt with images | `content: [ {"type":"text","text":…}, {"type":"image","source":{"type":"base64","media_type":…,"data":…}} ]`, or a `source` of `{"type":"url","url":…}` | `vision.zig::imageMessages` |
| Assistant reply | `{ "role": "assistant", "content": [blocks] }`, with the response's `content` blocks kept verbatim (`text`, `thinking`, `tool_use` with `id`, `name`, `input`, …) | `agent_steps.zig::stepAnthropic` |
| Tool results | One user message per tool batch: `{ "role": "user", "content": [ {"type":"tool_result","tool_use_id":…,"content":string,"is_error":true?} ] }`; `is_error` appears only on errors | `messages.zig::toolResultMessage`, `agent_steps.zig` |

A safety refusal (`stop_reason: "refusal"`) ends the turn and is not added to
history (ADR 0219). Sessions imported from another agent's transcript use this
shape and are marked `imported_from: "claude"`.

## `responses` (OpenAI Responses)

Every object in the response's `output` array is appended verbatim
(`agent_steps.zig`), so history holds Responses items:

| Item `type` | Notes |
|---|---|
| `message` | Assistant text: `{ "type":"message", "role":"assistant", "content":[{"type":"output_text","text":…}] }`. |
| `function_call` | `call_id`, `name`, and `arguments` as a JSON-encoded string. |
| `reasoning` | Opaque reasoning item, may carry `encrypted_content`. |
| `compaction`, `compaction_summary` | Server compaction state. Opaque; `canonical_compaction` in the session file fingerprints the latest one (`compaction_window.zig`). |
| `tool_search_call`, `tool_search_output`, `web_search_call` | Hosted server-side items, kept for replay but not dispatched (`codex_tool_search.zig::isServerSideItem`). |

graff adds:

| Item | Shape | Code |
|---|---|---|
| User prompt | `{ "role": "user", "content": string }` when appended. History normalization (on restore and before a request) rewrites a `user` or `assistant` string message to `{ "type":"message", "role":…, "content":[{"type":"input_text" or "output_text","text":…}] }` | `messages.zig::normalizeResponsesHistory` |
| User prompt with images | `content: [ {"type":"input_text","text":…}, {"type":"input_image","image_url":string} ]` | `vision.zig::imageMessages` |
| Tool result | `{ "type":"function_call_output", "call_id":…, "output":string }`. No error flag on this wire. Overlong output is truncated on send and on restore | `messages.zig::toolResultMessage`, `messages.zig::normalizeResponsesHistory`, `history_wire.zig::prepare` |
| Loaded-tool announcement | `{ "type":"additional_tools", "role":"developer", "tools":[…] }` | `additional_tools.zig` |

## `interactions` (Gemini Interactions)

Every entry is a typed step; the response's `steps` are appended verbatim,
because the thought signature they carry is validated by the endpoint
(`interactions_steps.zig::step`).

| Step `type` | Shape |
|---|---|
| `user_input` | `{ "type":"user_input", "content": string or [parts] }` (`userInput`) |
| `model_output` | `{ "type":"model_output", "content":[{"type":"text","text":…}] }` (`modelOutput`) |
| `function_call` | `id`, `name`, and `arguments` as a JSON object (not a string). |
| `function_result` | `{ "type":"function_result", "call_id":…, "name":…, "result":[{"type":"text","text":…}] }` (`functionResult`); an error has `[error] ` prepended when built by `fallbackResult` |

Image parts are `{ "type":"image", "data": base64, "mime_type": … }`; a
remote image URL rides as a text part (`imagePart`). Role-shaped messages are
rewritten into `user_input` / `model_output` steps on restore and before each
request (`interactions_steps.zig::normalizeHistory`).

## Harness notices

Some messages are written by graff rather than a person. They carry a
provenance key, `_graff_origin`, which is saved in the session file but
stripped from every request (`session_wake.zig::origin_key`,
`session_wake.zig::writeWire`).

| `_graff_origin` | What it is | Shape | Code |
|---|---|---|---|
| `notification` | One-line notice: finished job, schedule, channel wake | user text (a `user_input` step on Interactions) | `session_wake.zig::message`, `session_wake.zig::typedMessage` |
| `hot_context` | Mid-session instruction-file or date update, as a keyed `<context>` message (ADR 0208) | text with role `developer` on Responses, `system` on Chat, `user` on Anthropic and Interactions | `hot_context.zig::roleFor` |
| `additional_tools` | Loaded-tool announcement on wires without the `additional_tools` item | text with role `user` (or `system` on some routes) | `additional_tools.zig` |

These are not counted as human turns (`session_wake.zig::isNotice`,
`session_peer.zig::isHumanUserTurn`), so they never become the session title.

Peer-channel wakes (user text starting with `[peer]`, `[presence]`, and
similar markers) live in memory only. They are removed before saving
(`session_peer.zig::messagesForSave`, `peer_context.zig::isPeerInject`) and
rebuilt from `peer_inbox` on load.
