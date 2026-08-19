# 0013. ACP tool cards, idle job wake, and monitor

Status: accepted 2026-08-19

## Context

A grok-build comparison (same SuperGrok account, 2026-08-19) showed three
gaps that are not a second engine: ACP hosts saw only a final text blob,
background jobs that finished between turns stayed silent until the model
polled, and there was no line-stream watch distinct from `bash_output`'s
unread cursor. ADR 0010 already closed the in-turn wait. ADR 0012 said
`tool_call` streaming is a notification shape on the existing adapter.

Interrupting a blocked readline (a wake pipe on the input loop) is a
separate slice. So is mid-turn `session/cancel`.

## Decision

- ACP `session/update` emits `tool_call` / `tool_call_update` from engine
  tool events, and `agent_message_chunk` from `text_delta`. The final
  text chunk is omitted when deltas already streamed. Root tools only.
- Idle auto-wake: `popSteer` (REPL) and the next `session/prompt` (ACP)
  prepend a harness note when a job previously seen running has finished,
  or a `monitor` watch has new complete lines. Do not steal `job.cursor`.
- `monitor` is a base local tool: same pump as background `bash`, wake on
  lines, ~40 lines/wake, ~200 lifetime then `bash_kill`. Not in `--lean`.

## Consequences

Zed can draw tool cards during a turn. A `gh run watch` that exits
between prompts wakes once. `monitor` is the third background semantic
(spawn / wait-for-exit / line-watch). Revisit prompt-interrupt and
mid-turn cancel when a host needs them; do not `chdir` (ADR 0006) or
fork a second catalog.
