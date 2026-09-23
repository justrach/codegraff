# 0188. Streamed tool calls retain their explicit identity

Status: accepted 2026-09-23

## Context

A stream can reuse a numeric tool index for a later call. Merging solely by
index can concatenate two argument objects, lose their separate identities,
and prevent an otherwise complete successor from executing.

## Decision

Assemble calls by explicit call ID. An ID-less fragment continues the most
recent call at its index, while a new ID at that index starts a distinct call.
If the predecessor lacks a complete argument object, preserve it as invalid;
do not repair it with fragments from the successor. Contradictory names also
invalidate the affected call.

Only structured call and result events establish tool execution. Text that
merely resembles a command, including prose in a response, is not execution
evidence.

## Validation

`src/agent_steps_tests.zig` covers reused indexes, incomplete predecessors,
and contradictory fragments. The scripted behavior case in
`evals/harness_behavior.jsonl` checks distinct calls through the request path.
