# 0008. Synthetic coding evals use external verifiers; model judges only tiebreak

Status: accepted 2026-08-18

## Context

Long-horizon coding RL does not need a purchased repository: a seeded generator
can create the codebase, task, and latent invariants. The dangerous shortcut is
to let another model decide correctness. A judge model can be persuaded by the
candidate's prose or code, drift between runs, and reward plausible-looking
solutions that violate transactional or compatibility requirements.

The DGM example already uses the safer ordering: held-out replay is the primary
gradient and the LLM is demoted to a tiebreak. `evals/long_horizon/` needs the
same rule before its reward is used for optimization.

## Decision

- A deterministic generator materializes each seeded workspace. The evaluator
  and hidden checks stay outside that workspace and their revision/hash belongs
  in the trajectory.
- External executable checks decide correctness and fail closed. Fixture
  tampering scores `0`; any failed check stays below `0.8`; only a complete pass
  enters the promotable band at `0.9` or above.
- Efficiency and an optional model assessment may rank complete passes. A model
  judge sees a bounded diff and scores maintainability, clarity, and scope only;
  it can never promote an incorrect rollout.
- Training-scale or adversarial runs isolate the workspace in a container with
  the evaluator mounted outside it. A small real-code holdout measures transfer,
  not the primary training signal.

## Consequences

Synthetic environments can provide unlimited, exact, legally clean reward
without pretending they reproduce the whole distribution of production code.
Adding a generator family expands the curriculum; changing a verifier or score
band is an evaluation-version change, not an invisible tweak. Model judging is
still available for qualities executable tests cannot order, but correctness is
reproducible and auditable without a provider call.
