# 0358. A failed child's terminal frame says why

Status: accepted 2026-11-27. Extends 0194, 0196 and 0205.

## Context

When a child agent failed, an ACP client was told that it failed but, in two
of the three delivery modes, not why. The last progress row (0205) said
"✗ failed" with `_meta["graff/subagent"].state = "failed"`; the draft
`subagent_update` (0194) carried only `state`; the background
`graff/subagent_event` terminal event (0196) was `{type, state}`. The cause
reached the client only through the parent tool's failed result, which a
foreground child has and a detached child does not: its spawn call already
completed. For a detached child that failed, no reason existed anywhere on
the wire. The engine had it (`subagent_run.subagentFailure`, `classifyFailure`).

## Decision

- A child that ends `failed` or `cancelled` adds two fields to its terminal
  frame: `reason`, one line of text, and `failureKind`, the machine-readable
  class (`subagent_run.FailKind` tag: `quota`, `transport`, `model`,
  `invalid`, `auth`, `budget_exhausted`, `cancelled`, `synthesis_limit`,
  `unknown`). `failureKind` is omitted when nothing classified the end (a run
  that returned an empty report).
  A run that returned an empty report says `subagent finished without a
  report`; an error that unwinds `runSub` before its outcome is recorded says
  `subagent stopped before it recorded an outcome`. A cancelled child that
  did report names the stop (`Interrupted [cancelled failure, …]`).
- Where they sit follows each frame's existing extension data: inside
  `_meta["graff/subagent"]` on the last progress `tool_call_update`; in
  `_meta["graff/subagent"]` beside `graff/parentToolCallId` on the draft
  terminal `subagent_update`; beside `state` in the background `terminal`
  event, whose fields are all Graff's own.
- `reason` is the cause and class bracket the parent's result carries
  (`<cause> [<class> failure, N attempts]`), without the "failed before
  producing a report" prefix or the retry advice. Both come from
  `subagent_reason.cause`, so they cannot drift.
- At most 280 bytes, cut on a UTF-8 boundary with `…`, keeping the bracket.
  Escapes and control bytes are removed, whitespace collapsed, and the
  redaction already used for failure text in issue bodies applied
  (`codedbpro_report.redact`: credential-looking runs, absolute and home
  paths, URL query strings; a bare `/word` slash command is no longer taken
  for a path). Text that trips the secret canary
  (`learning_privacy.scanSecrets`) is replaced by a fixed "withheld" line.
- A completed child's frames are byte-for-byte unchanged, and no running row
  carries the fields. The drafts' gates and capabilities are unchanged.

## Consequences

A client can say why a detached child failed, and a client that ignores
unknown `_meta` keys sees no difference. Standard clients that read only
`content` still see "✗ failed"; the reason is not added to the visible log.
Like 0196, the background event streams only while the ACP process is
connected: a client that reconnects after a detached child ended gets its
outcome from `graff/agents` and the later `agent_output`, not from a replayed
terminal frame.
