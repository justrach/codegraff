# Local prompt-policy learning

`graff learn` is an experimental, local-first engine for evolving one named
agent prompt. It implements a complete local cycle:

```text
active parent → deterministic mutation seeds → paired evaluation
              → Zig-side verification/aggregation → select → promote or reject
```

It does **not** infer semantic success from ordinary interactive traces, and it
does not turn behavioral telemetry into promotion authority. Mutators and
evaluators are explicit local adapters with pinned inputs and typed JSON
protocols.

## Safety defaults

- A normal `learn run` writes immutable evidence and recommends a command; it
  never changes the active policy.
- Automatic promotion requires both `auto.enabled: true` in the immutable
  configuration **and** an explicit `learn run --auto`. A holdout suite is also
  mandatory.
- Activation uses a content-addressed transaction followed by an atomically
  replaced active ref. File data and containing directories are synchronized
  before publication. Every load validates the complete transaction chain.
- A run is promotable only while its parent genome, generation, and transaction
  ID exactly match the active ref. Rolling back to identical parent bytes does
  not make old evidence fresh again.
- Full 64-character lowercase IDs are required; abbreviated IDs are rejected.
- Local learned policy activation outranks built-in, personal, project, and
  subsequently fetched remote-fleet prompts of the same name.

## Commands

```text
graff learn init --parent PATH --config PATH
graff learn run [--candidates N] [--repetitions N] [--auto] [--lock-timeout-ms N]
graff --learning-privacy aggregate learn run [--candidates N] [--repetitions N] --submit
graff --learning-privacy aggregate learn submit RUN_ID [--lock-timeout-ms N]
graff learn status [--lock-timeout-ms N]
graff learn promote RUN_ID [--lock-timeout-ms N]
graff learn rollback [--to GENOME_ID] [--lock-timeout-ms N]
graff learn verify [--lock-timeout-ms N]
graff learn hash ABSOLUTE_PATH
graff learn help
```

All configured paths must be canonical absolute paths and must use the exact
spelling returned by the platform's `realPath` operation (including Windows
prefix/case conventions). Use `learn hash` to produce the raw SHA-256 pin for a
tool, declared input, or suite.

A typical manual workflow is:

```sh
graff learn init --parent /absolute/parent.md --config /absolute/learn.json
graff learn run
graff learn promote <complete-run-id>
graff learn status
graff learn rollback
```

Only one learning operation runs at a time. `--lock-timeout-ms` controls how
long a command waits for the local engine lock, up to 600,000 ms.

`run --submit` performs mutation, paired primary/holdout grading, immutable
storage, and aggregate publication in one command. `submit RUN_ID` re-verifies
and retries an already stored run. Both use `GRAFF_SCORE_KEY_FILE`, falling back
to `~/.simple-harness/score.key`, plus the normal OTLP endpoint configuration.
A retry is idempotent at the collector.
Neither form promotes the selected candidate; use the separate manual or
two-key automatic promotion policy described above.

For multiple candidates, execution is a barriered tournament:

1. every mutation arm runs concurrently;
2. every unique arm runs the same primary suite concurrently with common pair
   seeds and one fixed evaluator cohort;
3. ranking minimizes critical regressions, then maximizes observed correctness,
   then minimizes measured tool calls, latency, cost, and prompt size;
4. only that primary winner is evaluated on the holdout; and
5. promotion remains a separate manual action unless the configured two-key
   automatic policy is explicitly enabled and all statistical gates pass.

Run records use `codegraff.learn.run.v2` and persist the primary winner even
when evidence is underpowered. Missing tool-call instrumentation is recorded as
unknown and cannot masquerade as zero calls. `GRAFF_NO_TELEMETRY=1` and
`GRAFF_FLEET=off` both block explicit aggregate submission.

The bundled model-backed example adapters fail safely around transient or
malformed model output. A mutation gets one corrective turn after deterministic
size/invariant validation; a second failure becomes an unchanged-parent
non-contender rather than aborting other arms. An evaluation turn that ends
without gradeable evidence gets one bounded retry in a newly initialized task
directory, so partial file changes cannot leak into the retry.

The root model also receives an approval-gated `learn_candidate` tool when it
runs in a configured workspace. The tool bundles `run --submit` into one
model-facing action. In Local mode it shows the aggregate payload categories
and requires a one-shot confirmation that `--yolo` cannot bypass. It accepts
only candidate/repetition limits, is unavailable to subagents, and exposes no
promotion option. This consent controls learning telemetry; it does not make a
networked mutator local. A configured model adapter may send the parent prompt
and mutation instruction to its declared provider, which the confirmation
discloses separately.

## Configuration

The configuration is copied into `.graff/learn`, content-addressed, and treated
as immutable. Unknown JSON fields are rejected.

```json
{
  "schema": "codegraff.learn.config.v1",
  "agent_name": "reviewer",
  "agent_description": "locally learned review policy",
  "mutation_instruction": "change one behavior while preserving strengths",
  "mutator": {
    "program": "/absolute/mutator-adapter",
    "sha256": "<64 lowercase hex>",
    "args": ["/absolute/mutation-rules.json"],
    "inputs": [
      {"path": "/absolute/mutation-rules.json", "sha256": "<64 lowercase hex>"}
    ],
    "pass_env": ["MODEL_API_KEY"]
  },
  "evaluator": {
    "program": "/absolute/evaluator",
    "sha256": "<64 lowercase hex>",
    "args": [],
    "inputs": [],
    "pass_env": []
  },
  "evaluation_suite": {
    "path": "/absolute/primary-suite.json",
    "sha256": "<64 lowercase hex>"
  },
  "holdout_suite": {
    "path": "/absolute/holdout-suite.json",
    "sha256": "<64 lowercase hex>"
  },
  "limits": {
    "genome_bytes": 1048576,
    "request_bytes": 1048576,
    "response_bytes": 4194304,
    "stdout_bytes": 65536,
    "stderr_bytes": 65536,
    "mutator_timeout_ms": 300000,
    "evaluator_timeout_ms": 1800000
  },
  "gate": {
    "alpha_ppm": 50000,
    "minimum_delta_ppm": 50000,
    "minimum_pairs": 20,
    "economy_gate_enabled": false,
    "promotion_mode": "correctness",
    "minimum_tool_reduction_ppm": 100000,
    "minimum_economy_pairs": 8,
    "default_candidates": 1,
    "default_repetitions": 1
  },
  "auto": {"enabled": false},
  "cohort": {
    "provider": "anthropic",
    "model": "claude-example",
    "task_family": "code-review",
    "adapter_version": "v1",
    "verifier_version": "v1"
  }
}
```

`holdout_suite` is optional for manual operation and required for `--auto`.
Cohort fields are exact labels used to prevent unlike evaluations from being
compared as though they were interchangeable.

### Pinned program snapshots

The engine does not hash a tool and then reopen that original pathname for
execution. For each invocation it:

1. Opens the configured program and declared inputs without following the final
   symlink.
2. Reads and hashes each through that same handle.
3. Rejects a digest mismatch, non-regular file, oversized file, non-canonical
   path, and (on POSIX) group/world-writable source.
4. Writes the verified bytes into the private per-invocation scratch directory.
5. Executes only the private program snapshot.

If an argument exactly equals a declared input's original path, the engine
rewrites that argument to the corresponding private snapshot. Declared inputs
are also exposed as `GRAFF_LEARN_INPUT_0`, `GRAFF_LEARN_INPUT_1`, and so on,
with the count in `GRAFF_LEARN_INPUT_COUNT`.

The configured program must be directly executable **after relocation** while
retaining only its filename extension. Supported forms are a standalone
relocatable native adapter (a native `.exe` on Windows) or, on POSIX, an
executable script with a shebang. Do not configure an installed interpreter such
as `python3` as `program`: copying only that binary can separate it from adjacent
runtime files and make it unusable. Instead, make the adapter script itself
executable with a shebang, or provide a standalone launcher.

A pinned executable does not imply that its shebang interpreter, dynamic
libraries, imports, subprocesses, network responses, adjacent resources, or
undeclared files are pinned. Those runtime dependencies remain trusted external
components; adapters that discover resources relative to their installation
path are not supported by the Phase 1 snapshot model.

## Suite schema and statistical unit

A suite is pinned JSON:

```json
{
  "schema": "codegraff.learn.suite.v1",
  "suite_id": "review-v1",
  "cases": [
    {"id": "case-001", "critical": true, "payload": {"fixture": "..."}},
    {"id": "case-002", "payload": null}
  ]
}
```

Case IDs must be unique. The evaluator receives a verified private copy as
`suite.json`; the evaluation request never directs it back to the configured
suite pathname.

`default_repetitions` controls repeated measurements of each case. Repetitions
are **not** independent statistical samples. For the exact one-sided paired
sign test, all repetitions of one case are collapsed into one unit by comparing
aggregate parent and child pass counts for that case. Therefore:

- `minimum_pairs` means the minimum number of distinct suite cases.
- Repeating one case cannot satisfy the minimum or manufacture significance.
- Any parent-pass/child-fail result on a critical case is a hard rejection.
- Pass-rate and mean-score deltas still use all repeated measurements.
- The significance threshold is Bonferroni-corrected by the number of planned
  candidates.
- Correctness gates run before cost is used as a tie-breaker.

`promotion_mode` preregisters either `correctness` or `economy`; primary and
holdout cannot clear different endpoints. Economy mode also requires
`economy_gate_enabled`, zero case-level correctness losses, no mean-score
regression, measured calls, the configured aggregate call reduction, and a
separately Bonferroni-corrected per-case tool-call sign test.
`minimum_economy_pairs` counts only discordant cases (wins plus losses), since
tool-call ties provide no information to that sign test.
Latency is reported and used only as a ranking tie-breaker; it is not promotion
evidence because wall-clock measurements are comparatively noisy.

After each run, the CLI prints a prompt-free aggregate summary for every
candidate: parent and child pass counts, effect size, paired wins/losses/ties,
p-value, tool-call reduction and its per-case sign test, latency, cost movement,
prompt size, primary/holdout gate results, and the final decision.
This lets a user or the root model distinguish a harmful candidate from a
promising but underpowered result without weakening the promotion gate.

## Adapter protocols

Programs are invoked directly, never through a generated shell command:

```text
<private-program-snapshot> <configured-args...> mutate   request.json response.json
<private-program-snapshot> <configured-args...> evaluate request.json response.json
```

The child working directory is the private scratch directory. `HOME` and temp
variables point inside it; the environment is replaced with a small baseline
plus explicitly listed `pass_env` values. Standard output/error, response size,
and direct-child execution time are bounded. These limits are not OS resource
isolation: they do not cap CPU, memory, process count, or reliably terminate
descendants started by an adapter.

### Mutation

The request has schema `codegraff.learn.mutation.request.v1`:

```json
{
  "schema": "codegraff.learn.mutation.request.v1",
  "trial_id": "<id>",
  "candidate_index": 0,
  "seed": "<deterministic id>",
  "parent": {"id": "<genome id>", "path": "parent.genome"},
  "child_path": "child.genome",
  "maximum_bytes": 1048576,
  "instruction": "..."
}
```

The mutator writes `child.genome` and responds with
`codegraff.learn.mutation.response.v1`:

```json
{
  "schema": "codegraff.learn.mutation.response.v1",
  "trial_id": "<same id>",
  "candidate_index": 0,
  "parent_id": "<same parent id>",
  "child_path": "child.genome",
  "child_sha256": "<raw SHA-256 of the exact child bytes>",
  "description": "optional bounded description"
}
```

The engine rejects the response unless `child_sha256` matches the exact bytes it
stores as the candidate genome. Promotion rechecks that binding from immutable
evidence.

### Paired evaluation

The request uses `codegraff.learn.evaluation.request.v1` and includes the trial,
candidate, exact cohort ID, suite hash, `suite_path: "suite.json"`, parent and
child IDs/relative files, repetition count, and ordered pairs:

```json
{"case_id": "case-001", "seed": "<deterministic id>", "critical": true}
```

The response uses `codegraff.learn.evaluation.response.v1`, repeats the envelope
IDs, and returns exactly one ordered result per requested pair:

```json
{
  "case_id": "case-001",
  "seed": "<same seed>",
  "parent_pass": true,
  "child_pass": true,
  "parent_score_ppm": 900000,
  "child_score_ppm": 950000,
  "parent_cost_micros": 100,
  "child_cost_micros": 90,
  "parent_latency_ms": 10,
  "child_latency_ms": 9
}
```

Costs and latencies are optional and default to zero. The Zig engine validates
the envelope, ordering, bounds, deterministic seeds, trial derivation, and every
stored aggregate again before promotion. The trial identifier binds the pinned
configuration, parent genome, exact parent generation and transaction, and a
fresh nonce; rolling back to identical parent bytes cannot rebind earlier
evidence to the new transaction.

## Local store, activation, and rollback

The private store is rooted at `.graff/learn`:

```text
VERSION
config.json
configs/         immutable configurations
genomes/         immutable prompt bytes
evidence/        immutable adapter requests/responses
runs/            immutable verified run records
transactions/    immutable activation history
refs/active.json mutable atomic active ref
locks/engine.lock
tmp/             per-invocation private scratch
```

Directories are mode `0700` and files mode `0600` on POSIX. Addressed objects
use domain-separated SHA-256 IDs, so the same bytes in two object classes do not
share an ID. Immutable writes use exclusive atomic publication. On POSIX,
promotion writes and synchronizes the transaction first, then atomically
replaces `refs/active.json` and synchronizes its directory; synchronization
errors fail the command.

Windows synchronizes file contents and uses atomic replacement, but the Zig I/O
API does not portably flush directory handles. Graff therefore skips the
post-rename directory flush on Windows rather than failing every operation with
`ACCESS_DENIED`; its power-loss guarantee is weaker. Windows files and scratch
directories also inherit the workspace/temp-directory ACLs instead of Graff
installing a restrictive DACL. Use a workspace and temporary directory whose
ACLs are private to the account. Across every platform, stable-media behavior
ultimately depends on the OS, filesystem, and device.

`rollback` creates a new transaction; it never rewinds or deletes history. By
default it selects the immediately previous active genome. `--to` accepts only a
full genome ID present in validated ancestry. Promotion and `learn verify`
revalidate the configured source pins; changing or deleting an adapter or suite
therefore fails closed even when the addressed run/evidence objects still exist.

## Trust and privacy boundaries

Scratch isolation and environment scrubbing are **not an OS sandbox**. Mutator
and evaluator processes run with the invoking user's authority. They can read or
modify anything that user can, inspect the holdout and learning store, access
explicitly passed credentials, or use the network. A configured holdout is an
independent gate against ordinary overfitting, not a secret from a malicious or
colluding adapter. Do not run adapters you do not trust; use an external sandbox
when stronger isolation is required.

Learning artifacts and prompt genomes remain local by default. Submission also
requires an aggregate-or-higher learning ceiling, selected with
`--learning-privacy aggregate`, `GRAFF_LEARNING_PRIVACY=aggregate`, or
`/privacy aggregate`. The root-only `learn_candidate` tool can instead request
one explicit bundled aggregate submission without changing the session mode. An explicit `--submit` or
`learn submit` then publishes only the existing signed score envelope:
short parent/child fingerprints, aggregate pass rate, run/suite/cohort metadata,
and content-addressed evidence IDs. It does not publish prompt text, tasks,
adapter input/output, repository data, or local traces. The collector exposes a
retry-safe receipt at `GET /v1/learning/<RUN_ID>`.

Once activated, the learned prompt is used like any other agent prompt:

- it is sent to the selected model provider when that agent runs;
- prompt fingerprints stay in local trajectories and enter learning telemetry
  only in aggregate-or-higher mode;
- provider/model identifiers and other ordinary telemetry follow the existing
  telemetry policy; and
- local trace/session files retain their documented behavior.

Neither local behavioral JSONL nor best-effort telemetry is accepted as trusted
promotion evidence.

## Verification and regression test

`graff learn verify` validates active configuration, pins, object hashes, active
ref, current genome, and complete transaction ancestry. It does not execute the
adapters or prove their semantic quality.

The checked-in deterministic end-to-end fixture exercises manual promotion,
rollback, stale-run rejection, trial derivation, mutation-output binding,
private tool/suite snapshots, and explicitly gated automatic promotion without
network access:

```sh
zig build
python3 tests/learn_e2e.py --graff zig-out/bin/graff
python3 tests/learn_tournament_e2e.py --graff zig-out/bin/graff
python3 tests/learn_graff_adapters.py
```

For an explicitly consented model-backed trial,
`examples/prepare_graff_tournament.py` creates an isolated workspace, a newly
randomized five-case holdout, and pinned four-arm configuration. The shipped
arm map uses `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, and
`gpt-5.4-mini`; all prompts are evaluated by the same pinned cohort. The
mutator intentionally sends the parent prompt to those providers, while inner
agent telemetry is disabled and only the five signed aggregate tournament
grades are submitted. The generated config keeps automatic promotion off.

## Collective learning: aggregate receipts, not promotion authority

A privacy-preserving collective layer should exchange verified artifacts and
attestations, not raw repositories, prompts, tool arguments, or local traces.
A safe design has these components:

1. **Content-addressed policy bundles.** A bundle identifies parent and child,
   configuration/suite hashes, capability requirements, and cohort metadata.
2. **Signed evaluator attestations.** Trusted evaluators sign exact bundle,
   verifier, suite, result, cost, and harness-version claims. Local engines
   verify signatures and still rerun required checks.
3. **Cohort aggregation.** Compare only matching task family, verifier,
   provider/model capability class, adapter version, and harness version.
   Preserve MAP-Elites niches rather than electing one global prompt.
4. **Central hidden holdout.** For high-value shared promotion, an independent
   service evaluates a submitted content hash without exposing holdout material
   to mutators. Local configured holdouts alone are not secret.
5. **Abuse resistance.** Rate limits, per-install/per-signer contribution caps,
   robust aggregation, replay protection, evaluator reputation, and explicit
   anti-Sybil policy precede any fleet-wide recommendation.
6. **Safe rollout.** Signed manifests, local allowlists, canary cohorts,
   monotonic generation constraints, revocation lists, and one-command rollback
   are mandatory. Remote data remains advisory unless the user separately opts
   into a defined activation policy.
7. **Privacy-preserving visibility.** Public views expose thresholded aggregate
   cohort statistics, never raw run IDs, content, prompts, repositories, or
   individual behavioral rows.

D1 can serve as a small control plane for bundle manifests, signer keys,
revocations, and aggregate pointers. Larger evidence/aggregation workloads
belong behind a queue and analytical store rather than synchronous D1 writes.
The signed aggregate score/receipt path is implemented. Prompt distribution,
central hidden-holdout inference, and collective promotion authority are not:
backend results remain advisory, and only the local verified promotion path can
change the active policy.
