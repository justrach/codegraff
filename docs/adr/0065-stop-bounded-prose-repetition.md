# 0065. Stop bounded lexical prose loops independently of cancellation

Status: accepted 2026-09-05

## Context

A usable answer can be followed by unbounded repeated filler. Waiting for a
transport timeout cannot help while tokens continue arriving. A user should
not have to interrupt, and a harness stop must not be labelled a user action.

## Decision

Use one fixed-size lexical detector on assistant text before live delivery
and on assembled responses before final delivery/history insertion. Track
exact cycles of one to four short prose units. Require twelve consecutive
cycle matches and at least 192 matching bytes before stopping. Sentence
punctuation and newlines delimit units; transport chunk boundaries do not.

Exclude reasoning and tool arguments. Fenced blocks, indentation, numeric
or structured data, and long units break the evidence chain. Schema-bound
answers and compaction requests bypass detection. Buffered responses with
tool calls are exempt. Keep bounded evidence in memory, not an accumulating
copy of the generation.

A detected loop closes the current transport and propagates a distinct local
stop. It never sets the process-wide cancellation flag, retries the request,
or falls back to a different transport. The turn boundary saves the accepted
answer prefix with `stopped: model loop`, emits only unseen text and that
marker, and returns before completion nudges can reopen the answer. Existing
user cancellation retains its source and behaviour.

## Consequences

This is not semantic answer-completeness or off-topic detection. Novel fake
questions, changing countdowns, long repeated paragraphs, non-ASCII prose,
and repetition inside code/data may remain undetected. Deliberate repeated
plain prose can still meet the threshold; fence literal data to distinguish
it. A bounded initial run of repetition remains visible because already
streamed text is not erased. Usage may be unavailable on an early cut.

Regression coverage: `src/stream_repetition.zig`, the sibling delivery and
loopback transport tests, and `scripts/test-model-loop.py`. The scripted
check also verifies a clean subsequent turn and bounded saved history.
