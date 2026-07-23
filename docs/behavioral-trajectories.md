# Behavioral trajectories (experimental Phase 1)

Codegraff has an experimental behavioral event stream inspired by the
schema-harness traces discussed in [issue #246](https://github.com/justrach/codegraff/issues/246).
It establishes an ordered per-run envelope and explicit APIs for caller-asserted
commitments and mispredictions. Here, a **run** means an initialized agent
session; utility invocations such as help, version, and `graff title` return
before behavioral tracing starts. The configured eval loop now implements one
enforceable predict → act → verify → repair producer. The broader stream does
**not** yet provide replayable task state, a generic verifier for every task
adapter, or fleet/DGM selection from general behavioral scores.

## Three different local streams

| Stream | Lifetime | Purpose |
| --- | --- | --- |
| `.graff/traces/<run_id>.jsonl` | One exclusively created file per invocation | Operational API/tool latency and error counters, with active behavioral-turn attribution, used to debug the harness. |
| `.graff/behavior/<run_id>.jsonl` | Up to one exclusively-created file per initialized agent session | Experimental lifecycle and caller-asserted belief events. |
| `harness.trajectory.jsonl` | Append-only across runs | Existing DGM/MAP-Elites lineage and fitness ledger. Its record shapes are unchanged. |

Behavioral events are deliberately not mixed into the legacy DGM ledger. This
keeps old consumers working and prevents concurrent processes from interleaving
unattributed event rows. The eval-driven loop (`--eval`/`--until`, `agent_eval.zig`)
is the first production caller of the commitment and misprediction APIs
(issue #256): before it runs the configured scoring command it commits to
`{kind:"eval"}`/`{pass:true}`, then records a misprediction only if the command
exits nonzero or the parsed score misses `--until`. Every other invocation path
still contains lifecycle events only. Adapter rows in the example below are
illustrative.

The retired `harness.trace.jsonl` path is never opened, truncated, appended, or
repaired by current releases. It may still exist as an ignored legacy artifact
from an older installation. Current operational traces use random run IDs,
exclusive creation, a single mutexed writer, complete in-memory JSON records,
and stop writing after any failed file drain. This prevents a stale descriptor
from seeking past a later truncation and creating sparse NUL gaps (#242/#272).

For an eval-driven session, `eval` is a verifier boundary and must be the only
tool in its batch. A red result marks the current expectation as contradicted,
drops the remaining plan, and ends that model turn. The next turn is a repair
turn. A green result permits completion only while the workspace remains
unchanged; any subsequent workspace-changing tool makes the result stale and
requires another eval. Read-only tools do not stale it.

The loop maintains bounded task-class memory at
`.graff/eval-notes/<run_id>.md`. The task class is `--niche` when configured and
`general` otherwise. Its CONFIRMED, GUESSES, HYPOTHESES TO TEST, FACTS, and
verifier-history template is re-injected every turn, including after context
compaction. Eval `note` values can carry labeled belief updates. The directory
and file use private POSIX permissions, no-follow directory/file opens, bounded
reads, and atomic replacement. This file is not uploaded by the behavioral or
learning telemetry mechanisms. It *is* prompt context, so its contents are sent
to the selected model provider on each eval-driven turn.

## Behavioral network upload

The network destination is not a fourth local file and the local JSONL is never
read back or uploaded wholesale. While producing each logical event,
`BehaviorTrace` independently offers a privacy projection to a bounded in-memory
uploader. Local capture and upload have separate controls:

| Setting | Effect |
| --- | --- |
| `GRAFF_BEHAVIOR_TRACE=off` | Disables the local behavioral file only. `0`, `false`, and `no` are also accepted. |
| `GRAFF_BEHAVIOR_TRACE=full` | Opt-in rich capture (#255): the local file additionally records tool names/arguments and completed assistant text — see [Opt-in rich capture](#opt-in-rich-capture-graff_behavior_tracefull) below. Only the exact lowercase literal `full` enables it; every other enabling value (including unset) stays lifecycle-only. |
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
snapshot, local-sink health (`local_sink` on `run_started`, `local_dropped` on
`run_finished`), terminal and drop status, keyed opaque commitment references,
and content-free per-turn API/tool aggregates. The local deterministic prompt
fingerprint is deliberately omitted from all behavioral uploads because
low-entropy prompt variants can be recovered by enumeration. Tool aggregates use
controlled classes (`shell`, `read`, `write`, `search`, `web`, `agent`, `verify`,
`mcp`, and `other`). Unknown private MCP server/tool names collapse to `mcp`
rather than being serialized exactly.

`GRAFF_BEHAVIOR_UPLOAD` governs only this new behavioral POST; it does not
rewrite the existing OTLP score/run/fleet contract. In aggregate-or-higher
learning mode, OTLP score/run records can contain prompt fingerprints; a fleet proposal can contain reusable prompt text
only after the separate `/privacy templates` exact-artifact consent described
in [learning-privacy.md](learning-privacy.md). Disabling ordinary telemetry
disables both OTLP and behavioral upload.

Metadata admission is field-based; values of allowed fields are not scanned or
redacted. In particular, initial provider and model identifiers are transmitted
exactly as configured and can themselves contain private labels or path/repository
fragments. Lifecycle metadata has no dedicated fields for prompts, generated
text, source, paths, arguments/results, commands, credentials, identity, prompt
fingerprints, or adapter free text. Rich metadata adds only broad tool class,
call IDs, byte/duration/error counters, and truncation flags. Content mode may
add `commitment_id`, `action`, `expect`, `reason`, `predicted`, `actual`,
`detail`, exact tool names/arguments, and bounded assistant text. There
is no redactor, sanitizer, or secret scanner. The eval-driven loop is the only
built-in production adapter that currently supplies those fields, and it
supplies only static/opaque values (`{kind:"eval"}`, `{pass:<bool>}`,
`{pass:false,exit:<int>}`, and a short fixed reason/detail string) - never the
configured command text or its stdout/stderr.

The collector stores individual runs privately and has no raw behavioral GET
endpoint; its public stats expose aggregate totals only. Content-opt-in fields
are isolated from event metadata and expire after 30 days. Metadata rows do not
currently have an automatic expiry. The separately transmitted signed score
signal can carry the same `run_id` for trusted correlation, but uploaded
behavioral events are not themselves scores or remote promotion authority. A
local tournament can submit only its separately signed recomputed aggregates.
Eval-note memory is a separate local prompt-context file and is never part of
this behavioral batch.

## File and ordering contract

Every complete line is one flat JSON object with these required envelope fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `kind` | string | One of the nine event-kind names below. |
| `seq` | positive integer | Logical source-event order, reserved before either sink is attempted. A healthy local file starts at `1` and is contiguous except for events rejected before write, which the terminal `run_finished` accounts for in `local_dropped`; a bounded upload projection can have gaps reported by its own drop counters. |
| `ts` | number | Wall-clock Unix time in fractional seconds. It can repeat or move backwards if the system clock changes. |
| `run_id` | string | The run's random hexadecimal identifier, also used in the filename. |
| `schema` | string | `codegraff.behavior.v1`. |

Kind-specific fields are top-level fields rather than a nested `payload`.
Consumers should ignore unknown top-level fields so compatible additions remain
possible.

A logical `seq` is reserved once before either sink is attempted. Each local
record is built completely in memory, written, and flushed as one line.
Failures that happen before any byte reaches the file (allocation,
serialization, or the 64 KiB per-event cap that bounds temporary
serialization memory) drop only that event: the local stream stays alive, the
drop is counted, and the terminal `run_finished` declares the total as
`local_dropped` so an auditor can reconcile every gap. A failure of the file
write itself still disables local capture for the rest of the process, because
a partial tail may exist and later records must not be appended after it.
Upload remains independent in both directions: an upload admission failure
does not disable the local file, and an upload may contain source-sequence
gaps accounted for by its own `dropped_events`. Directory creation and
private-permission setup are best-effort; if the local file cannot be created,
the harness prints one stderr warning, reports `local_sink=false` in the
uploaded `run_started` projection, and leaves only local capture disabled. If
secure entropy is unavailable at run start, behavioral upload is disabled for
the run instead of degrading the commitment-reference key. An I/O failure
can still leave one malformed final
line; consumers should process only complete JSON lines and treat a missing
terminal `run_finished` as incomplete. The files currently have no manifest,
checksum, or signature, so they cannot prove that a local file was not truncated
or edited after the run.

## Current event support

The enum implements all nine schema-harness event names: five are always
automatically emitted (lifecycle) or caller-asserted (adapter), and the
remaining four are automatically emitted only under the opt-in rich capture
described below.

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
- `local_dropped` — how many events were rejected before reaching the local
  file (each one leaves a `seq` gap that this count must equal).

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
check semantic equivalence or prove that a verifier is correct. The eval producer
binds commitments to verifier outcomes and enforces stop-on-red repair; other
task adapters must define their own semantics.

### Opt-in rich capture (`GRAFF_BEHAVIOR_TRACE=full`)

The remaining four reserved kinds (#255) are automatically emitted by the
generic provider/tool plumbing, but only when rich capture is explicitly
opted into with `GRAFF_BEHAVIOR_TRACE=full`. The default lifecycle-only
posture (any other enabling value, including unset) never emits them — do not
interpret their absence as an empty tool/action history.

The versioned collector accepts all four kinds. Metadata mode receives only the
content-free projection described above; exact names/arguments/text require the
separate `GRAFF_BEHAVIOR_UPLOAD=content` opt-in and expire after 30 days.

#### `tool_started`

Emitted before a tool call runs. Fields:

- `turn` — the current nonzero behavioral turn.
- `call_id` — a per-run monotonic ID (starts at `1`) that pairs this event
  with the matching `tool_finished`.
- `name` — the tool name.
- `args` — the tool's JSON arguments, embedded verbatim when they parse as
  valid JSON; otherwise (or when truncated) a plain string.
- `args_truncated` — `true` when the serialized arguments exceeded 4,096
  bytes. A truncated payload may be cut mid-token, so it is always
  re-embedded as a string rather than risking invalid JSON dressed up as
  structured data.

#### `tool_finished`

Emitted after a tool call completes. Fields:

- `turn`, `call_id`, `name` — as above.
- `ms` — wall-clock duration of the call.
- `is_error` — whether the tool reported an error.
- `result_bytes` — the result's byte length. The result **content** is never
  recorded.

#### `action_taken`

The generic coding-task mapping: a state mutation, emitted once a tool call
that finished belongs to a mutating tool class (`write` or `shell`, per
`behavior_upload.toolClass`). Read/search/verify/agent/mcp/other classes are
observations and never emit this kind. Fields:

- `turn`, `call_id`, `name`, `is_error` — as above.

#### `text_delta`

One completed assistant text segment — called once per finished segment, not
per streaming token. In practice, Phase 1's only choke point common to every
provider streaming path is the root turn's final text, so today this fires
once per root turn rather than once per intermediate segment. Fields:

- `turn` — the current nonzero behavioral turn.
- `text` — the text, capped at 2,048 bytes.
- `text_truncated` — `true` when the text exceeded the cap.

#### Privacy posture in full mode

In lifecycle-only mode (the default), automatic events never include tool
arguments or model text, as described below. `GRAFF_BEHAVIOR_TRACE=full`
changes that for the local plaintext file: tool names and arguments,
and completed assistant text, land there in cleartext, subject only to the
4,096/2,048-byte caps above. There is no redaction or secret scanning. Rich
capture also enables typed upload projections: metadata stays content-free,
while exact content requires the second explicit opt-in.

## Local retention and privacy

Behavioral files are ordinary local plaintext. In the default lifecycle-only
posture, automatic events do **not** include prompts, generated text, hidden
reasoning, source code, tool arguments/results, credentials, or environment
contents. `GRAFF_BEHAVIOR_TRACE=full` (#255) is an explicit opt-in that
changes this locally: tool names/arguments and completed assistant text land
in the local file, subject only to the 4,096/2,048-byte caps described above
— see [Opt-in rich capture](#opt-in-rich-capture-graff_behavior_tracefull).
Opaque adapter values can also contain sensitive task data. Adapter authors
and callers are responsible for minimizing them; neither the local writer nor
explicit content upload scans or sanitizes any of this.

- `.graff/` is ignored by Git.
- Directory components are opened relative to verified no-follow handles, so a
  workspace symlink cannot redirect the trace outside the working directory.
  On POSIX, the behavior directory is set to mode `0700`; new files request
  a maximum mode of `0600`, which a restrictive process umask may reduce
  further. On Windows, access follows the directory's inherited ACLs.
- The local JSONL bytes are never automatically uploaded. A separately built
  metadata projection is uploaded by default only inside the existing telemetry
  consent boundary, as described above.
- Local capture is enabled by default and independent of the operational
  `/trace` toggle and behavioral upload setting.
- Local files have no automatic retention limit. Delete files from
  `.graff/behavior/` when they are no longer needed. Git ignore rules do not
  prevent backups, artifact collectors, support bundles, workspace-capable
  agent tools, or manual uploads from reading or copying them.
- The local tournament consumes only recomputed aggregate tool/behavior scores
  and keeps manual promotion as the default. Public collector visibility is
  aggregate-only; private metadata remains, while explicit content expires
  after 30 days.

## Example

```json
{"kind":"run_started","seq":1,"ts":1770000000.125,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","version":"0.0.200","unix_ms":1770000000125,"provider":"anthropic","model":"claude-sonnet","prompt_sha":"0011223344556677","effort":"high"}
{"kind":"turn_started","seq":2,"ts":1770000001.25,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","turn":1,"parent_turn":0,"trajectory_node":1}
{"kind":"turn_committed","seq":3,"ts":1770000002.5,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","turn":1,"commitment_id":"build-1","action":{"kind":"edit"},"expect":{"build":"passes"},"reason":"verify the patch"}
{"kind":"model_mispredicted","seq":4,"ts":1770000003.75,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","turn":1,"commitment_id":"build-1","predicted":{"build":"passes"},"actual":{"build":"fails"},"detail":"compiler verification contradicted the expectation"}
{"kind":"run_finished","seq":5,"ts":1770000004.0,"run_id":"0123456789abcdef","schema":"codegraff.behavior.v1","status":"closed","local_dropped":0}
```

## Recomputable scoring and replay

Two stdlib-only tools make the stream auditable on its own, mirroring the
schema-harness `score_trajectories.py` contract:

- `scripts/score_run.py <stream.jsonl>` audits a local behavioral file
  (envelope, seq/gap reconciliation against `local_dropped`, turn density,
  commitment fields) and derives behavioral metrics from events alone:
  turns, commitments, mispredicts, mispredict rate, commitment coverage, and
  mean repair gap. With `--profile replay --baseline <csv> --game <id>` it
  scores a converted external trajectory with the reference RHAE math
  (per-level `min(115, 100*(baseline/actions)^2)`, level-index weights,
  completion cap).
- `scripts/replay_schema_harness.py events.jsonl out.jsonl` converts a
  schema-harness trajectory into this envelope mechanically.

Round-trip validation: converting the published
`claude_fable_opus/claude-fable-5_max_ft09_100.0` trajectory and re-scoring
the converted stream reproduces its published 100.0 RHAE exactly (the issue
#246 validation criterion). CI runs a hermetic version of the same round trip
plus the live-session audit in `scripts/test-behavior-trace.py`.

## Remaining extensions

A complete predict–verify implementation still needs:

1. Task adapters that define state snapshots, legal actions, action/observation
   boundaries, and outcome semantics.
2. `tool_started`/`tool_finished`/`action_taken` now have real, `call_id`-paired
   dispatch/completion hooks (#255) generic across every tool. `text_delta`
   still only fires once per root turn (the one choke point common to every
   provider streaming path), not once per intermediate assistant text
   segment — a real per-segment hook remains open work.
3. The eval producer now has explicit expectation binding, verification,
   stop-on-red interruption, task-class notes, repair resumption, and a
   completion gate. Equivalent semantics for non-eval task adapters remain
   open.
4. The bundled prompt tournament now recomputes and audits tool-call counts
   and a bounded successful-tool-completion score from each closed rich
   behavioral stream. Tool economy remains the first tie-break after
   correctness; the behavioral score is the next tie-break and is surfaced in
   local aggregate evidence and the signed aggregate receipt. General
   task-specific behavioral scores still need trusted task adapters.
