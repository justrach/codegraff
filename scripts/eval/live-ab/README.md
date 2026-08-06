# Live A/B eval harness

Measures what a change actually costs or saves on real agent runs: api calls,
input tokens, cached tokens, output tokens, tool calls, wall time, and whether
the task was solved. Two graff binaries run the same fixtures with the same
model, N times each, on a fresh copy of the fixture per run.

This exists because token-economics claims are easy to assert and hard to
prove. Every number in a `RESULTS-*.md` here is regenerable from the run
artifacts the harness leaves behind.

## Running it

Build the two binaries you want to compare (both `-Doptimize=ReleaseSafe`, or
wall time is meaningless), then:

```sh
export GRAFF_EVAL_BEFORE=/path/to/base-worktree/zig-out/bin/graff
export GRAFF_EVAL_AFTER=/path/to/change-worktree/zig-out/bin/graff

python3 run_eval.py                      # all tasks, both arms, 3 runs each
python3 run_eval.py f3_goalloop          # one task
python3 run_eval.py f3_goalloop after 5  # one task, one arm, 5 runs
python3 make_results.py > RESULTS.md     # regenerate the report
```

Optional: `GRAFF_EVAL_MODEL` (default `gpt-5.6-sol`), `GRAFF_EVAL_TIMEOUT`
(default 300s hard kill).

Results accumulate in `results.json` and are merged by `(task, binary, run)`,
so a re-run of one cell replaces just that cell. Raw stdout, stderr and the
post-run fixture tree stay under `runs/<task>/<arm>/<n>/`. Both are gitignored:
they are outputs, not instrument.

## Measurement validity

Four things have to hold or the comparison says nothing:

1. **Same model on both arms.** The harness enforces one `MODEL` for the whole
   invocation.
2. **Both arms ReleaseSafe.** A Debug binary is roughly an order of magnitude
   slower and makes every wall-time column a lie.
3. **Companion MCP servers off.** `one_run` writes `.harness/settings.json`
   with `{"skills":{"codedbpro":false}}` into every run copy, so tool schemas
   cannot drift between the arms and silently move the input-token number.
   This lives in the harness rather than in each fixture because the repo
   `.gitignore` excludes `.harness/`, so a committed copy would not survive a
   clone. `empty-mcp.json` is here for the same purpose when you need to
   override MCP config wholesale (point `GRAFF_MCP_CONFIG` at it).
4. **Fresh fixture per run.** `one_run` deletes and re-copies the fixture, so
   run 2 never inherits run 1's edits or `.graff/` state.

`--no-telemetry` is passed throughout.

## The fixtures

| task | fixture | what it exercises |
|---|---|---|
| `f1_bugfix` | `f1-bugfix` | Ordinary agentic work: run tests, find a planted median bug, fix it, get 11 tests green. The broad regression check. |
| `f2_biglog` | `f2-biglog` | Big tool output, natural phrasing. A 168 KB build log with exactly one `status=FAILED` line. Models usually narrow with grep rather than dumping the file. |
| `f2b_forcedcat` | `f2-biglog` | Same log, but the prompt forbids narrowing and demands `cat` through bash, forcing the single oversized tool output the natural phrasing avoids. |
| `f3_goalloop` | `f3-goalloop` | The goal/eval loop: stub `slugify()`, iterate with the eval tool until the checker scores 100. |
| `f3b_reverify` | `f3-goalloop` | Same task, but the prompt tells the model to re-confirm a failing verdict without editing, which manufactures the precondition for the re-verify fast path. |
| `f4_embedder` | `f4-embedder` | `--no-local-tools`, single call, pure reasoning puzzle. Isolates system-prompt size with near-zero variance, which makes it the cleanest prompt-size probe in the set. |

Success is checked per task, not eyeballed: pytest exit status for `f1`, the
required request id and failure reason appearing in the answer for `f2`, a
final checker score of 100 for `f3`, and the correct one-word answer for `f4`.

## Static prompt capture, at zero model cost

`mock_capture.py` serves an OpenAI-compatible endpoint on `127.0.0.1:1234`,
records the first request body, and answers with a trivial completion. Point a
binary at it to diff the exact system prompt two builds send without spending
anything:

```sh
python3 mock_capture.py before.json &
GRAFF_EVAL_BEFORE_BINARY --model lmstudio -p "hi"
```

This is how the per-call prompt-size deltas in the reports were obtained. It is
far more precise than inferring prompt size from live token counts, and it is
the right first instrument for any prompt change.

## Reading the reports honestly

`make_results.py` reports medians with full min-max spread and marks whether
the two ranges separate. When they overlap, the comparison is inconclusive and
no claim should be drawn from it. At n=3 against a live model, single-digit
percentage deltas are usually sampling noise. Wall time is the noisiest column
and should never carry a conclusion on its own.
