# Synthetic long-horizon coding eval

This is an internal, data-free coding environment: a deterministic generator
builds a fresh multi-file repository from a seed, a harness works only inside
that repository, and an external verifier grades the resulting tree. The first
environment, `ledger-batch-v1`, asks an agent to implement atomic, idempotent
batch transfers across models, service logic, storage, and a JSON boundary
without regressing the existing API.

It is intentionally harder than the small tasks in `graff-evals/`: the outcome
requires coordinated edits, projected-state reasoning, rollback semantics,
compatibility, tests, and verification. New environments should test a distinct
systems behavior rather than merely making this fixture larger.

## Inspect one eval in 60 seconds

The showcase path makes the environment concrete without calling a provider or
leaving a workspace behind. It prints the seeded repository, the exact task an
agent receives, the unfinished baseline score, and every verifier row after the
bundled reference patch:

```sh
python3 evals/long_horizon/run.py --showcase --seed 469
```

The condensed scorecard is:

```text
ledger-batch-v1 / seed 469
Fixture accounts: cedar=105, ember=220, fjord=120, grove=210
Generated repository: 14 files across ledgercore/ and tests/
Agent task: implement atomic idempotent batch transfers across the model,
            service, repository state, and stable JSON API
Unfinished baseline: 2/10 checks, score=0.160 (expected failure)
Reference solution: 10/10 checks; deterministic reward floor=0.900
Model quality may add at most 0.050, only after this complete pass.
```

The full output includes the generated `TASK.md` and names all ten external
checks, so a reviewer can see both what the agent must coordinate and what
actually determines reward.

## What may explain the initial branch A/B

We also ran the same `gpt-5.6-luna` coding suite through peer/goal revision
`d93214e` and the `release/v0.0.265` Graff binary. The task score did **not** improve: both
versions solved every case. The branch instead reached the same answers with
less work (new versus release):

| Sample | Correctness | Wall time | Model calls | Input tokens | Output tokens |
|---|---:|---:|---:|---:|---:|
| Full suite, 12 tasks | 12/12 vs 12/12 | 146.01s vs 175.25s (-16.7%) | 37 vs 47 (-21.3%) | 172,919 vs 224,383 (-22.9%) | 3,284 vs 4,589 (-28.4%) |
| Five-task subset, three samples each | 15/15 vs 15/15 | 140.38s vs 190.58s (-26.3%) | 37 vs 50 (-26.0%) | 165,556 vs 233,237 (-29.0%) | 2,350 vs 4,342 (-45.9%) |

The strongest code-level explanation is conditional: ADR 0004 removed pushed
peer rosters and message bodies from model history. The release could put about
4,000 tokens of stale co-resident chatter into a one-shot's first request and
sometimes induced the model to answer that chatter. The branch parks bodies in
an inbox and injects at most a one-line wake. That mechanism predicts the
observed pattern—identical final answers, but fewer round trips and fewer input
and output tokens—**if another Graff session was visible during the run**.
The old harness often spent an extra call even on `exact-reply`; the branch
finished it in one.

This is a plausible mechanism, not a causal result. The result records do not
preserve the request bodies or live-peer roster, so they cannot prove that the
old arm paid the peer-context cost. Provider load, cache warmth, and rollout
nondeterminism remain confounders. The standing-goal change in ADR 0005 cannot
explain these short one-shots because the harness did not pass `--goal`, and the
runs were too short to compact. We also did not tune the system-prompt essays.

The single long-horizon seed is likewise a smoke test, not evidence of a score
increase. Under the corrected semantic grader both solutions pass 10/10. The
branch used 15 rather than 16 calls and 141,848 rather than 156,310 input tokens,
but it was slower (121.6s versus 111.0s) and emitted more output (5,185 versus
4,671 tokens). Establishing causality needs explicit binary provenance, held-out
seeds, interleaved run order, and multiple repetitions; five seeds with three
repetitions per binary is the minimum useful next comparison.

## Run

```sh
# No provider calls: prove the unfinished fixture fails, the reference patch
# passes, and editing protected fixtures forces reward 0.
python3 evals/long_horizon/run.py --self-test

# Build this checkout, then run one seeded rollout with Luna.
zig build
python3 evals/long_horizon/run.py \
  --harness graff-dev --model gpt-5.6-luna --seed 469 --keep

# Distribution rather than one memorized instance.
python3 evals/long_horizon/run.py \
  --harness graff-dev --model gpt-5.6-luna --seed 1000 --reps 5
```

Harness commands come from `graff-evals/harnesses.json`. Results are JSONL in
`results/`; `--keep` preserves the final synthetic repository under `.runs/`
for inspection.

## Grading and reward

Correctness is not an LLM opinion. `grader.py` runs outside the agent workspace
and produces named evidence rows:

- protected fixture hashes match a pristine regeneration;
- the public regression suite passes;
- the required data model and API exist;
- success order and projected balances are correct;
- replay is idempotent and changed payloads conflict;
- dry runs do not consume state;
- late validation failures are atomic;
- invalid metadata and duplicate transfer ids fail;
- stable JSON is emitted; and
- the old single-transfer behavior still works.

The reward bands make that ordering structural:

| Outcome | Reward |
|---|---:|
| Protected fixture changed | `0.0` |
| Any deterministic check fails | `0.8 × pass_fraction` (always `< 0.8`) |
| Every deterministic check passes | starts at `0.9` |
| Efficiency tiebreak | up to `+0.05` |
| Optional model-quality tiebreak | up to `+0.05` |

A model judge therefore cannot promote an incorrect rollout. When omitted, its
component is neutral (`0.5`). To use one, pass a command that reads a JSON
payload on stdin and writes exactly `{"score": 0..1, "reason": "..."}`:

```sh
python3 evals/long_horizon/run.py --judge-command './internal-judge'

# Ready-made adapter: use Graff/Luna as that secondary judge.
python3 evals/long_horizon/run.py --judge-command \
  'python3 evals/long_horizon/judge_graff.py --binary ./zig-out/bin/graff --model gpt-5.6-luna'
```

The payload contains the task, deterministic report, and bounded solution diff.
The rubric is limited to maintainability, clarity, and scope discipline. Judge
failure is fail-closed for that bonus. This is the same useful split as the DGM
example: an external replay verifier is the primary gradient; a model may only
reorder already-correct variants.

## Why synthetic codebases are enough

Long-horizon coding RL does not require purchased repositories. A generator can
control the latent specification, create unlimited seeded variants, retain
private invariants, and emit exact rewards. Purchased code mainly contributes
real-world distribution and accidental complexity; it is useful for transfer
validation, not a prerequisite for training signal.

A useful internal curriculum is:

1. **Generated kernels:** transactional state, parsers, schedulers, migrations,
   concurrent queues, and protocol adapters with exact executable semantics.
2. **Seeded variants:** renamed concepts, changed topology, distractor modules,
   boundary values, and injected historical constraints.
3. **Episodes:** investigation, implementation, test repair, and follow-up
   requirements against the same persisted workspace.
4. **Held-out generators:** score generalization on generator families and
   seeds never exposed during optimization.
5. **Real-code transfer set:** a small, legally clean suite used only to detect
   synthetic overfitting.

For adversarial or training-scale use, run the workspace in a container and
mount the generator/grader outside it. The local runner relies on harness path
confinement and is designed for evaluation convenience, not hostile-code
isolation. Pin the generator and grader commit/hash in every trajectory so an
optimizer cannot silently change its own reward function.
