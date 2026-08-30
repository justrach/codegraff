# graff-evals

A self-contained eval environment for coding harnesses: run any model through
any harness on a fixed task suite and get pass rate, wall time, first-output
latency, peak RSS, CPU, and token usage side by side.

Every task is one JSON file in `tasks/` — fixture files inline or via
`files_dir`, a prompt, and a deterministic shell `check` that decides
pass/fail inside the sandbox. Held-out checks live in `hidden/` and are
injected through `$TASK_ROOT` after the harness exits (the agent never
sees them). No network is needed to author or verify tasks; only the
harness under test spends model calls.

## Suites

`--suite` selects which tasks run (`all` is core+rlm+swe; `mcp` is opt-in):

| suite | what it measures |
|---|---|
| `core` | sequential single-file work (instruction, debug, git, schema, …) |
| `rlm` | scatter-gather / multi-file reads (where default rlm can overlap) |
| `swe` | DeepSWE-shaped multi-file bugfixes, distilled from [deepswe.datacurve.ai/run](https://deepswe.datacurve.ai/run) (no Harbor/Docker) |
| `mcp` | Linear-shaped fixture MCP (Blacksmith code-mode + muscle memory). Always `--no-lean` (`graff-dev-nolean`): lean is a different catalog and is not on the front. |
| `inhouse` | Bug shapes distilled from shipped CodeGraff PRs (symlink write, oneshot chrome, cache git-root, stall widen/warn, empty catalog). Self-contained fixtures — not the live repo. Opt-in like `mcp`. |

```sh
./run.py --suite swe --harness graff-dev-old,graff-dev --model grok-4.6 -j 12
./run.py --suite core,rlm,swe --harness graff-dev-old,graff-dev -j 8
# Pi on the same SuperGrok seat (`npm i -g @earendil-works/pi-coding-agent`):
./run.py --suite swe --harness graff-dev,pi-xai --model grok-4.6 -j 6
# same SuperGrok-shaped A/B on the Codegraff gateway (set CODEGRAFF_API_KEY):
CODEGRAFF_API_KEY=cg_sk_… ./run.py --suite swe --harness graff-dev,pi-codegraff --model glm-5.3-flash -j 6
# same seat, other models (ADR 0047): deepseek-v4-flash, gemini-3.7-flash, kimi-k2.6
CODEGRAFF_API_KEY=cg_sk_… ./run.py --suite swe --harness graff-dev,pi-codegraff --model deepseek-v4-flash -j 6
# multi-harness in-house PR suite (OpenCode needs --dir; see harnesses.json):
./run.py --suite inhouse --harness graff-dev,grok,opencode --model grok-4.6 -j 1
```

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
summary table on stdout. The `usd` / `list$` column is **xAI list price**
from tokens (and hosted-tool invocations when reported), not SuperGrok's
`$0.0000` subscription footer. grok-4.6 uses the dual band
`$2/$0.50/$6` under 200k prompt tokens and `$4/$1/$12` for the whole
request at or above. `.sandboxes/` holds the materialized working dirs of
the last run for post-mortems; both are disposable.

## Hillclimb

`hillclimb.py` is the autoresearch-style loop: propose a harness change
(see `hillclimb/candidates.json`), run the same tasks against the
champion and grok-build, keep only a measured win on wall / first-token
latency / tool calls / tokens / list-price USD. It will not keep
grok-build's heap or a 4-tool catalog (ADR 0024). First keep:
`GRAFF_XAI_X_SEARCH=0` on `graff` / `graff-dev` (live table in
`hillclimb/baseline.md`).

```sh
./hillclimb.py self-test
./hillclimb.py score results/run-20260828-021606.jsonl
./hillclimb.py iterate --suite core --task exact-reply,fix-fib,file-ops
./hillclimb/plot_frontier.py results/run-….jsonl -o hillclimb/frontier.svg
# same-model charts from the 2026-08-30 live set:
#   hillclimb/frontier-spine-20260830.svg
#   hillclimb/frontier-inhouse-20260830.svg
```

## Harnesses

`harnesses.json` declares each harness as a command template plus parsers:

- `answer` — where the final answer text comes from (`stdout`,
  `grok-stream` for grok's `streaming-messages-json` result event, or
  `pi-json` for Pi's `--mode json` `message_end` text).
- `usage` — how to extract token counts (`graff-stderr` parses graff's
  `[usage]` line; `grok-stream` / `pi-json` read the harness event).
  Pi `first_out_s` is the first JSONL line (`session`), not TUI first paint.
  Pi `cost.total` is list-price; SuperGrok on graff is `$0.0000` flat-rate.
- `capabilities` — feature gates; a task listing `requires` a capability is
  skipped on harnesses that lack it (e.g. `output-schema` structured outputs).

Add a harness by adding an entry; add a model by passing `--model`.

Same-model grok-4.6 series: `graff-dev`, `grok`, `opencode` (needs xAI
auth), `dsh-grok` (needs `dsh` + an xAI key dsh will accept; 0.1.1-rc.2
catalog has no grok-4.6 — use `dsh-xai` / grok-4.5 for a live dsh point).
Mixed-model native defaults — `opencode-zen`, `dsh-deepseek` — are a
**different comparison**; do not read them as grok-4.6 list-price points.

`dsh` does not read graff/grok OAuth files. On this machine the SuperGrok
seat is attached locally (`python3 graff-evals/attach-dsh-xai-oauth.py
--install`); see [dsh-local-oauth.md](dsh-local-oauth.md). No token is
in git. `dsh-deepseek` still needs a DeepSeek key (none here).

## Tasks

Tasks span instruction-following, debugging, shell, data (JSON/CSV), text
extraction, refactoring, test-writing, git, long-context recall, structured
output, scatter-gather, and DeepSWE-shaped SWE fixes. The check runs in the
sandbox with `$ANSWER_FILE` pointing at the captured final answer and
`$TASK_ROOT` pointing at `graff-evals/` for held-out scripts.

Authoring rules that keep results comparable:

- The check must be deterministic and self-contained (`python3` + POSIX sh).
- Planted values (sums, counts, code words) live in the fixture, not the
  prompt, so the model must actually do the work.
- One behavior per task; keep prompts short and unambiguous.
