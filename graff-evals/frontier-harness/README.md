# FrontierHarness — graff vs exo vs published board

Replicates and extends [runta-dev/frontier-harness-eval](https://github.com/runta-dev/frontier-harness-eval)
with graff (this repo) on two models, exo on grok-4.6, and our own grading of the
published **Kimi K3** board. No credential is committed here: the kimi-k3 path
reads keys from the environment, and the grok path copies an existing local
credentials file into the task container (see `PROTOCOL.md`).

## The GitHub suite is 30 tasks, we grade what the grader allows

| slice | n | grader |
|---|---|---|
| Terminal-Bench 2.1 | 21 | public `original-tasks/<id>/tests/test_outputs.py` |
| DeepSWE (datacurve-ai/deep-swe) | 9 | real tests in `datacurve-ai/deep-swe` (`tests/test.sh` + `grader.py`), used via `grade_swe.py` |

Board = 12 harnesses × 30. Exo published **16/30** = **16/21 TB + 0/9 DeepSWE**.

## Results (same 21 TB + 9 DeepSWE tasks)

### TB-21

| run | pass | list$ | $/pass |
|---|---|---|---|
| graff · grok-4.6 **first** (no eval append) | 14/21 | $5.05 | $0.36 |
| graff · grok-4.6 **now** (eval append) | 20/21 | see `tb21-*-results.maxima.json` | — |
| graff · kimi-k3 (Moonshot metered, eval append) | 17/21 | $3.65 | $0.21 |
| exo · grok-4.6 | 9/21 recorded | n/a (no token events) | — |
| exo · K3 published | 16/21 | ~$16.72/30 | — |

graff's 20/21 and 17/21 used `BENCH_APPEND` (eval-only; not `prompt_text.zig`).
The honest no-append number is the 14/21 first pass.

### DeepSWE 9 (graded on real `datacurve-ai/deep-swe` verifier, not fabricated)

| run | graded | list$ | calls max | tok_in max | wall max |
|---|---|---|---|---|---|
| graff · grok-4.6 | **1/9** (katex-multicolumn-array-spans) | $25.56 | 88 | 8.7M | 1161s |
| graff · kimi-k3 | **1/9** (katex) | $21.91 | 134 | 12.9M | 3588s |
| exo · K3 published | 0/9 | ~$10.3 | — | — | — |

Both graff runs pass only `katex`; the other 8 `apply_failed` or genuine fail.
`httpx` (grok) was a near-miss at f2p 0.992 / p2p 1.0.

## Files

| path | what |
|---|---|
| `fh_run.py` | runner: image → `graff`/`exo` → capture `model.patch` / tokens. `BENCH_APPEND` at `fh_run.py:178`. |
| `fh_exo.py` | exo runner. |
| `grade_swe.py` | `python3 grade_swe.py [grok-4.6\|kimi-k3]` — real `datacurve-ai/deep-swe` grader on a patch (needs `/tmp/deep-swe`, `/tmp/frontier-harness-eval`). |
| `plot_tb21.py` | the chart (`tb21-graff-grok46.png`). |
| `tb21-graff-grok46.png` | chart, using the project's own palette. |
| `results.jsonl` / `exo-results.jsonl` | grok / exo TB-21 rows. |
| `kimi-results.jsonl` | kimi-k3 TB-21 rows. |
| `swe-results.jsonl` / `swe-kimi-results.jsonl` | grok / kimi DeepSWE rows. |
| `*.maxima.json` | per-axis maxima (calls / tok / cache / list$ / wall). |
| `swe-grades-*.jsonl` | `grade_swe.py` output (reward.json per task). |
| `patches/grok-4.6/*.patch` | clean grok DeepSWE patches (`.graff/` stripped). |
| `patches/kimi-k3/*.patch` | clean kimi DeepSWE patches. |
| `raw/deepswe-kimi/*.patch` | kimi raw `model.patch` (incl. scratch). |

`tb21-graff-grok46.png` is the chart.

## reproduce

```sh
export FH_GRAFF_MODEL=grok-4.6       # or kimi-k3 + MOONSHOT_API_KEY
python3 fh_run.py --suite tb -j 2 --fresh --out results.jsonl    # TB-21
python3 fh_run.py --suite swe -j 2 --out swe-results.jsonl       # DeepSWE patches
python3 fh_exo.py -j 2 --fresh                                   # exo has its own runner
python3 grade_swe.py grok-4.6        # needs /tmp/deep-swe + /tmp/frontier-harness-eval
python3 grade_swe.py kimi-k3
python3 plot_tb21.py && open tb21-graff-grok46.png
```

See `PROTOCOL.md` for what is and is not the same bench seat.