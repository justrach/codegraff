# 0032. ACP streams mid-turn thought, tools, and text

Status: accepted 2026-08-26

## Context

`graff acp` (#375) was v0: one `session/update` `agent_message_chunk` with
the final answer. A client could not render thinking or tool use until the
turn ended. The Beautiful UI native app first spoke `graff serve` NDJSON,
which has those events, but that is a second protocol and a second process
from the editor-facing agent.

ACP v1 already names `agent_thought_chunk`, `tool_call`, and
`tool_call_update`. Emitting those from the same `--json` events the rest
of the harness already produces keeps one translation point.

## Decision

During `session/prompt`, install a translating `Io.Writer` on `root.out`
and `g_out`. `--json` lines become ACP `session/update` notifications:

| `--json` | `sessionUpdate` |
|---|---|
| `reasoning` | `agent_thought_chunk` |
| `text` | `agent_message_chunk` |
| `tool_call` / `tool_call_started` | `tool_call` (kind from the catalog name) |
| `tool_result` / `tool_call_finished` / `tool_rejected` | `tool_call_update` |

A stub turn that emits no events still writes one final
`agent_message_chunk` (the v0 contract). A live turn that already streamed
text returns `""` so the final chunk is not duplicated.

Between prompts both writers are null (stdout stays JSON-RPC). Protocol
version stays 1 for Zed (we speak the
[v1 session/update shapes](https://agentclientprotocol.com/protocol/v1/tool-calls),
not the v2 upsert). `session/cancel` sets `esc_cancel` and the prompt
result uses `stopReason: cancelled` when that latch is set. After
`session/new` the agent advertises `/never` via `available_commands_update`.
`session/request_permission` is not implemented: unattended + `--yolo` is
how a UI that wants tools from the first call runs the agent.

The native app (`apps/native`) is an ACP client via `/api/acp` →
`graff acp --yolo`. It does not require `graff serve`.

## Consequences

- Zed and the native app see the same mid-turn shapes.
- Approvals stay off ACP until we grow `session/request_permission`.
- `set_model` is not an ACP method; a model change respawns the child.
