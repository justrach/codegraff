# 0118. Interactive subagents yield the parent and wake on completion

Status: accepted 2026-09-15

## Context

Background execution alone did not free the prompt: synchronous spawn was
the default and a parent could block in `agent_output` until exit. The TUI
supported idle wakes for shell jobs, but not child results. Long-lived
children also exposed borrowed per-turn approval storage.

## Decision

Interactive direct `subagent` calls always launch background jobs. After the
tool batch settles, yield the parent without cancellation or claiming task
completion. Interactive `agent_output` is a snapshot; reading a running child
yields too. Headless calls retain ADR 0010's synchronous and wait contracts.

Finished interactive jobs carry one unread notice keyed to the spawning
session. Notices identify the job and success/failure; reports remain in
`agent_output`. Reading a finished report suppresses its wake. A full buffer
retains notices that do not fit. Deliver completions at root step boundaries
or wake an idle REPL. TUI drafts, attachments and queued input take priority;
the line editor wakes only with an empty draft. Notifications retain
provenance and do not authorize paused or superseded work. A yielded `/goal`
run does not immediately loop back into a wait.

Background jobs own approval-policy and provider-string copies. Session
services outlive the job registry. Existing child models, effort, run budgets
and feedback continue to apply.

## Consequences

Interactive direct delegation returns an id even without the background flag.
Workflow calls retain their synchronous aggregate contract. Closing the
process does not detach or persist a running child.

Unit tests cover yield, ownership, session scoping, buffer retention and
read-before-wake suppression. TUI simulator tests cover draft priority.
`scripts/eval-subagent-repl.py` holds a child open through a separate parent
turn in the real line REPL, then verifies automatic report collection.
