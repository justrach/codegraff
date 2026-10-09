# 0272. Compaction never summarizes tool results the model has not read

Status: accepted 2026-10-09

## Context

The pre-send gate in the turn loop compacts as soon as the context crosses the
compaction point. A batch of large tool results is what usually pushes it over,
so the gate ran with that batch still unread. The cut keeps an ~8k-token
verbatim suffix ending at a clean user turn, and a batch of several large
results never fits in it. The summarizer therefore saw the batch, the model
never did, and the model answered from a summary that had dropped the specific
values. In one case it invented plausible ones instead of reading the files
again. In another it re-read them, the new batch crossed the line again, and
the cycle repeated.

On the Interactions wire no step carries a `role`, so `cleanUserTurn` found no
boundary and every compaction summarized the whole history.

Gemini's default compaction point was 80% of a 1,048,576-token window, about
839k tokens. Every request near that line carried the whole history at full
input price.

## Decision

- `compact_cut.unreadToolBatch` finds the model turn whose tool results end the
  history. `recentContextStart` never cuts after it, so that model turn and its
  results survive a compaction verbatim on every wire.
- The pre-send gate skips compaction when an unread batch ends the history and
  the summarizable prefix in front of it is under a quarter of the compaction
  point. Instead the request is sent, and compaction runs at the next check,
  once the model has read the batch. At 95% of the window the ordinary recovery
  runs regardless.
- The summary instruction asks for exact values to be copied character for
  character. It also asks the summary to name any result that was not read
  closely enough to copy from, so the model reads it again instead of recalling
  it.
- On the Interactions wire, a `user_input` step is a user turn boundary.
- Gemini's default compaction point is 80% of the window, capped at 300k tokens
  (`Provider.gemini_compact_tokens`). A percentage set through `--compact-at`,
  `GRAFF_COMPACT_PCT` or `/compact-at` applies as before.

## Consequences

A batch larger than the compaction point is sent once, over the line, instead
of being summarized unseen. The window still bounds it, and so do the
per-result caps. A compaction that keeps a large batch can leave the context
above the line until the next model turn. Gemini sessions compact earlier: more
summaries per long session, and smaller and cheaper requests between them.
