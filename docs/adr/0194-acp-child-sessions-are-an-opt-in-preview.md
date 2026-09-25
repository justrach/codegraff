# 0194. Live ACP child sessions are an opt-in draft preview

Status: accepted 2026-09-24

## Context

ACP's proposed child-session extension is still under review. Graff already
records worker activity for process-local inspection, but those snapshots are
bounded and disappear with the parent process. They cannot satisfy the draft's
ordered `session/load` replay and orphan recovery requirements.

## Decision

Keep stable ACP behavior as the default. A client that advertises
`clientCapabilities.subagents` can receive live `subagent_update` and child
session updates only when Graff is also launched with
`GRAFF_ACP_DRAFT_SUBAGENTS=1`. Announce only foreground children that complete
within the active parent prompt. Interactive sessions default to detached
workers; `run_in_background:false` explicitly selects a foreground child on
every frontend. Detached workers remain available through `graff/agents` and
their parent tool rows. Preserve the parent tool call for clients and early failures,
with a namespaced tool name and parent call ID for exact UI correlation.

## Consequences

The preview streams child thoughts, messages and tools as they happen, with a
terminal state before the parent prompt returns. It does not yet replay child
streams on `session/load`, so it is not full conformance with the draft. Remove
the environment gate only after durable ordered replay and orphan recovery are
implemented and tested against the accepted protocol shape.
