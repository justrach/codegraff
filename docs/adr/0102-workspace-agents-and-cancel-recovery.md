# 0102. Workspace agents, explicit Tasks, and bounded cancel recovery

Status: accepted 2026-09-11

## Context

Agent inspection needs enough room for messages without narrowing every chat.
Task updates must respect a user's decision to dismiss the sidebar. A cancelled
ACP prompt can fail to send its terminal reply, leaving every follow-up blocked.
Simply clearing the streaming flag lets late replies interfere with a new turn.

## Decision

Agents occupies the workspace beneath a shared tab strip. Chat splits stay
mounted while hidden so switching views preserves composer drafts. Each agent
recipient has its own draft and sending requires an explicit action. Tasks
visibility changes only through user controls and persists in browser storage.

Cancellation waits up to eight seconds for the same pending prompt. A prompt
that finishes remains reusable. On timeout, retire its transport, terminate the
worker, and await process exit before a replacement loads the saved session.
A worker ignoring termination is killed after a further second. Late replies
cannot clear a successor's streaming gate or deliver updates into it. Recovery
retains the workspace, session name and agent settings. Cancellation failures
remain visible to the user.

## Consequences

Recovery preserves the last saved conversation; unsaved output from a stuck
worker may be lost. The timed-out worker is not reused. Local GUI verification
uses hidden windows under ADR 0101, including the workspace layout regression;
native foreground coverage remains a separate GitHub Actions job.
