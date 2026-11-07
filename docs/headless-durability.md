# Unattended runs: recovery and supervisor contract

Use the one-shot stream when a program owns the job:

```sh
graff -p --output-format stream-json --max-model-calls 500 "Write the deliverables to files"
graff -p --output-format stream-json --resume SESSION_ID "Continue the saved work"
```

`--output-format stream-json` (or `-p --json`) keeps stdout JSONL. Its first
one-shot lifecycle event is `run_started`, carrying `run_id`, `session_id`
and nullable `parent_session_id`. Save the session id immediately rather
than scanning session filenames. Ordinary text mode also writes that start
record to stderr; its stdout remains the answer.

The final event is `result`, with `status`, `reason`, `exit_code`,
`retryable`, `session_saved`, the same ids, `turns`, `model_calls`,
`duration_ms`, `usage`, `total_cost_usd`, `known_cost_usd`, `cost_complete`,
`unpriced_calls`, `subscription_calls` and `result` (answer/error text).
Events between the start and result use the existing text/tool JSON stream.
A successful turn is not independent proof that an artifact satisfies the
brief: use `--eval` for an executable acceptance check. Open checklist work,
unsatisfied evaluation and recovery exhaustion must not report completion.

`total_cost_usd` is null when any charge is unknown; `known_cost_usd` is only
a subtotal in that case. Token totals expose missing usage and failed
attempts without usage rather than inventing numbers. Subscription calls
have no incremental token charge and are counted separately. These are
invocation totals, including recorded descendant usage, not cumulative
multi-process resumed-run totals. Duration is elapsed one-shot execution
in this process, not time across retries or startup.

## Exit codes after one-shot execution starts

| Code | Meaning | Supervisor action |
|---|---|---|
| 0 | Completed turn, with no known unfinished checklist/evaluation | Validate deliverables as required |
| 1 | Other failure, including an unsuccessful final session save | Inspect the result |
| 2 | Unfinished work, model loop, or exhausted length continuation | Inspect partial work before continuing |
| 3 | Invocation model/tool budget exhausted | Resume with an explicitly raised budget |
| 4 | Credit/billing/quota cap | Fix the account limit; do not blindly retry |
| 75 | Transient provider/transport failure after bounded recovery | Retry/resume with supervisor backoff |
| 77 | Authentication/permission or required fallback consent | Repair credentials/consent first |
| 78 | Invalid provider request | Fix the request/configuration |
| 130 | Cancelled | Resume only if still wanted |

The execution boundary saves the current session on both success and
failure and reports whether saving worked. Abrupt process termination,
output-pipe failure and startup/argument/credential errors before this
boundary cannot promise a terminal result event. `--resume` takes an
explicit saved name; `last` is not a newest-session alias. Normal resume
continues that session; `--branch` records an independent child session.

## Recovery policy

An output-length stop retains partial history and grants a bounded in-turn
continuation that asks for incremental file writes, not another full draft
in a reply. The allowance is per turn and cannot be refilled by tools or
compaction. Truncated tool arguments remain non-executable. Reasoning-only
length stops also receive a brief-answer note. Cancellation and invocation
budgets take precedence. A forced tools-off final-budget landing is reported
as budget exhaustion, even if its prose sounds successful; it is not proof
that the requested work finished.

Empty completions are transient failures, with cancellation-aware jittered
backoff rather than immediate identical calls. Billing/auth refusals take
precedence over generic retryable HTTP envelopes. Exhausting recovery is a
failure, not a successful empty answer.

Gemini-4 model ids, including provider-qualified aliases, get a request-local
20-minute silence allowance for buffered output after HTTP headers. Active
answer prose retains the normal short stall/reconnect policy. Explicit
`GRAFF_STREAM_STALL_SECS` and `GRAFF_STREAM_HEAD_STALL_SECS` settings override
the model defaults; connect/header deadlines are unchanged. This protects
client-side waits, not gateway/upstream idle deadlines.

Raw MCP startup exception lines are debug-only (`GRAFF_REPL_DEBUG=1`).
Configured servers are not removed or silently disabled: cached stdio
servers retain their existing lazy start, and normal MCP status/tool-call
errors remain available. This is quiet startup, not universal lazy discovery.

## Still not journal-first execution

Current checkpoints record messages and completed tool batches, and
compaction context survives session snapshots. Recovery loads a snapshot,
not an authoritative write-ahead execution journal. A crash between a side
effect and its checkpoint is still ambiguous. Input hashes cannot make an
arbitrary shell command or remote API exactly-once; that needs explicit
prepare/commit records and operation-specific reconciliation or a
cooperating idempotent service.

Remaining larger work:

- Authoritative append-before-dispatch journal, replay state machine and
  explicit reconciliation of interrupted side effects.
- Whole-run identity/lineage, wall/agent time and accounting across resumed
  processes, rather than just invocation ids plus saved session parentage.
- Dollar budgets and route-specific pre-flight credit checks. Current
  budgets count calls/tools; unknown charges cannot enforce a dollar cap.
- Account-wide route capacity discovery and cross-process queuing. The
  existing invocation-local concurrency limiter does not discover an
  upstream account's actual limit.
- Gateway-side heartbeat and idle-timeout support. A longer client-side
  silence allowance cannot keep an upstream gateway connection alive.
