# Learning privacy and consent

Graff separates calls to the user's selected model provider, ordinary
operational telemetry, and federated prompt-policy learning. The controls on
this page govern only the third path.

`Local` therefore means **no background learning upload to the Graff backend**.
The one exception is a separately confirmed `learn_candidate` action that sends
one aggregate-only receipt. Local does not claim that a prompt stays on-device
when the configured model provider is remote.

## Modes

The default is `local`. Change the session ceiling interactively:

```text
/privacy
/privacy aggregate
/privacy templates
/privacy examples
```

Or select it at launch:

```sh
graff --learning-privacy aggregate
GRAFF_LEARNING_PRIVACY=aggregate graff
```

Only exact lowercase environment values are recognized. Unknown, padded, or
case-varied values fail closed to `local`.

| Mode | Learning data admitted | Additional consent |
| --- | --- | --- |
| `local` | Nothing automatically | One-shot confirmation if `learn_candidate` requests aggregate submission |
| `aggregate` | Signed grades, counts, buckets, fingerprints, controlled cohort metadata | Selecting the mode |
| `templates` | Aggregate data plus reviewed reusable system/persona templates | Exact template-version approval |
| `examples` | Same implemented behavior as `templates` today | Raw example transport is reserved but not implemented |

`GRAFF_FLEET=off` and `/fleet off` remain master kill switches. Ordinary
telemetry still follows `--no-telemetry` / `GRAFF_NO_TELEMETRY` and the
behavioral upload controls documented separately.

## Template consent

`templates` is a ceiling, not blanket content consent. Before a private inline,
personal, project, or locally learned persona can enter a `fleet:propose`, the
interactive root shows:

- its short fingerprint and byte count;
- a bounded one-line preview;
- what is included and structurally excluded; and
- any locally detected credential marker.

The user can share that exact version for the current process, run the child
locally, or cancel it. Changing one byte changes the fingerprint and asks
again. Approvals are kept only in memory and are cleared on every mode change.
A repository-controlled settings file cannot grant them.

`--yolo`, saved command approvals, subagents, and noninteractive runs cannot
approve template publication. Without an interactive approval, the child still
runs but its prompt text is omitted. Builtin and already-downloaded fleet
personas are public artifacts and do not need to be republished as private user
content.

## Final egress boundary

All score and fleet call sites converge in `Telemetry.scoreEvent` and
`Telemetry.fleetEvent`. Those functions enforce the current mode again.
Template text is admitted only when its exact SHA-256 digest is on the
session-local approval list and a second secret scan passes.

This double check means a missed condition at an individual mutation,
evaluation, subagent, or workflow call site cannot silently attach content.

Raw task prompts, template bindings, user messages, code, paths, child reports,
tool arguments/results, and local traces have no field in the fleet contract.
The future `examples` path must use a separate endpoint, preview hash, consent
receipt, short retention, and deletion API before it can be enabled.

## Hashes are not anonymity

Graff does not describe deterministic prompt hashes as anonymous. Short or
low-entropy prompt text can be guessed and checked against an ordinary hash,
and stable identifiers permit correlation.

Private prompt fingerprints therefore remain local unless needed as controlled
aggregate lineage metadata. Public/builtin templates may use stable IDs because
their content is already known. Raw prompt text is never made safe merely by
hashing it.

## Local files

Local is still sensitive storage. Trajectory archives can contain complete
system/persona prompt genomes, subagent nodes contain a short task preview, and
`.graff/subagents/` inspection reports contain full task/report detail. Keep
`.graff/` out of version control, protect the workspace permissions, and delete
those files when they are no longer needed.

## Explicit grade submission

`graff learn submit` and `graff learn run --submit` require an aggregate-or-
higher ceiling in addition to their existing signing key and telemetry endpoint:

```sh
graff --learning-privacy aggregate learn submit RUN_ID
graff --learning-privacy aggregate learn run --submit
```

The root `learn_candidate` tool is a deliberate one-shot exception: it bundles
local evaluation, grading, and aggregate submission. In Local mode the root
shows the exact aggregate categories and requires a separate confirmation;
`--yolo`, saved approvals, subagents, and noninteractive calls cannot bypass it.
The permit is consumed once without changing the session mode. The tool cannot
publish prompt text or promote a candidate automatically.

## Regression contract

Tests assert that:

- local mode creates no score or fleet record;
- aggregate mode records grades and fleet metadata without prompt text;
- template mode still omits unapproved text;
- approval applies only to the exact template version;
- planted API keys, tokens, authorization headers, and private-key markers
  cannot be approved; and
- lowering or changing the mode revokes prior content approvals.
