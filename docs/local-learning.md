# Local prompt-policy learning

`graff learn` is an experimental, local-first engine for evolving one named
agent prompt. It implements a complete local cycle:

```text
active parent → deterministic mutation seeds → paired evaluation
              → Zig-side verification/aggregation → select → promote or reject
              → the promoted genome becomes this workspace's root prompt
```

## Closing the loop in one command

```sh
graff learn init            # generate the whole pinned setup for this workspace
```

A bare `init` writes `.graff/learn-kit`: the bundled mutation/evaluation
adapters, a 60-case primary suite, a freshly randomized 40-case holdout, a
parent genome snapshotted from this build's root prompt, a copy of the running
binary, and the pinned configuration that ties them together. It then
initializes the store exactly as a hand-written `--parent/--config` pair would.
`--provider`/`--model` pick what the adapters drive (default: this session's
saved model, else any provider with a credential, else the hosted default), and
`--candidates N` sets the arms per trial.

Requirements and consequences worth knowing:

- `python3` must be on `PATH`; the bundled adapters are Python and the suite
  generator runs once at init.
- The binary is *copied* into the kit and pinned there, so `graff update` never
  invalidates the configuration. The kit keeps evaluating that copy until you
  re-initialize.
- The generated configuration enables the two-key automatic promotion policy
  (`auto.enabled`), so a trial that clears every statistical gate promotes
  without a human step.
- Re-running `init` in an initialized workspace fails instead of rewriting the
  pinned files out from under the existing store.

## Automatic trials

Once a workspace has a store, sessions feed it. When a session that made at
least one model call ends, graff counts it and — every 5 sessions, and at most
once every 6 hours — starts one detached trial in the background:

```text
↺ learning trial started in the background — `graff learn status`, log .graff/learn/auto.log
```

The trial is an ordinary `graff learn run --auto`, resuming an existing
checkpoint rather than restarting it, and publishing prompt-free aggregate
grades when learning privacy and a local signing key both allow it. It holds
the engine lock, so a second session cannot start a competing trial. Turn the
trigger off with `GRAFF_LEARN_AUTO=off`.

Budget it deliberately: one trial runs the parent once over the whole primary
suite plus every candidate arm over the same suite, so the default two-arm
configuration is roughly 180 short agent runs against the configured learning
model. Point `learn init --provider/--model` at a cheap model, or use
`--candidates 1`, before letting the trigger run against an expensive one.

## The learned root policy

A promoted genome named `graff-root` (what `learn init` generates) becomes the
root system prompt for later sessions in that workspace, not just a subagent
persona. Generation 0 — the untouched snapshot of some build's own prompt —
never takes over, so an initialized-but-unpromoted store changes nothing.
Sessions using a learned policy say so at startup:

```text
root policy: learned generation 3 (9f2c1a7b0d44)
```

`--system-prompt` still wins, `GRAFF_LEARNED_PROMPT=off` ignores the learned
policy for one session, and `graff learn rollback` reverts the promotion
itself.

## Credentials

Adapters run with a scrubbed environment and a scratch `HOME`, so a `graff
login` credential on disk is invisible to them. `learn run` resolves the
credential names the configuration already declares in `pass_env` from the same
local key store the session uses, and passes only those. An undeclared name is
never resolved, and an exported value always wins.

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
graff learn run [--candidates N] [--repetitions N] [--resume | --restart] [--auto] [--show-adapter-stderr] [--lock-timeout-ms N]
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

Expensive tournament progress is atomically checkpointed after mutation, the
shared parent baseline, every completed primary arm, and holdout completion. If
an adapter fails or the process exits, rerun with `learn run --resume` using the
same candidate/repetition/automatic-promotion options. Resume re-derives the
trial ID and re-verifies every referenced immutable genome and evidence object
before skipping completed work. A normal `learn run` refuses to overwrite a
recoverable checkpoint. `--restart` explicitly discards it and starts a new
trial; it does not unconsume a hidden suite that was already exposed.
`learn status` reports the pending trial ID plus completed primary and holdout
arm counts without exposing prompts, cases, or adapter output. `learn verify`
also re-verifies any pending checkpoint and reports `pending_verified: true`;
ordinary status leaves a present checkpoint explicitly unverified.
For a new trial, a previously consumed holdout is detected before any mutator
or evaluator process starts; only an exact checkpoint resume may reuse its own
reservation.

Each mutation arm gets one bounded retry after a timeout or nonzero exit. The
retry keeps the registered candidate index and seed but uses a new private
scratch directory, so partial files from the failed process are never reused.
Adapter stderr and executable paths are hidden by default because failures may
contain prompts, repository text, credentials, or usernames. A human debugging
in a local terminal can explicitly add `--show-adapter-stderr`; the
model-facing `learn_candidate` action never exposes nested-process stderr.

`run --submit` performs mutation, paired primary/holdout grading, immutable
storage, and aggregate publication in one command. `submit RUN_ID` re-verifies
and retries an already stored run. Both use `GRAFF_SCORE_KEY_FILE`, falling back
to `~/.simple-harness/score.key`, plus the normal OTLP endpoint configuration.
A retry is idempotent at the collector.
Neither form promotes the selected candidate; use the separate manual or
two-key automatic promotion policy described above.

`delete-remote RUN_ID` removes that run's aggregate backend receipt without
touching local genomes, evidence, or history. Its bearer capability is derived
from the immutable run nonce and the score key; the nonce stays local and the
collector stores only a verifier. Deletion remains available when
`GRAFF_NO_TELEMETRY=1`, `GRAFF_FLEET=off`, or learning privacy is Local, so
revoking consent never prevents removing data that was already submitted.

For multiple candidates, execution is a barriered tournament:

1. every mutation arm runs concurrently;
2. every unique arm runs the same primary suite concurrently with common pair
   seeds and one fixed evaluator cohort;
3. ranking minimizes child critical failures and critical regressions, then
   maximizes observed child correctness, then minimizes measured tool calls,
   cost, and prompt size;
4. only that primary winner is evaluated on the holdout; and
5. promotion remains a separate manual action unless the configured two-key
   automatic policy is explicitly enabled and all statistical gates pass.

Run records use `codegraff.learn.run.v3`, which stores one verified primary
parent baseline shared by all candidate arms, and persist the primary winner
even when evidence is underpowered. Missing tool-call instrumentation is
recorded as unknown and cannot masquerade as zero calls. Latency remains in the
report but is deliberately excluded from ranking and promotion evidence.
`GRAFF_NO_TELEMETRY=1` and `GRAFF_FLEET=off` both block explicit aggregate
submission; they deliberately do not block `delete-remote`.

The bundled model-backed example adapters fail safely around transient or
malformed model output. A mutation gets one corrective turn after deterministic
size/invariant validation; a second failure becomes an unchanged-parent
non-contender rather than aborting other arms. An evaluation turn that ends
without gradeable evidence gets one bounded retry in a newly initialized task
directory, so partial file changes cannot leak into the retry. Each evaluator
side also keeps a request-bound, prompt-free attempt journal in private scratch.
It durably records observed latency, tool calls, and cost, plus a completed side
result. After an evaluator crash, the retry restores that usage and does not
repeat a completed side. The journal is cleared only after paired progress is
durably committed.

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
    {"id": "case-001a", "statistical_unit_id": "scenario-001", "critical": true, "payload": {"fixture": "..."}},
    {"id": "case-001b", "statistical_unit_id": "scenario-001", "critical": true, "payload": {"fixture": "..."}},
    {"id": "case-002", "payload": null}
  ]
}
```

Case IDs must be unique. The evaluator receives a verified private copy as
`suite.json`; the evaluation request never directs it back to the configured
suite pathname.

A configured holdout must have a different content digest and `suite_id`, and
its declared statistical-unit IDs must be disjoint from the primary suite.
Initialization and every later verification boundary enforce this before the
hidden suite is exposed. These checks prevent accidental reuse; authors must
still ensure differently named units are semantically independent.

`default_repetitions` controls repeated measurements of each case. Repetitions
and semantically cloned cases are **not** independent statistical samples. Set
the optional `statistical_unit_id` to the same value for related cases. Suites
that omit it remain compatible: the case ID becomes the effective unit ID. For
the exact one-sided paired sign test, all rows in one effective unit are
collapsed by comparing aggregate parent and child results. Therefore:

- `minimum_pairs` means the minimum number of independent statistical units.
- Repeating or cloning one scenario cannot satisfy the minimum or manufacture
  significance.
- Initialization rejects an underpowered primary or holdout suite before any
  adapter/model call. A trial also rechecks that even an all-win result could
  clear the exact p-value after correction for its actual candidate count;
  otherwise it fails with `InsufficientSignificancePower`. Stored requests bind
  every pair to its effective unit.
- Any parent-pass/child-fail result on a critical case is a hard rejection.
- Pass-rate and mean-score deltas still use all repeated measurements.
- The significance threshold is Bonferroni-corrected by the number of planned
  candidates.
- Correctness gates run before cost is used as a tie-breaker.

`promotion_mode` preregisters either `correctness` or `economy`; primary and
holdout cannot clear different endpoints. Economy mode also requires
`economy_gate_enabled`, zero raw parent-pass/child-fail rows, no mean-score
regression, measured calls, the configured aggregate call reduction, and a
separately Bonferroni-corrected per-case tool-call sign test.
`minimum_economy_pairs` counts only discordant statistical units (wins plus
losses), since tool-call ties provide no information to that sign test. The
suite must contain at least that many possible units before evaluation starts.
Latency is reported but is neither a ranking tie-breaker nor promotion evidence
because wall-clock measurements are comparatively noisy.

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
and execution time are bounded. Learning adapters run in an owned POSIX process
group or Windows Job Object, so ordinary descendants are terminated on timeout,
orchestrator error, and parent exit. This is process-lifecycle containment, not
OS resource isolation: it does not cap CPU, memory, or process count, prevent a
process from deliberately escaping the owned tree, or revoke remote provider
work that was already accepted.

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
evidence. `description` is retained only in that local evidence for debugging;
because it is adapter-controlled and may contain sensitive or adversarial text,
aggregate summaries and the model-facing `learn_candidate` result never render
it.

### Paired evaluation

The request uses `codegraff.learn.evaluation.request.v1` and includes the trial,
candidate, exact cohort ID, suite hash, `suite_path: "suite.json"`, parent and
child IDs/relative files, repetition count, and ordered pairs. The optional
statistical-unit field is omitted for legacy one-case-per-unit suites:

```json
{"case_id": "case-001a", "statistical_unit_id": "scenario-001", "seed": "<deterministic id>", "critical": true}
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

The pair seed is a deterministic evidence identity shared across arms. An
adapter backed by a seed-capable model API may also use it to control sampling.
The bundled Codex Responses evaluator cannot: the Responses API has no sampling
seed parameter, so it uses the value for parent/child order counterbalancing and
treats model generations as stochastic repetitions. Those repetitions remain
inside their case's statistical unit and never increase independent power.

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
refs/pending.json mutable atomic in-flight tournament checkpoint
locks/engine.lock
tmp/             per-invocation private scratch
```

Directories are mode `0700` and files mode `0600` on POSIX. Addressed objects
use domain-separated SHA-256 IDs, so the same bytes in two object classes do not
share an ID. Immutable writes use exclusive atomic publication. On POSIX,
promotion writes and synchronizes the transaction first, then atomically
replaces `refs/active.json` and synchronizes its directory; synchronization
errors fail the command.

The pending ref is recovery state, not promotion authority. It contains only
lineage, immutable object IDs, and aggregate comparisons. Resume validates the
active parent/configuration, deterministic trial derivation, mutation evidence,
shared baseline projection, every completed primary comparison, sole winner,
and any holdout reservation/comparison. A holdout reservation can be reused
only by its exact original trial, so recovery cannot switch candidates or start
a new tournament against the same exposed suite.

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

Prompt genomes, suites, evidence, and traces never leave the machine. Signed
aggregate grades do: the learning ceiling defaults to aggregate, so an explicit
`--submit`, `learn submit`, or automatic trial publishes them when a local
signing key exists. `--learning-privacy local`, `GRAFF_LEARNING_PRIVACY=local`,
`/privacy local`, `GRAFF_FLEET=off`, and `GRAFF_NO_TELEMETRY=1` each turn that
off, and the first session that could contribute says so once per machine.

The root-only `learn_candidate` tool can instead request one explicit bundled
aggregate submission without changing the session mode. An explicit `--submit` or
`learn submit` publishes the existing signed score plus a separately signed
`codegraff.learn.grade.v3` receipt: fixed aggregate pass/delta/significance,
regression, tool/cost/latency, recomputed behavioral score, gate (including economy-gate enablement), and
eligibility fields; short parent/child fingerprints; run/suite/cohort metadata;
and content-addressed evidence IDs. It
does not publish prompt text, tasks, adapter input/output, repository data, raw
error details, paths, or local traces.
It also omits the ordinary telemetry installation identifier and platform
metadata, so separate explicit submissions cannot be linked through a stable
client identity. The collector ignores legacy learning install identifiers.
Buffered learning events recheck the current privacy mode and fleet kill switch
at send time, so lowering consent suppresses already queued events. SDK clients
apply the same policy to each harness instance, honor `--no-telemetry` and
`GRAFF_FLEET=off`, allowlist fixed event kinds/provider classes, and fingerprint
unexpected free-form labels before egress. The collector independently validates
field ranges and cross-field invariants after both signatures, stores learning
comparisons outside fleet fitness, and exposes them at the retry-safe
`GET /v1/learning/<RUN_ID>` receipt endpoint.

The bundled evaluator transfers parent and child prompts to its local Graff
process through the JSON stdin control channel, not command-line arguments, so
the full prompt is not exposed by ordinary process listings.

Each inner evaluation enables a rich behavioral trace only inside its disposable
private scratch workspace while disabling network telemetry. After a terminal
turn, the pinned stdlib scorer audits sequence integrity and clean closure,
recomputes the tool-call count from paired tool events, and requires it to match
the evaluator protocol count. It also derives a bounded successful-tool-
completion score from those events. The recomputed count is the first
tool-economy input after correctness ties; the behavioral score is the next
tie-break and appears in local candidate summaries. An absent, incomplete,
invalid, or disagreeing stream fails the bounded attempt instead of silently
trusting the process counter; the scratch workspace and content-bearing trace
are then removed.

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
randomized 40-case/40-unit holdout, and pinned four-arm configuration. The
primary suite contains 60 rows representing 44 independent units. The shipped
arm map uses `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, and
`gpt-5.4-mini`; all prompts are evaluated by the same pinned cohort. The
mutator intentionally sends the parent prompt to those providers, while inner
agent telemetry is disabled and only prompt-free signed aggregate tournament
grades are submitted. The generated config pins both the behavioral auditor and
its scorer as evaluator inputs. The generated config keeps automatic promotion
off.

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
