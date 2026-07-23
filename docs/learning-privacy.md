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

Generated TypeScript and Python clients resolve these controls per harness
instance rather than mutating process-global environment state. A local/off
instance cannot be made network-active by a different aggregate instance in the
same process.

### SDK startup prompts

The local Python `system_prompt` / `append_system_prompt` and TypeScript
`systemPrompt` / `appendSystemPrompt` options are not placed in subprocess argv.
The SDK starts a versioned stdin-bootstrap mode, sends both values in one bounded
JSON frame, validates a prompt-free UTF-8 byte-count acknowledgement, and only
then permits the first user turn. Graff composes that frame at the original
startup boundary, preserving the normal replacement → project instructions →
append → skills/MCP ordering and the initial behavioral prompt fingerprint.
Bootstrap failure closes and reaps the child. Raw SDK `args` remain explicitly
caller-controlled; manually supplying CLI prompt flags there can expose them to
same-user process inspection.

Remote SDK creation sends the same fields in the authenticated HTTP request.
`graff serve` now forwards them to its session child with that stdin bootstrap
before publishing the session ID; it never rebuilds prompt-bearing child argv.
Use HTTPS outside loopback and configure reverse proxies not to log request
bodies—the bridge necessarily handles the plaintext in memory to construct the
model request. Serve-level prompt defaults supplied manually as CLI flags remain
visible in the server parent argv, like any explicit raw CLI prompt flag.
Remote SDK exceptions report only HTTP status and path; arbitrary response bodies
are discarded so a reflecting proxy cannot copy a prompt into application logs.

Each local SDK serializes non-answer operations, and the HTTP bridge independently
serializes them per session. `answer` is the deliberate exception so it can
resolve an in-flight `ask_user`. If a local event iterator is abandoned early,
the client drains that turn while retaining the operation gate, preventing its
remaining events from being mistaken for a later request.

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
`Telemetry.fleetEvent`. Those functions enforce the current mode again, and
serialization rechecks the live privacy ceiling and fleet kill switch before a
buffered event leaves the process. Template text is admitted only when its exact
SHA-256 digest is on the session-local approval list and a second secret scan
passes.

This double check means a missed condition at an individual mutation,
evaluation, subagent, or workflow call site cannot silently attach content.

Raw task prompts, template bindings, user messages, code, paths, child reports,
tool arguments/results, and local traces have no field in the fleet contract.
Raw provider/tool error details are dropped rather than redacted. Event kinds
and provider classes are allowlisted; custom niches and unexpected identifiers
are projected to bounded fingerprints before egress. SDK fleet emitters always
strip prompt text because they do not have an interactive review surface.
The future `examples` path must use a separate endpoint, preview hash, consent
receipt, short retention, and deletion API before it can be enabled. Aggregate
receipts have a fixed 30-day backend retention window; the receipt status
reports its expiry. This does not delete the local immutable evidence store.
Users can delete a receipt sooner with `graff learn delete-remote RUN_ID`.
The deletion token is scoped to one run, derived from that run's private nonce,
and is neither returned by receipt lookup nor stored in plaintext. The backend
keeps only a one-way run tombstone after deletion to reject queued or replayed
copies; it contains no prompt, task, path, metric, or stable installation ID.

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

Deletion is a revocation operation, not new telemetry, so it is allowed under
Local mode and the fleet/telemetry kill switches:

```sh
graff learn delete-remote RUN_ID
```

The root `learn_candidate` tool is a deliberate one-shot exception: it bundles
local evaluation, grading, and aggregate submission. In Local mode the root
shows the exact aggregate categories and requires a separate confirmation;
`--yolo`, saved approvals, subagents, and noninteractive calls cannot bypass it.
The permit is consumed once without changing the session mode. The tool cannot
publish prompt text or promote a candidate automatically.

The signed receipt contains fixed aggregate fields only: parent/child pass
counts and deltas, statistical-unit counts and significance, critical and
ordinary regression counts, measured tool/cost/latency totals, fixed gate
settings (including economy-gate enablement), eligibility/reason codes, short
prompt lineage fingerprints, and content-addressed run/suite/cohort/evidence
identifiers. A second signature
binds those metrics so the backend rejects tampering that the legacy score
signature alone could not detect. It has no field for prompts, tasks, code,
paths, adapter output, evaluator payloads, errors, or traces.
Explicit learning submissions also omit the stable installation identifier,
OS, architecture, and service version. The collector discards installation
identifiers sent by older learning clients, and receipt lookups are marked
`private, no-store` so capability URLs are not retained by caches.

Adapter failure diagnostics follow the same boundary. Direct learning commands
show only the adapter operation and termination status by default; raw stderr
and executable paths require the local-only
`graff learn run --show-adapter-stderr` opt-in. The model-facing
`learn_candidate` tool discards all nested-process stderr even on failure.

## Regression contract

Tests assert that:

- local mode creates no score or fleet record;
- lowering privacy or disabling fleet drops already buffered learning events;
- aggregate mode records grades and fleet metadata without prompt text;
- SDK instance overrides, `--no-telemetry`, and `GRAFF_FLEET=off` prevent
  network calls without leaking raw error or free-form metadata;
- structured SDK startup prompts stay out of argv, finish before the first user
  turn, validate UTF-8 byte counts, and reap the child on bootstrap failure;
- remote session prompts also stay out of the server child argv, and concurrent
  non-answer operations cannot steal one another's events;
- adapter stderr canaries stay hidden by default and never enter model-facing
  `learn_candidate` results;
- template mode still omits unapproved text;
- approval applies only to the exact template version;
- planted API keys, tokens, authorization headers, and private-key markers
  cannot be approved; and
- lowering or changing the mode revokes prior content approvals.
