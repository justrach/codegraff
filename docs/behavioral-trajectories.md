# Behavioral trajectories (experimental Phase 1)

Codegraff has an experimental behavioral event stream inspired by the
schema-harness traces discussed in [issue #246](https://github.com/justrach/codegraff/issues/246).
It establishes an ordered per-run envelope and explicit APIs for caller-asserted
commitments and mispredictions. Here, a **run** means an initialized agent
session; utility invocations such as help, version, and `graff title` return
before behavioral tracing starts. Phase 1 does **not** yet implement the complete
generic predict → act → verify → repair loop, replayable task state, behavioral
scoring, or fleet/DGM selection from those scores.

## Three different local streams

| Stream | Lifetime | Purpose |
| --- | --- | --- |
| `harness.trace.jsonl` | Truncated at startup | Operational API/tool latency and error counters, with active behavioral-turn attribution, used to debug the harness. |
| `.graff/trajectories/<run_id>.jsonl` | Up to one exclusively-created file per initialized agent session | Experimental lifecycle and caller-asserted belief events. |
| `harness.trajectory.jsonl` | Append-only across runs | Existing DGM/MAP-Elites lineage and fitness ledger. Its record shapes are unchanged. |

Behavioral events are deliberately not mixed into the legacy DGM ledger. This
keeps old consumers working and prevents concurrent processes from interleaving
unattributed event rows. No built-in production task adapter calls the
commitment or misprediction APIs yet, so ordinary Phase 1 files contain lifecycle
events only. Adapter rows in the example below are illustrative.

## Behavioral network upload

The network destination is not a fourth local file and the local JSONL is never
read back or uploaded wholesale. While producing each logical event,
`BehaviorTrace` independently offers a privacy projection to a bounded in-memory
uploader. Local capture and upload have separate controls:

| Setting | Effect |
| --- | --- |
| `GRAFF_BEHAVIOR_TRACE=off` | Disables the local behavioral file only. `0`, `false`, and `no` are also accepted. |
| `GRAFF_BEHAVIOR_UPLOAD=off` | Disables the behavioral POST only. `0`, `false`, and `no` are also accepted. |
| `GRAFF_BEHAVIOR_UPLOAD=metadata` | Explicitly selects the field-allowlisted metadata projection. This is the default when ordinary telemetry is enabled. Only the exact lowercase literal enables an explicit selection. |
| `GRAFF_BEHAVIOR_UPLOAD=content` | Explicitly opts into opaque content supplied by a task adapter. Only the exact lowercase literal `content` enables this mode. |
| `GRAFF_TELEMETRY_KEY=<token>` | Sends the same bounded visible token as `x-harness-key` on ordinary OTLP and behavioral requests. Use it when the collector configures `TELEMETRY_KEY`. |

Unknown upload values and case/whitespace variants fail closed to `off`. The existing telemetry consent gate
is the parent gate: `--no-telemetry`, `GRAFF_NO_TELEMETRY=1`, or an empty
telemetry endpoint forces behavioral upload off even if `content` is requested.
Conversely, disabling local capture does not disable upload, and disabling upload
does not disable the local file.

At terminal closure the client derives `/v1/behavior` beside the configured
`/v1/logs` OTLP endpoint and attempts one POST with a three-second deadline. A
validated `GRAFF_TELEMETRY_KEY` is sent as `x-harness-key`; empty, oversized,
whitespace, and control-bearing values are not sent. HTTP non-2xx responses are
treated as failed attempts. Upload remains best-effort and silent, and it does
not retry. Timeout cancellation synchronously joins the POST task before
its payload and client state are released. A crash, kill, early
`std.process.fatal`, network error, deadline, or serialization/admission failure
can therefore leave no uploaded run or a batch with reported drops. The payload
is capped at 256 KiB, 4,096 events, and 128 metric turns. Upload happens only
after session-owned workers are joined. `complete=true` is sent only when the
upload retained `run_finished`; if terminal admission or allocation fails, the
batch instead reports `complete=false` and increments `dropped_events`.
`run_finished(status="closed")` still means a clean session return, not
successful task completion.

The batch schema is `codegraff.behavior.batch.v1`; projected events retain
`codegraff.behavior.v1`. In metadata mode the batch contains pseudonymous
install/run attribution, a controlled client class (`harness`, `sdk-ts`, or
`sdk-py`), lifecycle and turn relationships, an initial provider/model/effort
snapshot, terminal and drop status, keyed opaque commitment references, and
content-free per-turn API/tool aggregates. The local deterministic prompt
fingerprint is deliberately omitted from all behavioral uploads because
low-entropy prompt variants can be recovered by enumeration. Tool aggregates use
controlled classes (`shell`, `read`, `write`, `search`, `web`, `agent`, `verify`,
`mcp`, and `other`). Unknown private MCP server/tool names collapse to `mcp`
rather than being serialized exactly.

`GRAFF_BEHAVIOR_UPLOAD` governs only this new behavioral POST; it does not
rewrite the existing OTLP score/run/fleet contract. Existing OTLP records can
contain prompt fingerprints, and fleet proposal records can contain prompt text
as documented in [hyperagents.md](hyperagents.md). Disabling ordinary telemetry
disables both OTLP and behavioral upload.

Metadata admission is field-based; values of allowed fields are not scanned or
redacted. In particular, initial provider and model identifiers are transmitted
exactly as configured and can themselves contain private labels or path/repository
fragments. The schema has no dedicated fields for user/system prompts, generated
model text or hidden reasoning, source, diffs, filesystem paths or repository
names, tool arguments or results, shell commands, arbitrary environment values,
credentials, headers, identity, prompt fingerprints, or free-text adapter
content. Content mode changes typed adapter events: it may include
`commitment_id`, `action`, `expect`, `reason`, `predicted`, `actual`, and `detail`
exactly as supplied. There
is no redactor, sanitizer, or secret scanner. No built-in production adapter
currently supplies those fields.

The collector stores individual runs privately and has no raw behavioral GET
endpoint; its public stats expose aggregate totals only. Content-opt-in fields
are isolated from event metadata and expire after 30 days. Metadata rows do not
currently have an automatic expiry. The separately transmitted signed score
signal can carry the same `run_id` for trusted correlation, but uploaded
behavioral events are not themselves scores and do not enter fleet selection.

## File and ordering contract

Every complete line is one flat JSON object with these required envelope fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `kind` | string | One of the nine event-kind names below. |
| `seq` | positive integer | Logical source-event order. A healthy local file is a contiguous prefix starting at `1`; a bounded upload projection can have gaps reported by its drop counters. |
| `ts` | number | Wall-clock Unix time in fractional seconds. It can repeat or move backwards if the system clock changes. |
| `run_id` | string | The run's random hexadecimal identifier, also used in the filename. |
| `schema` | string | `codegraff.behavior.v1`. |

Kind-specific fields are top-level fields rather than a nested `payload`.
Consumers should ignore unknown top-level fields so compatible additions remain
possible.

A logical `seq` is reserved once before either sink is attempted. Each local
record is built completely in memory, written, and flushed as one line. If local
serialization or output fails, local capture is disabled for the rest of the
process while upload remains independent; an upload admission failure likewise
does not disable the local file. This makes a healthy local stream a contiguous
prefix, while an upload may contain source-sequence gaps accounted for by
`dropped_events`. A local event is capped at 64 KiB to bound temporary
serialization memory; exceeding that cap disables the local sink for the rest of
the run but does not disable metadata upload. Directory creation,
private-permission setup, and exclusive-open collisions are best-effort; a
failure silently leaves only local behavioral capture disabled. An I/O failure
can still leave one malformed final
line; consumers should process only complete JSON lines and treat a missing
terminal `run_finished` as incomplete. The files currently have no manifest,
checksum, or signature, so they cannot prove that a local file was not truncated
or edited after the run.

## Current event support

The enum reserves the nine schema-harness event names, but Phase 1 intentionally
implements only the lifecycle and caller-asserted adapter subset.

### Automatically emitted

#### `run_started`

Fields:

- `version` — Codegraff version string.
- `unix_ms` — integer startup timestamp retained for correlation with existing
  local records.
- `provider` and `model` — restored/current root selection when lifecycle starts.
- `prompt_sha` — a one-way fingerprint of the effective system prompt at that
  point, not prompt text.
- `effort` — configured reasoning-effort label at that point.

These are an initial run-start snapshot, not immutable per-turn wire facts.
Later `/model`, `/strict`, ultracode, provider fallback, or effort negotiation can
change what a later request uses without rewriting `run_started`. Phase 1 does
not emit per-turn configuration snapshots. The fields are optional for
compatible producers but are emitted by the current root session path.
`run_started` is the first logical event and is emitted at most once. For an
interactive resume, persisted state is loaded before this event; any optional
model-backed cold-cache compaction runs afterward, outside a root turn.

#### `turn_started`

Required fields:

- `turn` — dense behavioral root-turn ID, starting at `1`.
- `parent_turn` — previous root turn, or `0` for the first turn.
- `trajectory_node` — current legacy DGM node when one was already reserved,
  otherwise `0`.

This event is emitted once at the shared provider boundary, before model or tool
work. It covers interactive, JSON, one-shot, and zigzag REPL root turns. Provider
fallback retries occur inside that boundary and do not create extra behavioral
turns. Active attribution is cleared when the complete provider operation
returns; later administrative or resume-preprocessing API/tool work carries
operational turn `0` and does not create an uploaded turn-metric row. Subagent
calls are not separate behavioral root turns in Phase 1.

`trajectory_node` is correlation metadata scoped to the current process. Legacy
node IDs restart in later processes and legacy rows do not all carry `run_id`, so
historical consumers must not treat this number alone as a globally unique join
key. One-shot and zigzag modes preserve their old DGM behavior and currently use
`0` here.

#### `run_finished`

Required field:

- `status` — currently `closed` or `error`.

`closed` means that the initialized agent session returned without propagating
a Zig error. It is **not** a task-success verdict and does not prove that every
turn succeeded; interactive turn errors can be handled before a later clean
close. `error` means that main unwound with an error or that the expected
one-shot provider-failure path terminated through `std.process.fatal`. A crash,
kill, trace-write failure, or another non-unwinding exit can leave no
`run_finished` event.

### Caller-asserted task-adapter APIs

These records are never inferred from model prose or from a generic tool exit
code. An adapter is responsible for deciding what the action, expectation, and
verification mean; the backend neither authenticates that caller nor attests
that verification occurred.

#### `turn_committed`

`BehaviorTrace.recordExpectedAction` records:

- `turn` — the current nonzero behavioral turn.
- `commitment_id` — nonempty, producer-defined correlation ID; it should be
  unique within the run.
- `action` — opaque JSON describing the intended action.
- `expect` — opaque JSON describing the predicted result or state.
- `reason` — producer-provided explanation of the commitment.

#### `model_mispredicted`

`BehaviorTrace.recordMisprediction` records the caller's assertion that an
observation contradicted a prediction:

- `turn` — the current nonzero behavioral turn.
- `commitment_id` — nonempty correlation ID for the commitment being checked.
- `predicted` — opaque JSON for the relevant prediction.
- `actual` — opaque JSON for the caller-reported observation.
- `detail` — producer-provided description of the contradiction.

The typed call serializes opaque values synchronously rather than borrowing
caller memory. The local file retains their serialized form; explicit content
upload can retain a second copy under the 30-day policy above. Codegraff does not
check semantic equivalence, prove that a verifier is correct, maintain a
commitment registry, cancel a plan, or initiate a repair turn.

### Reserved, not emitted in Phase 1

- `text_delta`
- `tool_started`
- `tool_finished`
- `action_taken`

These names are reserved so later task adapters can use the same envelope. They
are not automatically emitted yet because generic provider/tool plumbing cannot
honestly determine task state, distinguish an action from an observation, or
verify a prediction. Tool arguments, results, model text, and state snapshots
also carry substantial credential/source/privacy risk. Do not interpret their
absence as an empty tool/action history. The Phase 1 collector rejects these
reserved kinds until a typed producer and versioned validation contract exist.

## Local retention and privacy

Behavioral files are ordinary local plaintext. Automatic Phase 1 events do
**not** include prompts, generated text, hidden reasoning, source code, tool
arguments/results, credentials, or environment contents. Opaque adapter values
can contain sensitive task data, however. Adapter authors and callers are
responsible for minimizing them; neither the local writer nor explicit content
upload scans or sanitizes them.

- `.graff/` is ignored by Git.
- Directory components are opened relative to verified no-follow handles, so a
  workspace symlink cannot redirect the trace outside the working directory.
  On POSIX, the trajectories directory is set to mode `0700`; new files request
  a maximum mode of `0600`, which a restrictive process umask may reduce
  further. On Windows, access follows the directory's inherited ACLs.
- The local JSONL bytes are never automatically uploaded. A separately built
  metadata projection is uploaded by default only inside the existing telemetry
  consent boundary, as described above.
- Local capture is enabled by default and independent of the operational
  `/trace` toggle and behavioral upload setting.
- Local files have no automatic retention limit. Delete files from
  `.graff/trajectories/` when they are no longer needed. Git ignore rules do not
  prevent backups, artifact collectors, support bundles, workspace-capable
  agent tools, or manual uploads from reading or copying them.
- Behavioral events are not consumed for fleet/DGM selection in Phase 1.
  Public collector visibility is aggregate-only, but the collector retains
  private metadata rows and retains explicit content for up to 30 days.

## Example

```json
{"kind":"run_started","seq":1,"ts":1770000000.125,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","version":"0.0.200","unix_ms":1770000000125,"provider":"anthropic","model":"claude-sonnet","prompt_sha":"0011223344556677","effort":"high"}
{"kind":"turn_started","seq":2,"ts":1770000001.25,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","turn":1,"parent_turn":0,"trajectory_node":1}
{"kind":"turn_committed","seq":3,"ts":1770000002.5,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","turn":1,"commitment_id":"build-1","action":{"kind":"edit"},"expect":{"build":"passes"},"reason":"verify the patch"}
{"kind":"model_mispredicted","seq":4,"ts":1770000003.75,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","turn":1,"commitment_id":"build-1","predicted":{"build":"passes"},"actual":{"build":"fails"},"detail":"compiler verification contradicted the expectation"}
{"kind":"run_finished","seq":5,"ts":1770000004.0,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","status":"closed"}
```

## Deferred work for the full issue

A complete predict–verify implementation still needs:

1. Task adapters that define state snapshots, legal actions, action/observation
   boundaries, and outcome semantics.
2. Stable agent/invocation identities and real dispatch/completion hooks for
   concurrent tool events.
3. Explicit expectation binding, verification, surprise interruption, and
   repair behavior.
4. Versioned, recomputable behavioral scorers plus recipe/eval identity and
   trace-integrity metadata.
5. Admission of only trusted recomputed scores into eval, fleet, MAP-Elites,
   and DGM selection.
6. Replay of the published schema-harness ft09 trajectory and reproduction of
   its reference score.
