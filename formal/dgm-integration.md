# Formal checks in the evolution loop

Formal evidence is an admission condition, not a fitness reward. Passing a
model check must never compensate for failed task correctness, and neither
formal success nor a smaller prompt establishes a performance improvement.

## Prompt evolution and source evolution

`examples/dgm_loop.py` evolves prompt genomes. Its correctness gate is the
external held-out replay judge. Its current passing score ranks tool economy:
`total / (total + tool_calls)`. Formal checks validate the pinned harness
baseline beneath those prompt candidates; they do not prove prompt behavior.
Keep the reward formula unchanged when adding the gate.

For harness-source evolution, each candidate instead needs an immutable source
identity, a reviewed mapping between its lifecycle changes and formal actions,
model checks, and runtime regressions. Hashing a source tree and an executable
records their identities; it does not prove the executable was built from that
source. A reproducible build or attested build receipt supplies that separate
link.

## Evaluation flow

```mermaid
flowchart TD
    A[Pin evaluator, models, source and executable] --> B[Run formal baseline checks]
    B -->|Fail or unavailable| X[Stop formal-enabled evaluation]
    B -->|Pass| C[Generate prompt candidate]
    C --> D[Revalidate pins and bind candidate receipt]
    D --> E[Run held-out replay tests]
    E -->|Any failure| F[Keep below passing score band]
    E -->|All pass| G[Compute existing efficiency score]
    G --> H[Revalidate inputs before score write]
    H --> I[Archive signed evidence digest and score]
```

The same checked baseline can be reused for multiple prompts while every pinned
input remains unchanged. Input drift invalidates admission; it must not silently
trigger a new baseline or allow the candidate to rewrite its own checker.
Keep evaluator copies and pin files outside the editable task workspace. These
integrity checks do not replace OS isolation for adversarial evolution.

A receipt should distinguish source/model identity, finite checked properties,
checker result, candidate prompt identity, held-out suite identity and executable
identity. Preserve the original replay suite hash and bind the formal receipt
into score provenance. Retain formal failure separately from replay failure,
unknown measurement and an ordinary low efficiency score.

## Other native promotion paths

The repository also has native learning and persona promotion paths. Integrating
the Python example alone does not gate all of them:

- `src/learn_tournament.zig` selects one primary winner and applies holdout
  eligibility. Formal evidence belongs in admission and final eligibility,
  without allowing it to rescue a primary or holdout rejection.
- `src/learn_run.zig` persists checkpoints and comparison records. A resumed run
  needs the same checked identity; a receipt from an earlier source cannot be
  reused merely because the prompt genome matches.
- `src/learn_receipt.zig` signs aggregate learning evidence. Adding a formal
  receipt to this path requires a versioned signed schema and validation.
- `src/fleet.zig` promotes local archive champions. Historical scores without
  formal evidence cannot be represented as formally checked evaluations.

These are separate integration points, not properties established by the
Python gate. A rollout must identify which entry points enforce formal mode,
and preserve explicit distinction between unchecked and checked archives.

## Performance evidence remains separate

Wall time, input/output tokens, cached input, cache writes and cost need paired
runtime measurements with preserved failures and per-metric completeness.
Unknown usage is not zero, and subscription usage is not a billed-dollar receipt.
The formal gate does not change these measurement requirements or establish
that a candidate is faster, cheaper, or more capable.
