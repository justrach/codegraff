# 0149. Child briefs are structured sections plus a harness environment header

Status: accepted 2026-09-21

## Context

`subagent` composed the child's first user message from a single `prompt`
string. Parents re-typed working directory, instructions file, disabled
tools, and pre-tool hooks — or omitted them — and children re-derived
paths and observed facts the parent already had. Reports came back in
whatever frame each child picked. The system prompt asked only for a
concise report of concrete facts.

## Decision

Optional `context`, `established_facts`, `scope`, and `deliverable` on
the `subagent` tool render as headed sections around `prompt` (empties
omitted; a bare prompt is unchanged). `runSub` prepends a harness-stated
environment header (cwd, instructions file name, disabled-tool line,
pre_tool hooks) on every path except `judge_task`. The child system
prompt asks for Files changed / Verified / Skipped / Open questions.
REPL, TUI, and GUI share this engine path. Workflow task objects stay
`context` + `prompt` only.

## Consequences

Children see one brief shape. A parent that still sends only `prompt`
gets the environment header and the default report headings, nothing
else. Token cost is a few header lines per spawn, not a copy of
AGENTS.md. Revisiting would need a measured brief-quality eval or a
workflow-task field expansion.
