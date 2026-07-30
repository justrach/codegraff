# Repository instructions

## File size

- Keep every hand-written source file at or below 600 lines of code.
- When a change would push a file past 600 LOC, split cohesive responsibilities into focused sibling modules as part of the same change.
- If a touched file is already over 600 LOC, do not grow it; move it toward the limit before adding more behavior.
- Generated files, vendored dependencies, lockfiles, and machine-produced artifacts are exempt; change their generator or source instead of hand-editing them.

## Tests must be reachable

- `zig build test` only runs the tests in files the test root pulls in. A new module's `test {}` blocks compile to nothing until something references it, and the suite still reports green.
- A new test-bearing module needs a reference in `src/main.zig`'s `test {}` block: `_ = @import("your_module.zig");`.
- Prove it with the count, not with hope: the suite total must go up by the number of tests you added. `scripts/eval-tier1.sh --only reach` fails on any file that declares tests nothing imports.

## Before you push

Install the tracked hooks once, and the checks run themselves:

```bash
scripts/install-hooks.sh
```

That points `core.hooksPath` at `.githooks/`, whose `pre-push` runs **tier 1** of the internal eval set: `zig fmt`, the 600-line ceiling, test reachability, `zig build`, the unit suite plus a count that may grow and never shrink, the named goal/loop/todo invariants, and SDK drift. It is deterministic and offline (no provider calls, no network, no spend) and takes about 20 seconds warm. A push that only touches docs skips it.

```bash
scripts/eval-tier1.sh                 # run it by hand
scripts/eval-tier1.sh --only sdk      # rerun one check
scripts/eval-tier1.sh --list          # the check names
git push --no-verify                  # emergency skip (GRAFF_SKIP_PREPUSH=1 also works)
```

Failures name the invariant, say which regression it guards, and print the command that reruns only that check. The required invariants and the docs-only path list are data in `scripts/eval/tier1-manifest.json`.

Two rules the hook enforces that are easy to trip:

- **The suite count is a ratchet.** If it drops, either restore the tests or lower `test_count_baseline` in the manifest in the same commit, with a reason in the message.
- **The SDKs are generated, not written.** Run `python3 sdk/generate.py --harness ./zig-out/bin/graff` after any change to the model catalog, tool schemas, or provider list, and commit the result.

## Tier 2: model-backed behavior

Behavior regressions do not show up in a unit suite. **Tier 2** runs the harness for real, so it is opt-in and never in the hook. Cases are data in `evals/harness_behavior.jsonl`, one line each, carrying the regression it guards. The model is scripted (`scripts/eval/mock_model.py`), so the default run is offline and free.

```bash
python3 scripts/eval-tier2.py                 # every case
python3 scripts/eval-tier2.py --list          # the cases and what they guard
python3 scripts/eval-tier2.py --only <id>
python3 scripts/eval-tier2.py --dump <id>     # every event and request from one case
```

Add a case when you fix a behavior bug: script the model replies that provoke it, then assert on the events the harness emitted or on what it sent back to the model. Run it against a real provider with `--provider`/`--model` when you care how the model behaves rather than how the harness does.
