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
