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

`--suite` selects which tasks run (`all` is core+rlm+swe; `mcp` / `inhouse` / `live` are opt-in):

| suite | what it measures |
|---|---|
| `core` | sequential single-file work (instruction, debug, git, schema, …) |
| `rlm` | scatter-gather / multi-file reads (where default rlm can overlap) |
| `swe` | DeepSWE-shaped multi-file bugfixes, distilled from [deepswe.datacurve.ai/run](https://deepswe.datacurve.ai/run) (no Harbor/Docker) |
| `mcp` | Linear-shaped fixture MCP (Blacksmith code-mode + muscle memory). Always `--no-lean` (`graff-dev-nolean`): lean is a different catalog and is not on the front. |
| `inhouse` | Distilled PR fixtures with SPEC.md. Cheap harness A/B — not the live badge. Opt-in. |
| `live` | Capped 12 gated PRs, no SPEC.md. Pass @ n=3; list$ on passing reps only. See [LIVE.md](../artifacts/graff-evals-live/LIVE.md). |

Published live board (2026-09-09, five harnesses on grok-4.6 SuperGrok):
[artifacts/graff-evals-live/RECEIPT.md](../artifacts/graff-evals-live/RECEIPT.md).
Rebuild the card with `python3 plot_live.py --from-jsonl` when `results/` is present.

```sh
./run.py --suite swe --harness graff-dev-old,graff-dev --model grok-4.6 -j 12
./run.py --suite core,rlm,swe --harness graff-dev-old,graff-dev -j 8
# Pi on the same SuperGrok seat (`npm i -g @earendil-works/pi-coding-agent`):
./run.py --suite swe --harness graff-dev,pi-xai --model grok-4.6 -j 6
# same SuperGrok-shaped A/B on the Codegraff gateway (set CODEGRAFF_API_KEY):
CODEGRAFF_API_KEY=cg_sk_… ./run.py --suite swe --harness graff-dev,pi-codegraff --model glm-5.3-flash -j 6
# same seat, other models (ADR 0047): deepseek-v4-flash, gemini-3.7-flash, kimi-k2.6
CODEGRAFF_API_KEY=cg_sk_… ./run.py --suite swe --harness graff-dev,pi-codegraff --model deepseek-v4-flash -j 6
# same seat, OpenCode vs graff (ADR 0053; needs `opencode` on PATH):
CODEGRAFF_API_KEY=cg_sk_… ./run.py --suite swe --harness graff-dev,opencode-codegraff --model deepseek-v4-flash -j 6
# multi-harness in-house PR suite (OpenCode needs --dir; see harnesses.json):
./run.py --suite inhouse --harness graff-dev,grok,opencode --model grok-4.6 -j 1
# live PRs (no SPEC.md). Smoke gates first: python3 verify_live_gates.py --only graff-195
./run.py --suite live --harness graff-dev --reps 3 -j 1
# same SuperGrok seat, other harnesses (OpenCode / Pi / exo local-process):
./run.py --suite live --harness opencode,pi-xai,exo --reps 3 -j 1
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

Same-model grok-4.6 series: `graff-dev`, `grok`, `opencode` / `pi-xai`
(SuperGrok JWT + `X-XAI-Token-Auth`), `exo` (exoharness CLI,
`--provider local-process`, no Docker; same header via a localhost
proxy), `dsh-grok` (needs `dsh` + an xAI key dsh will accept; 0.1.1-rc.2
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

## Paired model measurements

For gateway comparisons, supply `CODEGRAFF_API_KEY` through the environment
without putting the key in commands or reports. Both arms use fresh HOME
folders containing the explicit saved provider/model selection; the runner
removes `--model` so production startup loads that provider's catalog. No
other provider credentials, user skills, saved sessions, or MCP configuration
are inherited. Root API trace model identity must match for a run to qualify.

```sh
python3 graff-evals/run.py --suite swe --task config-parse \
  --harness graff-dev --provider codegraff --model gpt-6-astra \
  --binary /path/to/baseline/graff --arm baseline --reps 3 -j 1 \
  --output-root /tmp/graff-astra-baseline
```

Use the identical command with the candidate binary, candidate arm, and a new
output directory. Match build optimization and effort across arms. Start with
a fixed, explicitly selected model set to check transport and measurement
completeness, then expand the task set while keeping those model routes fixed.
Availability failures remain failed/incomplete cells, never zero-cost wins. Interleave baseline/candidate repetitions to reduce cache/order bias.

Receipts include binary SHA-256, evaluation-working-tree revision and patch
hash, untracked source hashes, task hash, requested provider/model, arm, wall
time, and harness usage. Raw logs stay in private run directories. Visible
verifiers must remain unchanged; held-out graders run from outside the task
workspace after the model exits. The final cumulative `[usage]` footer supplies
metered cost; dollars in tool output or prose are ignored. Missing/unpriced
usage stays unknown. Direct-provider list prices are not applied to gateway
calls, and aggregate multi-request tokens cannot determine long-context price
bands. Compare costs only when both binaries use the same validated accounting.

For an existing Codex subscription, use `--provider codex` and supply
`CODEX_HOME` as the explicit authentication-directory path. The runner checks
that its `auth.json` exists without reading or copying its contents, inherits
only that path, and excludes gateway and other API keys. The same fresh HOME
and saved-selection path applies. Subscription calls are labelled separately;
the metered subtotal is retained, while total USD stays unknown rather than
presenting a flat subscription as free inference. API list-price estimates
require a separately validated model/rate snapshot.

### Validated fixture versions

`validated` (v1) remains frozen for existing result comparisons. Its visible and
held-out checks do not cover every SPEC requirement, including the `Validated`
export and empty-error `Invalid` combinations; a v1 pass is limited to that grader.

`validated-contract-v2` is a separate task and fixture with explicit alias
classmethod semantics, collection wrapping examples, and empty-Invalid
short-circuit checks. Its held-out checker independently verifies these and
remaining named contract behaviors. Compare both harness arms on the same task
version; do not pool v1 and v2 passes or rewrite earlier raw results.

### Actual request capture

Add `--capture-requests` to retain serialized request bodies in a private
`requests/` directory beside the sandboxes. Each harness process uses a unique
subdirectory. The receipt records body and rendered instruction/tool fingerprints;
it does not contain the request text. Require `capture_evidence_ok` before using
these fingerprints: empty, malformed, or gapped captures fail this check. Sequence
order is per-process body construction, not global HTTP attempt order; transport
retries can reuse a body. Capture is opt-in and identical in both
arms; do not publish raw request files. Standalone harness diagnostics use
`GRAFF_REQ_STATS=1` plus `GRAFF_REQ_DUMP_DIR`; statistics alone do not write files.

A matching fingerprint establishes only matching request components. Prove cache
reuse with returned cached-token usage. For warm-prefix comparisons, predetermine
warmups, preserve their costs separately, alternate arm order, and retain every
measured failure. Neither a warmup nor a stable cache key guarantees a hit.
