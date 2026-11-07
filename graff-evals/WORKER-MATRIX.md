# Private Worker Comparisons

`worker_matrix.py` runs the existing paired `subagents` / `subagents-solo`
fixtures with independently selected lead and worker routes. It supports solo,
same-route teams and mixed-route teams without putting account configuration
or experimental results in the repository. It does not change engine defaults.

Preparing a matrix runs only the frozen fixture's initial checker. Executing
it requires a separate, explicit `--run` command and can spend provider credits.
The runner is POSIX-only. It does not replay arbitrary task setup commands.

```sh
python3 graff-evals/worker_matrix.py \
  --manifest "$PRIVATE_MANIFEST" --binary "$GRAFF_BINARY" \
  --output-root "$PRIVATE_OUTPUT"

# Only when live model execution is intended:
python3 graff-evals/worker_matrix.py --run "$PRIVATE_OUTPUT"

# Read an existing batch without model calls or modifying the saved evidence:
python3 graff-evals/worker_matrix.py --summarize "$PRIVATE_OUTPUT"
```

The output directory must be new and outside the repository. Existing runs
are never overwritten or retried. Keep manifests, receipts, credentials,
logs and results private; do not attach them to public trackers.

## Manifest

Create the manifest privately. The route names here are placeholders, not
available models:

```json
{
  "repetitions": 2,
  "max_model_calls": 64,
  "max_tool_calls": 180,
  "cost_stop_usd": "1",
  "auth_env": [],
  "auth_files": [],
  "tasks": [
    {"team": "sa-fix-three", "solo": "solo-fix-three", "workers": 3}
  ],
  "arms": [
    {"id": "solo-a", "root": {"provider": "provider-a", "model": "model-a"}},
    {"id": "team-a", "root": {"provider": "provider-a", "model": "model-a"},
     "worker": {"provider": "provider-a", "model": "model-a"}},
    {"id": "solo-b", "root": {"provider": "provider-b", "model": "model-b"}},
    {"id": "team-b", "root": {"provider": "provider-b", "model": "model-b"},
     "worker": {"provider": "provider-b", "model": "model-b"}}
  ]
}
```

This four-arm matrix compares each route alone and with three workers using
that same route. No separate larger lead is needed. Two repetitions produce
eight trials on the same three-package repair fixture.

Each arm can select a different lead. For a mixed team, add an arm whose `root`
uses route A and whose `worker` uses route B. The order rotates across repetitions and tasks;
cache state is not reset and model-specific default reasoning is retained.

`auth_env` lists only the authentication environment-variable names explicitly
needed for the selected routes. Values are inherited by the harness, never
written into receipts. `auth_files` entries have `source` and `destination`:
the source is an existing private credential or catalog file, and the destination
is relative to each trial's fresh HOME. No other user configuration is inherited.
Provision authentication deliberately; preparation does not sign in or create keys.
Fresh HOME and restricted prompts are isolation measures, not an OS security sandbox.

Other existing pairs include `sa-rename-api` / `solo-rename-api` (three workers),
`sa-sidecar` / `solo-sidecar` (one) and `sa-coverage` / `solo-coverage` (two).
Set `freeze_all_inputs: true` on inventory/reconciliation tasks such as coverage,
where input modifications must not qualify as a fix.

## Measurements

- Frozen executable, runner, measurement, manifest, fixture and grader hashes.
- Held-out checks outside the agent cwd; visible verifiers protected against edits.
- Actual lead/worker route identities, worker receipts and per-role observed tokens.
- Wall time including lead review/repair, exit/timeout status and failed API attempts.
- Native full cost only when tokens and pricing are complete, with no excluded
  subscription calls. A known subtotal is not a full charge, including when zero.

Optional `prices.root` and `prices.worker` on an arm supply explicit hypothetical
per-million rates: `input`, `cached`, `write`, `write_1h`, `output`, a positive
per-request `max_input`, and a required `source` describing the assumption.
The runner never infers a gateway tariff from a direct-provider model name.
Rates apply to each recorded request, not aggregated tokens. Hypothetical
API-equivalent estimates remain separate from native cost.

Summaries include attempted/passed counts and mean wall time, native full cost,
API-equivalent total, and `mean_estimated_role_costs_usd` split into `root` and
`worker`. Role estimates require explicit rates; they are not native per-role
charges. A missing role estimate in any trial keeps that role's mean unknown.
An observed solo run's explicit zero worker estimate remains zero. Older saved
results without role estimates remain readable, but their role means are unknown.
`--summarize` only reads saved `results.json` and prints a JSON report; it does
not execute the harness, recheck graders, rewrite receipts, or validate old
results against today's executable.

Unknown usage or wrong routes stop the batch. Unknown full native cost also
stops it unless a complete explicit rate estimate is available. The between-run
cost stop uses native full cost when known, otherwise that estimate; it is not
a provider-side hard dollar cap. All trials, including failures, enter time
and cost means. Any unknown cost keeps the corresponding full mean unknown.

Fixture passes measure their held-out contracts, not general coding quality.
Documentation coverage checks do not establish full semantic accuracy, and
worker quality is not graded independently of the lead's repairs.

## Offline Regression Checks

```sh
python3 -m unittest discover -s graff-evals -p 'test_worker_matrix.py'
```

These checks use synthetic routes, usage events and a local fake executable.
They make no model or network calls and do not read real credentials.
