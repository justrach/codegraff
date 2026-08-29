# 0041. The fullscreen TUI is an in-process ACP client

Status: accepted 2026-08-27

## Context

`graff acp` and `apps/native` already share one mid-turn protocol (ADR 0032):
`session/prompt` in, `session/update` thought / tool / text out. The TUI was
a sibling frontend on the same agent loop (`tui_sink` typed events), so a
tool row or thought chunk had two translations. Spawning `graff acp` from
the pager would fork a second Agent and drop the in-process seams (images,
`/debug`, idle wake, shared conversation).

## Decision

`graff tui` (and TTY `graff repl`) is an ACP **client in the same process**.
It speaks initialize / session/new / session/prompt / session/cancel through
`acp_engine` and renders thought, tools, and answer text from `session/update`.
No child `graff acp`. Live coding still uses the existing `ReplCtx` turn
(`replTurnCb`); the ACP envelopes are the client wire, not a second runtime.

TUI-only extras ACP does not name — meters, notices, raw bash tail, failover
— stay on `tui_sink`. Local slashes (`/theme`, `/model` picker, `/rewind`)
stay local. `session/request_permission` is still off (`--yolo` / unattended).

## Consequences

Zed, the native app, and the pager share one session/update vocabulary.
Do not spawn a child agent to "make the TUI use ACP." Revisit a subprocess
only if the pager and the agent must be separate binaries.
