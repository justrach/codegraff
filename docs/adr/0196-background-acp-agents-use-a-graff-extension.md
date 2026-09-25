# 0196. Background ACP workers use a Graff extension

Status: accepted 2026-09-24

## Context

The draft ACP child-session update expects the child to terminate before its
parent prompt returns. A detached Graff worker can continue through later
parent turns. The draft update would either close that worker too early or send
activity outside its defined lifetime. The current child activity snapshots
are bounded and cannot provide complete historical ACP replay.

## Decision

Keep draft `subagent_update` for negotiated foreground children. A client may
separately request `clientCapabilities._meta["graff/backgroundSubagents"] = true`.
Graff advertises this extension in `agentCapabilities._meta` and, only for
opted-in clients, sends `graff/subagent_event` notifications for detached
children. Each notification carries parent session, child session, parent tool
call, and a per-child sequence number. Spawn precedes semantic activity, and a
terminal state follows it. The ACP connection owns the output lock across
prompt boundaries and detaches the worker emitter before closing stdout.

## Consequences

Clients can render a live background child without treating the parent prompt
as the child's lifetime. Standard ACP clients continue to see the parent tool
call and result. This extension currently streams only while the ACP process
is connected; a reconnect must use the bounded `graff/agents` snapshot and
report truncation rather than claim exact draft child-session replay.
