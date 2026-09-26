# 0205. Subagent progress streams as standard tool call content

Status: accepted 2026-09-26. Extends 0194.

## Context

ACP v1 has no subagent protocol. Its RFDs mention subagents only in passing
(the v2 prompt lifecycle, session fork, proxy chains). Graff's child-session
stream (ADR 0194) follows an unmerged proposal, so it stays behind
`GRAFF_ACP_DRAFT_SUBAGENTS=1` plus a client `subagents` capability. By default
an ACP client saw only the parent's `subagent` tool row and its final result,
while the child's work was reachable only by polling `graff/agents`.

Every ACP client already renders `tool_call_update.content`, and other ACP
agents report delegated work the same way.

## Decision

- By default, a top-level `subagent` child streams onto its parent's tool
  call: `tool_call_update` rows in the parent session whose `content` is a
  rolling log of the child's tool calls, failures, and the tail of the
  message it is writing. Tool events publish immediately; text is throttled.
- These rows carry no `status`. The parent's own tool result still completes
  or fails the call, and a detached child's spawn call stays completed.
- `_meta["graff/subagent"]` carries `{sessionId, name, state}` for clients
  that want to link the row to `graff/agents` inspection.
- The draft child-session stream replaces this when both sides opt in.
  `GRAFF_ACP_SUBAGENT_PROGRESS=0` turns the progress rows off.
- Only while the parent prompt is active, like 0194.

## Consequences

Zed, Harness and any other ACP client show what a subagent is doing with no
client change. The log is bounded (12 steps, a 280-byte message tail), so a
long child cannot flood the transcript. Progress after the parent prompt
ends is not streamed; `graff/agents` still covers detached workers then.
