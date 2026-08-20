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

# harness-vs-harness on the same model (fair wall/cache compare)
./run.py --harness graff,grok --model grok-4.6
./run.py --harness graff-dev,pi-codegraff --model gemini-3.7-flash

# suite wall clock: run 4 tasks at once (rate-limit aware)
./run.py --harness graff-dev --jobs 4

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

## Wall clocks (and why Pi looks different)

Each task is a **new process in a new sandbox cwd**. Graff's prompt-cache key
is a cwd-derived UUIDv5 (`projectRootId`), so task 2 cannot read task 1's
prefix. Pi is launched with `--no-session`, so it also starts a fresh
conversation per task. Neither harness reuses a process across the 12 tasks.

Defaults are **not** a fair compare — pin the model. Every row is a **new
process in a new sandbox cwd**; none reuse a session across the 12 tasks.

| harness | runtime | command shape | default model | `--model` | session / cache | usage in scorecard | `schema-output` |
|---|---|---|---|---|---|---|---|
| `graff` | Zig (installed) | `graff -p --yolo` (`--lean` implied). Env `GRAFF_POST_DEADLINE_SECS=90` | `grok-4.6` | yes | cwd-derived `projectRootId`; cold per sandbox | calls / in / cached / writes / out | runs |
| `graff-dev` | Zig (`zig-out`, usually Debug) | same as `graff`, local binary. **No** 90s post deadline | `grok-4.6` | yes | same as `graff` | same | runs |
| `graff-full` | Zig (installed) | `graff -p --yolo --no-lean` (full catalog + eager MCP) | `grok-4.6` | yes | same as `graff` | same | runs |
| `grok` | grok CLI | `grok -p -m … --always-approve --output-format streaming-messages-json` | `grok-4.6` | yes | new process / task | calls / in / cached / out (no writes) | **skipped** |
| `claude` | Claude Code CLI | `claude -p --dangerously-skip-permissions` | `claude-sonnet-5` | yes | new process / task | wall / TTFT / pass only | **skipped** |
| `dsh` | dsh headless | `dsh --profile headless --patch dsh-luna.yml`. No `--model` flag | `gpt-5.6-luna` (patch) | **no** — edit the patch | headless, new process | wall / TTFT / pass only | **skipped** |
| `dsh-deepseek` | dsh headless | `dsh --profile headless` (native default route, no patch) | `deepseek-v4-flash` | **no** | same as `dsh` | wall / TTFT / pass only | **skipped** |
| `pi` | Node `pi` | `pi -p --mode json --provider openai --no-session` | `gpt-5.6-luna` | yes | `--no-session` | calls / in / cached / writes / out / $ | **skipped** |
| `pi-deepseek` | Node `pi` | same + `--provider deepseek` | `deepseek-v4-flash` | yes | `--no-session` | same as `pi` | **skipped** |
| `pi-codegraff` | Node `pi` + gateway | same + `--provider codegraff` → `gateway.codegraff.com` | `gemini-3.7-flash` | yes | `--no-session` | same as `pi` | **skipped** |

`schema-output` is the only task with `requires: ["output-schema"]`. Non-graff
harnesses skip it, so a full-suite pass rate is **12/12 vs 11/11**, not 12/12
vs 11/12. Time and token totals are 11 tasks on those rows.

`pi-codegraff` Gemini tool loops need
`graff-evals/pi-extensions/codegraff-gemini-echo.ts` or the follow-up 400s.

Fair same-model groups (suite wall / cache only after the pin):

```sh
# grok-4.6: installed vs Debug vs full catalog vs grok CLI
./run.py --harness graff,graff-dev,graff-full,grok --model grok-4.6

# gpt-5.6-luna: graff vs Pi vs dsh (dsh ignores --model; already luna)
./run.py --harness graff-dev,pi,dsh --model gpt-5.6-luna

# deepseek-v4-flash: graff vs Pi vs dsh native (dsh-deepseek ignores --model)
./run.py --harness graff-dev,pi-deepseek,dsh-deepseek --model deepseek-v4-flash

# gemini-3.7-flash: graff vs Pi-through-codegraff
./run.py --harness graff-dev,pi-codegraff --model gemini-3.7-flash

# Claude Code's default seat
./run.py --harness graff-dev,claude --model claude-sonnet-5
```

Ranked levers for a faster suite (biggest first):

1. **Fewer model calls.** Each hop is 2–8s of network. The last luna suite
   was 37 vs 47 calls (this lineage vs `release/v0.0.265`) — that is the
   harness win, not cache %.
2. **`--jobs N`.** Overlaps independent sandboxes. Suite wall drops; per-task
   wall does not. Stay rate-limit aware (~15 rpm per cache key on some
   providers).
3. **Release binary.** `zig build -Doptimize=ReleaseFast` (or `ReleaseSafe`).
   Debug `graff-dev` makes the harness column a lie; model time still
   dominates, but TTFT and short tasks do not.
4. **Keep `--lean`.** Already the `-p` default. `graff-full` / `--no-lean`
   doubles the per-turn prefix for capability these 12 tasks rarely use.
5. **Same faster model.** Flash vs Luna/Grok is a quality trade, not a
   harness win. Only compare walls after `--model` is pinned.
6. **One process / shared cache key.** Not built. A `graff --json` daemon
   across the 12 tasks, or an opt-in shared `prompt_cache_key` despite
   sandbox cwd, would let task 2+ hit the prefix on call 1. That is
   load-bearing (ADR 0011 / cwd isolation) — do not add it casually.
   Dropping Pi's `--no-session` is the same shape on that side.

Expected suite cache-read rate is ~45–60% of input tokens (12 cold writes,
warmth only on call 2+ inside a task). OpenCode's ~85% is one long-lived
process — different shape. Do not default `GRAFF_STABLE_CATALOG` (ADR 0011;
measured empty). Title-gen does not run on `-p`.
