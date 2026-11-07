# 0282. The Claude system breakpoint closes before the per-repo context

Status: accepted 2026-10-13

## Context

On the Anthropic API graff sent the system prompt as one text block with the
cache breakpoint on it (ADR 0220), so the cached prefix was tools + the whole
system prompt. The project layout sits near the end of that prompt (and the
project-instructions block before it), so two repos shared none of it: the
first request in any new repo wrote the full ~10k-token prefix at 1.25x.

Measured on Claude Sonnet 5.5 against Claude Code (graff-evals, 13 Oct):
request dumps of two tasks differed only in the layout lines, and each new
task's first call wrote ~10k tokens. That was most of graff's
`refactor-rename` cost ($0.031 vs Claude Code's $0.024), whose static prefix
is shared across every session.

## Decision

On Claude, the system prompt goes as two text blocks with the same bytes. The
first ends where the per-repo blocks begin (the blocks ADR 0243 moves on
Responses: the project-instructions section and the layout) and carries the
breakpoint. The second holds the rest (layout, skills, constraint ledger) with
no breakpoint; the last-message breakpoint still covers it. With no per-repo
block, the prompt stays one block. Other anthropic-format providers (Kimi,
MiniMax) are unchanged.

## Consequences

A new repo's first request reads tools + instructions from the cache and
writes only its own tail: 1.2k written tokens instead of 10.1k on a task the
cache had not seen ($0.017 vs $0.033 for the session). The breakpoint count is
unchanged. Instructions that vary per session before the layout (a goal, a
mode) still split the cache there; moving those after the breakpoint is the
next step if they show up in request dumps.
