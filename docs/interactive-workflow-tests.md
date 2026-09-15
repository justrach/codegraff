# Interactive workflow regressions

Run the repeatable, offline cases against the compiled harness:

```sh
zig build
python3 scripts/eval/test_tier2_outcomes.py
python3 scripts/eval-tier2.py \
  --only human-workflow-clarify-edit-recover-followup \
  --only human-workflow-missing-config-clarify-followup \
  --evidence-dir /tmp/interactive-workflows
```

The same cases run in Linux CI. Run them sequentially with other scripted-model
suites because they share the local model port. Each case names its workflow in
failures. `--dump CASE_ID` shows its complete events and assertions' input.

The label-rendering workflow starts with an existing two-file project. It asks
about case preservation, carries the human's answer before editing, observes a
failed validation and failed edit, rereads the file, repairs both modules, and
handles a second request to omit blank labels. Independent checks verify output,
input-list preservation, and unchanged documentation.

The configuration workflow encounters a missing file, asks for the actual path,
reads the existing settings without inventing defaults, and answers the first
turn without changes. A follow-up changes one setting while preserving the
other; an independent JSON check also rejects an invented replacement file.

Model replies are scripted; these cases test harness behavior, not whether a
particular model will choose the right plan. They exercise real tools and actual
files. The evaluator runs its own verification command after the agent stops,
checks the final files, and fails on missing evidence or a nonzero/timeout result
even when the agent or verifier stdout claims success. Verifier-integrity tests
cover those false-positive cases.

Evidence exports contain requests, responses, actual file outcomes, verifier
results, saved sessions, and available harness traces and trajectory records.
Keep these files private. A live-provider run needs separate authentication and
assessment; passing the scripted suite does not establish live-model coverage.
