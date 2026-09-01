# 0060. Named-source gate is per unanswered mention

Status: accepted 2026-09-01

## Context

`named_work` appends a user-role nudge when the prompt names a source
file and the model answers without tools. `handle` also walked every
string in history (`conversationNamesSource`). After a successful
read, `SPEC.md` was still in an earlier message; the next turn reset
`named_work_nudges` and fired again.

Separately, `repl_convo.adopt` always appended the frontend's trailing
user row. A host that re-submitted the same prompt injected another
user turn. Combined with the gate, the session replayed the same Q&A
until the human interrupted (#714).

## Decision

The gate keys on **this turn's** user text only (`latestUserText` /
`remembered_task`), including Responses `input_text`. Once that
mention is nudged or tools run, it is settled; a later turn must name
a different path.

`adopt` and the mainloop/ACP inject path skip a user payload that
already is the latest user text. After three identical injects, fail
closed and print `stuck replay`.

## Consequences

A greeting after a file question does not re-open the file. A
literal identical re-ask after an answer is treated as replay (rephrase
to run it again). The history-wide walk stays as a test helper only.
