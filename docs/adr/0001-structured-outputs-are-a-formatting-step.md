# 0001. Structured outputs are a formatting step, not a decoding constraint

Status: accepted 2026-08-15

## Context

`--output-schema` (#502) originally applied the strict schema grammar to
every message in the session. On grok-4.6 the grammar pulled the model into
answering immediately in the required shape instead of using its tools
first: on the graff-evals file-inspection task it guessed a plausible answer
without opening the file, and the schema task passed 1/3. Constrained
decoding during the agentic phase suppresses exactly the tool-use behavior
that makes answers correct. Two related findings from the same work:
grok-4.6 leaks a literal `<|eos|>` after strict-schema JSON (now stripped),
and structured output adds no accuracy on its own; identical answers arrive
with or without it.

## Decision

- The agentic phase always runs unconstrained. No schema grammar, response
  format, or text format is attached to any turn that may use tools.
- When a schema is requested, it is satisfied by one final tools-off,
  low-effort formatting turn in the same conversation that restates the
  answer the agentic phase already produced (the two-phase one-shot in
  `src/session_run.zig`).
- `--output-schema` is not a default and should not be reached for
  reflexively. Use it when a program consumes the result (pipelines, evals,
  SDK callers) and skip it when a human reads the answer.

## Consequences

- Task accuracy is unaffected by requesting a schema: the schema task went
  3/3 after the split (re-confirmed 3/3 on the v0.0.258 release build), and
  the answer content matches the unconstrained run.
- Machine consumers get guaranteed-parseable output with no prose preamble,
  which is why graff-evals grades by exact value and why this is a
  capability edge over harnesses without schema support.
- Cost when used: one extra cheap turn (tools off, low effort), a few
  seconds and a few hundred tokens.
- Revisit if a provider ships constrained decoding that provably preserves
  tool-use behavior mid-session; until then, any change that attaches a
  grammar to intermediate turns is a regression, not an optimization.

Evidence: #502, `graff-evals/tasks/10-schema-output.json` (the task that
caught both bugs), the two-phase block in `src/session_run.zig`.
