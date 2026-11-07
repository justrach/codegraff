# Native Cursor comparisons

`cursor_compare.py` makes the Argon comparison repeatable and adds an xAI
subscription preset. This is opt-in live spend, separate from offline tier 1.
It reuses `run.py`, the existing deterministic checks and the same 21 core/MCP
fixtures: 11 core and 10 fixture-MCP tasks, three repetitions per arm by default.

| Preset | Graff model and login | Native Cursor model | Requested effort |
|---|---|---|---|
| `argon` | `codegraff/gemini-4-argon`, Codegraff login | `gemini-4-argon-low` | low |
| `xai-sub` | `xai/grok-4.7`, xAI subscription login | `grok-4.7-high` | high |

These compare the same **named model** across different harnesses and provider
backends, not a causal ablation of harness overhead alone. Cursor runs through
native `agent -p`, **not Harness desktop**. Requested reasoning scales may differ.
A missing or changed model label fails routing validation; no automatic fallback.

## Run

From the repository root, with `agent` on PATH and both required logins present:

```sh
zig build -Doptimize=ReleaseFast
# Six smoke runs; does not contribute to the full score.
python3 graff-evals/cursor_compare.py --preset xai-sub --smoke
# 126 interleaved runs, with a private temporary root printed on stdout.
python3 graff-evals/cursor_compare.py --preset xai-sub --reps 3 --workers 4
# Repeat the original Argon comparison through the reusable eval entry point.
python3 graff-evals/cursor_compare.py --preset argon --reps 3 --workers 4
# A labeled subset for MCP regressions; never merged into the full score.
python3 graff-evals/cursor_compare.py --preset xai-sub --task linear-issues --task linear-warm --task linear-quiet --reps 3 --workers 4
```

`--binary PATH` selects a Graff executable; the runner freezes and hashes it
before running either arm. `--cursor-bin PATH` selects the native CLI. The
Cursor version and bundled index hash are recorded; an index change invalidates
the run. Fixture prompts and system prompts are not rewritten.

`--output-root PATH` must be a **new directory outside every repository**. This
keeps private repo instructions and source context out of both sandboxes. Raw
receipts and model transcripts stay there. The fixture MCP script is copied
next to the output root so the existing task setup can find it. `--report-dir
PATH` optionally writes local summary JSON and Markdown elsewhere; it never
publishes anything. Do not commit raw receipts, private reports or root pointers.

An offline summary can be rebuilt without model calls:

```sh
python3 graff-evals/cursor_compare_report.py --root /private/eval-root --output /private/report
python3 -m unittest discover -s graff-evals -p 'test_cursor_compare.py'
```

## Authentication isolation

Graff gets only the selected saved login, an explicit provider/model selection,
and a fresh HOME. The xAI preset copies only the subscription access token and
expiry, **not the refresh token**; API-key fallback and other provider logins
are absent. The isolated route must confirm OAuth/login and subscription billing
before any scored run. xAI access tokens need at least 30 minutes remaining;
the eval does not refresh or rotate the real login. Use `--xai-auth PATH` or
`--codegraff-auth PATH` to select a saved login file.

On macOS the runner reads exactly one named Cursor Keychain access-token item,
never enumerates the Keychain, and never copies a valid refresh token. Elsewhere,
or to use a specific login snapshot, supply `--cursor-auth PATH` with a private
JSON object containing `accessToken`. Cursor's disposable file has a deliberately
invalid refresh value because its CLI requires that field. Do not pass secrets
as command-line arguments. Disposable login files are removed in `finally` after
normal runs/errors; a forced kill can leave private snapshots behind.

Both arms have isolated HOME/XDG directories, fixture-only MCP, no personal
rules, no inherited provider API keys, and no personal repository source. Only a
prewarmed Node compile cache is shared across Cursor runs, not account state.

## Interpretation

A clean pass requires the deterministic check, unchanged verifiers, exact model
routing, native completion, exit zero and no timeout. Graff additionally confirms
its requested effort selection. Incomplete/duplicate/unexpected run matrices
cannot produce a complete report. Failures remain in the score; passing-only
matched timings are reported separately with their both-pass denominator.

Wall time is the complete task-process lifetime. Cursor's self-reported task
duration and the wall time outside it (including CLI startup/teardown) are kept
separate; these are **not matched Graff model timings**. First output includes
startup events and is not TTFT. Comparable costs and Cursor model-call counts are
unknown, not zero. Subscription price is not free inference. Small fixture
results do not establish performance on large real-world repositories.

The original Argon replay is retained locally under
`artifacts/argon-cursor-20261017/`; it is historical evidence, not rerun or mixed
into subsequent preset scores.
