# 0286. MCP run_task takes caller context, summarized into text

Status: accepted 2026-10-05

## Context

`graff mcp serve` exposes one tool, `run_task`, which spawns the current
executable as a fresh bounded one-shot (ADR 0129). The only input was `prompt`,
so a caller that already held the relevant background had to either re-derive it
inside the child or paste it into the brief. Callers asked for a channel to hand
context over.

The gateway's `/responses/compact` endpoint cannot serve that channel. It
returns opaque encrypted state that is meaningful only by continuing the
conversation it compacted, so it cannot seed a child that starts with
`--no-resume`. It is also provider-scoped: standalone only for the codegraff
provider on an OpenAI GPT-family model, in-stream-only for codex and
`chatgpt-new`, and absent everywhere else, including xAI (ADR 0002).

## Decision

`run_task` gains one optional argument, `context`: nonblank UTF-8, at most
32 KiB, carrying background the child cannot re-derive.

- At or below 8 KiB, `context` is appended to the child's system prompt
  verbatim via `--append-system-prompt`.
- Above 8 KiB, the server first runs a summarizer child and appends its text
  instead. The summarizer runs `--no-resume --safe --max-model-calls 1
  --max-tool-calls 0` on a 60-second deadline: summarizing is not a reason to
  touch the workspace or to spend the task's own budget.
- If summarization fails, the task is not run and the tool returns an error
  naming the failure. Context is never silently dropped or truncated.
- `structuredContent` reports `context_chars`, `context_summarized` and
  `context_used_chars`, and mirrors the same object under
  `_meta["codegraff/runTask"]` so a raw-result reader needs no prose.
- The same object crosses the ACP boundary: `mcp_call` reads the MCP result's
  mirror, the engine carries it on the `tool_result` event, and the completed
  `tool_call_update` carries it as `_meta["codegraff/runTask"]` beside any
  `graff/view`. Only the five fields cross — the task's text and the caller's
  context never travel with them, and a result that reported nothing gains no
  `_meta` at all.
- Those same facts cross into ACP: the engine carries them on the tool
  outcome (`engine_events.ToolOutcome.run_task`), the `--json` `tool_result`
  line gains a `run_task` object only when one exists, and a completed
  `tool_call_update` carries `_meta["codegraff/runTask"]` alongside any
  `_meta["graff/view"]`. The task's text and the caller's context do not
  travel in that metadata.
- Per-task usage and charge for the CHILD's own execution are **not
  reported**. `usage_reported` is always `false` and
  `usage_unavailable_reason` names the cause, so a client can tell "no
  settlement exists" apart from "the field was dropped". Account-wide gateway
  usage remains authoritative for what the child cost.
- Preprocessing **is** reported, separately, because it is a real settled
  charge: `preprocess` carries `cost_usd`, `usage_complete`, `input_tokens`,
  `output_tokens` and `unavailable_reason`. The summarizer runs as a `--json`
  child (print mode reports no settled charge) with its single request line on
  a file-backed stdin, so the engine's own exact-charge ingestion supplies the
  number. An incomplete report — `usage_complete: false`, or any unpriced or
  missing usage — yields `cost_usd: null` and a reason; a list-rate estimate is
  never presented as a settlement. Preprocessing is never folded into the
  child's total, so it cannot be double-counted.

`context` carries text only. cwd, credentials, model, permission mode and CLI
flags still come from the server launch, as ADR 0129 requires.

## Consequences

Children stay fresh and isolated, and the permission and configuration
boundaries of ADR 0129 are unchanged — `context` adds text, not authority.

Summarizing costs one extra model call per over-long handover. It runs under the
caller's own credentials, so it bills to the same account.

Exact per-task charge reporting is **not implemented**, and the result says so
rather than leaving it to be inferred. A `-p` child exposes no settled gateway
charge, and `pricing_settled.zig` forbids deriving one from a list rate; so
`usage_reported` is `false` with a stated reason. Producing a real number needs
the child driven under the JSON protocol to capture the `turn` event's
`cost_usd`, which the process runner cannot yet do — it hardcodes `stdin =
.ignore` and a JSON child does not exit on its own. Until then, account-wide
gateway usage is the authoritative figure and any per-task total would be a
second, double-counted estimate.

An over-long handover also costs a second child process and up to 60 seconds
before the task starts, against `timeout_seconds`, which is unaffected.

The 8 KiB threshold is a policy number, not a measurement. If handovers are
routinely summarized that would have fit, or routinely passed through that
crowd out the task, that number is the thing to revisit. Streaming, session
continuation and cancellation remain out of scope (ADR 0129).