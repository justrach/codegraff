# graff-evals

A self-contained eval environment for coding harnesses: run any model through
any harness on a fixed task suite and get pass rate, wall time, first-output
latency, and token usage side by side.

Every task is one JSON file in `tasks/` — fixture files inline, a prompt, and
a deterministic shell `check` that decides pass/fail inside the sandbox. No
network is needed to author or verify tasks; only the harness under test
spends model calls.

## Run it

```sh
cd graff-evals

# full suite on graff (defaults to grok-4.6)
./run.py --harness graff

# one task, three reps, on the grok CLI
./run.py --harness grok --task fix-fib --reps 3

# harness-vs-harness on the same model
./run.py --harness graff,grok --model grok-4.6

# a different model through graff
./run.py --harness graff --model claude-opus-4-8

# the locally built binary instead of the installed one
zig build && ./run.py --harness graff-dev

# interactive: pick a task + harness, watch the run live, get the verdict
./run.py --interactive
```

Results land in `results/run-<stamp>.jsonl` (one record per run) plus a
summary table on stdout. `.sandboxes/` holds the materialized working dirs of
the last run for post-mortems; both are disposable.

## Harnesses

`harnesses.json` declares each harness as a command template plus parsers:

- `answer` — where the final answer text comes from (`stdout`, or
  `grok-stream` for grok's `streaming-messages-json` result event).
- `usage` — how to extract token counts (`graff-stderr` parses graff's
  `[usage]` line; `grok-stream` reads the result event's usage).
- `capabilities` — feature gates; a task listing `requires` a capability is
  skipped on harnesses that lack it (e.g. `output-schema` structured outputs).

Add a harness by adding an entry; add a model by passing `--model`.

## Tasks

12 tasks across categories: instruction-following, debugging, shell, data
(JSON/CSV), text extraction, refactoring, test-writing, git, long-context
recall, structured output, and code comprehension. The check runs in the
sandbox with `$ANSWER_FILE` pointing at the captured final answer, so checks
can assert on the answer text and on filesystem/git state.

Authoring rules that keep results comparable:

- The check must be deterministic and self-contained (`python3` + POSIX sh).
- Planted values (sums, counts, code words) live in the fixture, not the
  prompt, so the model must actually do the work.
- One behavior per task; keep prompts short and unambiguous.
