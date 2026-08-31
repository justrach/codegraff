# 0058. compact_cut stalls when the same pin does not shrink

Status: accepted 2026-08-31

## Context

A long Codex tool turn (#706) retried `compact_cut` at one unresolved
boundary 41 times. Compaction reclaimed some prefix, then the live
suffix grew past 285k tokens and the turn failed. Prior fixes (#163,
#193, #201, #440, #581) still allow a single current turn to outgrow
the safe retained suffix.

## Decision

Record each in-turn cut's boundary and suffix-token estimate. If the
same boundary fails to shrink by 2k tokens twice in a row, stop
further summarization spends for that unresolved turn, announce once,
and take the existing recover/trim path. A material shrink or a new
boundary resets the counter. A resolved turn clears it.

## Consequences

The harness will not resend an ever-larger pinned current turn. It
does not invent a mid-turn tool-pair checkpoint; that remains a
follow-up if stall-then-trim is still too coarse.
