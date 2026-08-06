# Long-horizon memory eval

Answers one question the other harnesses cannot: **after a session ends, can a
fresh one recover what the first one learned?**

`scripts/eval/live-ab/` measures token economics within a run and
`scripts/eval/golden/` proves byte-identity of rendering. Neither crosses a
session boundary, and neither exercises compaction more than incidentally. This
one does both by construction.

## Running it

```sh
export GRAFF_BIN=/path/to/zig-out/bin/graff
python3 run_longhorizon.py base 1          # 1 run of the base arm
python3 run_longhorizon.py base 3          # 3 runs
LH_MEMO_BIN=/path/to/memo python3 run_longhorizon.py base,optmem 1   # comparison arm
```

Knobs: `LH_STEPS` (12), `LH_COMPACT_PCT` (4), `LH_FILLER` (26 lines/step),
`LH_TIMEOUT` (900s), `LH_SEED`, `GRAFF_EVAL_MODEL`.

## The two phases

**Phase 1** walks a chain of steps, each printing a one-time TOKEN, and is told
that a later session will need them. **Phase 2** is a *fresh process with no
shared history* in the same directory, asked to recover those tokens from
whatever durable record survived. Only phase 2 is scored; phase 1's number is a
sanity check that the chain completed.

## Four design properties, each of which had to be there

1. **Tokens are unrecoverable from disk.** `probe.py` prints a token once, then
   erases it from its own state file. `grep -r` over the fixture afterwards
   finds nothing. Without this the eval measures re-reading, not memory: a fact
   still on disk is one a competent agent simply reads again, and every arm
   scores full marks.
2. **The steps are chained, not numbered 1..N.** Each step reveals only the id
   of the next, so they cannot be batched. This is measured, not assumed: with a
   predictable sequence the model ran several probes per turn and 14 steps
   produced **9 api calls and 3 compactions**. Chained, the same 14 steps
   produced **45 calls and 15 compactions**.
3. **Compaction is forced with `GRAFF_COMPACT_PCT`, not `GRAFF_CONTEXT`.**
   `GRAFF_CONTEXT` only applies to models whose window graff cannot look up, so
   against a model with a known window it is silently ignored and the run
   compacts zero times while appearing to work.
4. **Filler stays under the #440 handle threshold** so it accumulates in context
   and drives compaction, rather than spilling to a handle.

## Scoring

- `correct` — token matched against its own step label. The real score.
- `loose` — token present anywhere in the output. Separates "forgot it" from
  "mislabelled it", and caught a run that scored 0/14 exact while having
  actually retained all 14.
- `fabricated` — a label carrying the *wrong* value. On a cold recall an agent
  that invents plausible tokens is worse than one that admits it cannot recover
  them, and a hits-only score hides that completely.

## Reading a result honestly

Runs are live-model and n is small; treat single-run deltas as directional. The
call cap (`--max-model-calls 60`) is a parameter, and an arm that exhausts it
has not "forgotten" anything — it failed to arrive. Check `p1_correct` before
concluding anything about recall: a low phase-2 score with a low phase-1 score
is an incompleteness result, not a memory result.

The phase-1 prompt tells both arms that a later session will need the data. That
does real work — in an earlier un-hinted variant the agent persisted nothing at
all — so this measures "can it persist when told to", not "does it think to".
