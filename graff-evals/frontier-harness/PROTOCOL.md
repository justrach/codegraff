# How to read these numbers (cross-check)

GitHub source: [runta-dev/frontier-harness-eval](https://github.com/runta-dev/frontier-harness-eval)
Pinned snapshot in `results/eval-data.json` (generated 2026-08-22, model **k3**).

## What GitHub actually runs

**30 tasks**, not 21:

| slice | n | grader |
|---|---|---|
| Terminal-Bench 2.1 | 21 | public `original-tasks/<id>/tests/test_outputs.py` |
| DeepSWE (datacurve/*) | 9 | **hidden**. Task only collects `/logs/artifacts/model.patch` |

Overview on the board is **12 harnesses × 30 tasks = 360 cells**.
Exo on that board: **16/30** = **16/21 TB + 0/9 DeepSWE**.

This folder ran **all 30 tasks**. TB-21 is pytest-graded in-container. DeepSWE is graded with `datacurve-ai/deep-swe` (`grade_swe.py`), not guessed from a patch. Claiming *same-seat* 30-task parity with the board is still a lie unless model = Kimi K3 **and** `BENCH_APPEND` is empty.

## Same tests we used (TB-21)

Images from each `tasks/<id>/task.toml` `docker_image`.
Tests copied from the pinned `terminal-bench` tree `original-tasks/<id>/tests`.
Pass = `pytest /tests` exit 0 inside the task container after the agent exits.

## What is *not* the same protocol as the board

1. **`BENCH_APPEND`** in `fh_run.py` (`--append-system-prompt`). Extra coaching the 12 K3 harnesses did not get (leftover files, sandbox `FLAG{...}`, `setsid nohup`, ELF section VAs). Graff grok **first pass without that was 14/21**. Later 17 → 20 used the append. Do not put 20/21 next to their 16/21 as “same seat.”
2. **Model**: board = Kimi K3. Our grok-4.6 / exo grok-4.6 runs are a different model. Graff **kimi-k3** (Moonshot metered) is the closest model match, still with `BENCH_APPEND`.
3. **Exo cost on our PNG is not “cheap.”** Our exo grok run logged **no token events**, so list$ is missing. SuperGrok meter $0 is a plan, not a price. On the **published K3 board**, exo spent **~$16.72** `cost_first_cold` across 30 tasks (TB tasks mostly $0.04–$0.18; cython $1.83). Claude-code ~$348, codex ~$69, opencode ~$49.
4. **Runtime is not Runta’s golden checkpoint.** Official eval restores a prepared VM (same vCPU/RAM/disk). We `docker run` the public image and, on stripped images, copy a CA bundle and apt-install pytest so TLS and tests can actually run. That is infrastructure, not a task hint — but it is not bit-identical to Runta.
5. **DeepSWE** is graded (see below). We do not invent pass/fail.

## List prices we used

| model | per 1M | source |
|---|---|---|
| grok-4.6 | $2 in / $0.50 cache / $6 out (high band $4/$1/$12 at 200k/request) | xAI table |
| kimi-k3 | $3 in / $0.30 cache / $15 out | platform.kimi.ai/docs/pricing/chat-k3 |

Graff `[usage]` on SuperGrok prints $0.0000 (subscription). `list_price.py` rebuilds list$.

## Reproduce TB-21 (graff)

```
export FH_GRAFF_MODEL=grok-4.6   # or kimi-k3 + MOONSHOT_API_KEY
python3 graff-evals/frontier-harness/fh_run.py -j 2 --out graff-evals/frontier-harness/results.jsonl
python3 graff-evals/frontier-harness/plot_tb21.py
```

Linux `graff` at `/tmp/graff-linux-x64`. Tests at `/tmp/tb-tests/original-tasks`. Task pack at `/tmp/frontier-harness-eval`.

To compare **fairly** to the K3 board: empty `BENCH_APPEND`, same model (kimi-k3), TB-21 only, then say so.

## DeepSWE 9 — how we graded them (not fabricated)

`frontier-harness-eval` only collects `model.patch` for the 9 DeepSWE tasks — the
grader was considered "hidden." It isn't: `datacurve-ai/deep-swe` ships the tests.
We cloned it (`/tmp/deep-swe`, pinned `datacurve-ai/deep-swe`).

`grade_swe.py` for each task:
1. start the task image (`--entrypoint sleep`)
2. copy `deep-swe/tasks/<id>/tests/` → `/tests`
3. copy the clean patch → `/logs/artifacts/model.patch`
4. `python3 /tests/grader.py prepare`, then `bash /tests/test.sh`
5. read `/logs/verifier/reward.json` → `reward`, `f2p`, `p2p`, `apply_failed`

That is exactly how the board scored (exo 0/9). Same images, same tests, same
Grader prepare/test protocol. If reward.json is missing we mark FAIL (never guess).

### Why some patches `apply_failed`

- **grok / kimi both**: `git apply` against the *test.patch-applied base* can
  reject a patch that applied cleanly to the raw tree. `apply_failed=1` means the
  grader could not land the patch; that is a real failure, same for both models.
- `httpx`/`scc` (kimi) clean to **0 bytes** of real change — raw `model.patch` was
  all `.graff/` scratch junk. Empty → fail.

### Accuracy of the DeepSWE cost columns

- grok `list$ $25.56` = `swe-results.maxima.json` `list_usd_sum` (cache-adjusted,
  ~96% hit at `$2/$0.50/$6` per 1M, high band not hit). Trust the per-task
  `list_usd` field over recomputing from raw tokens.
- kimi `list$ $21.91` = cache-adjusted at Moonshot `$3/$0.30/$15` per 1M. The
  cached portion is baked into `list_usd` (e.g. anko no-cache would be $6.27; with
  cache it's $1.28) — so $21.91 is the honest figure, not a raw $126.
- `tok_cached_max` in some maxima is 0 because the run row didn't re-telemetry
  it; the `list_usd` field already accounts for the cache discount.

### Exo cost ("is it really that cheap")

No — **our** exo grok run logged no token events, so list$ is missing (that's
a telemetry gap, not $0). On the **published K3 table** exo spent **~$16.72**
`cost_first_cold` across 30 (TB tasks mostly $0.04–$0.18; cython $1.83;
DeepSWE ~$10.3). That's genuinely cheap vs claude-code ~$348 / codex ~$69 /
opencode ~$49 — but it is real list$, not a free plan.
