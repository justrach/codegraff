# 0330. Unified mid-task subagent steering, waiting metadata, and cross-turn ACP progress

Status: accepted 2026-11-09

## Context

When a parent agent spawned background subagents (`subagent(run_in_background: true)`) or blocked inside `agent_output(wait_ms > 0)`, three gaps prevented the user and ACP clients from inspecting or steering the running work (`e1871e25`):

1. A background subagent's `sa-000-...` activity ID was only minted inside `runSubagentWithProgress` after the worker thread booted, while `AgentJob` only knew its numeric `id` (`1, 2, ...`) and `label`, so `agent_message` and ACP `graff/agents` could not address the same worker by `id`, `sa-...`, `task-N`, and `label` from spawn time, and foreground subagents had no steering inbox at all.
2. Once a parent `session/prompt` returned `end_turn` while background subagents kept running, `acp_subagent_live` dropped `active` to `null` and stopped emitting `tool_call_update` progress with `_meta["graff/subagent"]`.
3. Unlike `bash_output` (ADR 0262), `subagent.agentOutput` did not break its blocking wait loop when `job_wait.followup_pending` was set by a mid-turn user prompt.

## Decision

- `subagent_spawn_job.spawnSubBackground` pre-mints the subagent ordinal and `sa-...` `sub_id` onto `job.feedback` before spawning the thread and returns `sub_id` in the spawn receipt alongside `agent_id`, `task_id`, and `label`.
- `subagent_run.runSubagentWithProgress` attaches a steering `Inbox` to both foreground and background subagents and registers every live subagent in `subagent_steer`. Users and ACP clients can steer any running subagent mid-task via `@agent-<id> <msg>`, `@sa-... <msg>`, `/workers send <id> <msg>`, `agent_message`, or ACP `graff/agents` (`action: "steer"`, live-answered during active turns in `acp_inbox.tryLiveAgents`).
- `background_wait.labelNamed` names running subagents in the REPL standing bar (`agent 1 (Scout)`), and `background_wait.writeAcpWaiting` emits ACP `session_info_update` notifications with `_meta["graff/waiting"] = { text, wakes, jobs, agents }`.
- `acp_subagent_live` falls back to `BackgroundState`'s persistent session writer when `active` is `null` so detached background subagents stream `tool_call_update` progress across turns.
- `subagent.agentOutput` checks `job_wait.followup_pending` in its wait loop and yields immediately when a user follow-up arrives.

## Consequences

Running subagents and tasks remain visible, stream progress across turns on ACP, and accept mid-task steering by numeric ID, `sa-...` ID, or label from both the REPL and ACP clients without interrupting the parent turn.
