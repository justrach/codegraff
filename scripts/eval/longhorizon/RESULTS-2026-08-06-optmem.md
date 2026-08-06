# Cross-session memory: graff v0.0.242 vs graff + OptMem

**Verdict: not adopting OptMem.** Its retention was flawless; its cost model is
the wrong shape for a harness whose agent already has bash and a filesystem.

Evaluated because [OptMem](https://github.com/VictorTaelin/OptMem) solves a real
gap — a hierarchical, navigable index over an append-only log — that #441's flat
transcript does not. The design is sound. The integration is not.

**Setup.** `gpt-5.6-sol`, 12 chained steps, `GRAFF_COMPACT_PCT=3`, 36 filler
lines/step, `--max-model-calls 60`, one run per arm, identical tokens across
arms (paired). Base is v0.0.242 as shipped, which already carries the
append-only transcript (#441), pre-compaction notes-to-self (#391) and the
post-compaction durable-state note (#411) — so this is not "OptMem vs nothing",
it is "does OptMem add anything on top of what we ship".

## Results

| | base (v0.0.242) | + OptMem |
|---|---|---|
| **cold recall** | **12/12** | 8/12 |
| fabricated tokens | 0 | 0 |
| steps completed | 12/12 | **8/12 — call budget exhausted** |
| api calls per completed step | **3.2** | 7.5 |
| input tokens | 198,864 | 332,925 (**+67%**) |
| compactions | 13 | 21 |
| wall | 296s | 580s |

## What actually happened

**OptMem retained everything it stored: 8 of 8, across a genuine session
boundary.** It did not forget. It ran out of budget at step 8 of 12, and its
final message honestly enumerated what remained undone, including a `memo nap`
compression it had been asked to perform mid-task.

**The mechanism is the whole result.** The base agent persisted with:

```sh
python3 probe.py step 9 | tee -a .probe-token-chain
```

Persistence folded into a tool call it was **already making** — zero marginal
cost. OptMem requires a separate `memo note` call per fact, plus `wake` at
startup, plus compressions it prompts for mid-task. That is 2.3× the calls per
step, and the extra output inflated context enough to force 21 compactions
against 13.

This is the #440 doctrine ("filesystem as the namespace, bash as the REPL")
arriving at the same destination without a subsystem — reached by the model on
its own, unprompted.

## An earlier round that was invalid, and why it is recorded

The first attempt was a single session. Both arms scored 18/18 through ~20
compactions and OptMem appeared to cost +10.7% for no benefit — a tidy,
plausible, **entirely unfounded** conclusion. `memo note` had been called **zero
times** and `LOG.txt` was empty. The arm never used the tool; it only paid to
carry instructions it ignored.

Two findings survive from that failure:

1. **The model ignored instructions marked "mandatory."** The AGENTS.md was
   correct and complete and `memo` was executable at the documented path. Given
   a concrete task, the agent went straight at it. That is an adoption risk for
   *any* always-on memory layer that depends on the model volunteering to write,
   and it is not specific to OptMem.
2. **A single-session test cannot evaluate a cross-session tool.** Within one
   session the agent has no reason to note anything: its context holds
   everything, and #391 covers the rollover.

The lesson for this harness generally: **always check the mechanism was
exercised before believing the score.** `memo_notes` and `memo_log_lines` are in
the record for exactly that reason.

## What is worth taking

Not the tool. The **idea**: a hierarchical index over the append-only
transcript, so a large `.transcript.jsonl` is navigable rather than only
greppable. Built from the compaction summaries graff *already generates*, its
leaves cost nothing extra and land on precisely the right boundary — which is
the one thing OptMem cannot do, since it must schedule merges explicitly and
interrupt the agent to run them.

Two costs to avoid importing along with it: OptMem's `wake` loads ~8k tokens
into every session by default, several times what #416 and #445 clawed back this
same release; and a per-fact API call is expensive in exactly the regime that
matters.

## Caveats

n=1 per arm — treat the deltas as directional, not measured. The 60-call cap is
a chosen parameter and OptMem would likely have finished without it, though the
2.3×-per-step cost ratio is cap-independent and is the real signal. Both arms
were told a later session would need the data, which does real work: in the
un-hinted round the agent persisted nothing at all. And OptMem is built for
accumulating identity across projects over weeks, which this fixture does not
test at all.
