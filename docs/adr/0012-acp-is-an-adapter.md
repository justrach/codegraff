# 0012. ACP is an adapter over the existing agent loop

Status: accepted 2026-08-19

## Context

#375 asked for ACP (Zed's editor↔agent JSON-RPC) as a thin adapter, not a
second engine. `graff acp` shipped in v0.0.236: one live session, same
`runTurnWithFallback` as `-p`, stdout locked to protocol JSON. That was enough
to speak the handshake. It was not enough to *see* a turn.

A same-account cache check (2026-08-19, SuperGrok OAuth, grok-4.6 vs
grok-4.6-build) showed why the protocol shape matters: grok ACP in one process
held 99%+ cache after turn 1; `grok -p`/`-c` (new process each turn) wobbled
40–98%. Graff's in-process append-only history already has that property.
Clients could not read it: v0's `session/prompt` result was only
`{stopReason:"end_turn"}`. grok puts the useful numbers on ACP
`updates.jsonl` / PromptResponse `_meta`; the official v1 home is
[PromptResponse.usage](https://agentclientprotocol.com/rfds/end-turn-token-usage).

A second loop, a grok-sized catalog, or process-wide `chdir` on `session/new`
`cwd` would look like "more ACP" and would bust the prefix or fight the
workspace tool (ADR 0006).

## Decision

- `graff acp` stays an adapter over the existing Agent. Do not fork a second
  turn engine, tool catalog, or prompt-cache key for editors.
- `PromptResponse.usage` is the per-turn `CostTally` delta. `inputTokens` is
  the full prompt (ordinary + cache-write + cache-read), matching grok ACP
  and `--json` `input_tokens`, not `--json` `uncached_input_tokens`.
- Session context (`used`/`size`) and cumulative `$` go on `session/update`
  `usage_update`. Do not fold those into `usage`.
- Accept string `protocolVersion` values (`"1"`, `"2025-11-25"`, `"0.1"`).
  Advertise integer `1`.
- `session/new` `cwd` is ignored. Do not `chdir`.
- `session/cancel` is acknowledged; an in-flight turn is not aborted until
  the stdio loop can read while a turn runs.

## Consequences

Zed and other ACP hosts can show cache hits without speaking `--json`.
`tool_call` / `tool_call_update` and streamed `agent_message_chunk` landed
in ADR 0013. Revisit mid-turn cancel, client fs/permission callbacks, or
`session/load` when a host needs them — each is a notification shape on
this adapter, not a new agent.
