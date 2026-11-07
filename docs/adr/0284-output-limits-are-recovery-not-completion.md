# 0284. Provider recovery must not masquerade as completion

Status: accepted 2026-10-17

## Context

Unattended authoring stopped on output limits and exhausted empty replies.
A supervisor had neither a reliable execution result nor a resume handle,
so retrying often required filename discovery and could waste attempts on
an account failure. Existing tool-batch checkpoints preserve useful work,
but are not a write-ahead execution journal.

## Decision

Treat output-length stops as bounded in-turn continuations, preserving
partial history and requesting small complete file-writing calls. Never
execute cut tool arguments. Keep the allowance on the turn stack so tool
progress or compaction cannot reset it. Empty replies back off with jitter
and fail explicitly after exhaustion. Account billing/auth faults outrank
transient envelopes, with no blind retry into a hard cap.

One-shot `--output-format stream-json` reuses the existing event transport,
with an initial resume handle and a terminal result containing the outcome,
classified exit code, usage completeness, elapsed time and cost. Ordinary
text stdout stays compatible. Save the session before reporting the result,
including on errors. Unknown charges stay null, not fabricated zeroes.
Latch a forced tools-off final-budget landing and report budget exhaustion,
not completion inferred from its prose, even without an open checklist.
An ordinary final answer before the forced landing remains successful.
Keep startup's raw MCP exceptions behind the debug switch without hiding
configured servers from the agent. Buffered Gemini-4 generation gets a
request-local silence allowance after headers, not a process-global timeout
increase; explicit overrides and active-prose watchdogs retain precedence.

## Consequences

Recovery is bounded and may stop with partial work, but is no longer a
successful blank/truncated final. The result describes what this invocation
knows, not a proof of semantic task success or whole-run accounting across
processes. Do not claim exactly-once tools: snapshot recovery cannot decide
whether a crash after an unjournalled side effect completed it. A real
journal/replay migration needs operation-specific reconciliation rather
than hashes as an idempotency guarantee.

The offline supervisor regressions live in
`scripts/test-headless-durability.py`; the precise output contract and
remaining gaps are in `docs/headless-durability.md`.
