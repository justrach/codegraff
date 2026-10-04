# 0252. Hosted compaction with a Codegraff login

Status: accepted 2026-10-04.

## Context

graff's own compaction asks the session's model for a summary and restarts
history from it (agent_compact.zig). A summary is lossy in the worst place:
exact error text, file paths and the constraints a task depends on are what a
paraphrase drops, and nothing records what was dropped.

The Codegraff gateway now offers `POST /v1/compact`. It takes a neutral
transcript (`role`, `text`, `toolUses`, `toolResults`) and answers with a
decision per tool call — keep it, drop only its result's bulk, or drop the
call and its result — made by a decision model. Text is never rewritten, the
first message and the newest few are pinned, and every decision comes back
with the reply. Pruning alone cannot shrink a session forever, so in `hybrid`
mode, when pruning frees too little, the gateway also summarizes the middle
of the transcript and splices that summary in. The call is billed to the
account like any other request and returns a settled charge receipt.

## Decision

- With a persisted Codegraff login, `compact()` tries the gateway first, with
  `model: "clef"` and `mode: "hybrid"`. The only credential is the persisted
  login (the same one the effort picker uses), never the chat provider's key.
  Without a login nothing changes.
- The reply is applied to graff's own wire-format history by call id
  (gateway_compact_wire.zig). Nothing is rebuilt from the neutral copy, so
  reasoning items, images and provider metadata stay as they were.
  - A trimmed result keeps its head and tail plus the #409 pointer to the full
    output when the session is durable.
  - A dropped call goes with its result only in earlier turns. In the live
    turn the call stays and only its result shrinks, so that turn's reasoning,
    thinking blocks and signatures stay paired with every call they reference.
    Earlier turns' reasoning items go, as in the local path (#174).
  - A spliced summary becomes graff's usual handoff note between the pinned
    first message and the kept tail. The cut moves back over any call a kept
    result answers, and an unresolved turn's opening prompt stays verbatim
    (#581).
- The reply is checked before it is installed: the transcript it returns has
  to be exactly what its decisions imply, the new history may not pair calls
  and results worse than the old one, and it has to free at least a tenth of
  the estimated context. Anything else is a failure.
- Refusals and failures:
  - A refused key (401/403) turns hosted compaction off for the session and
    compaction stays local.
  - Exhausted credits (`insufficient_credits`, `key_budget_exceeded`) turn it
    off for the session as well. Compaction continues with the local summary,
    and graff says once that it is local and lossy until the account is topped
    up. `gateway_compact.on_credits_exhausted = .off` stops compaction instead.
  - Any other failure — a 5xx, a timeout, a reply that does not check out —
    falls back to the local summary for that compaction only and is noted in
    the trace.
- The settled charge is added to the session's cost tally; an unsettled reply
  counts its tokens as unpriced.
- Opaque provider state (Responses `compaction` items) still needs the
  provider's own compaction: `compact()` refuses before the gateway is asked.
  Routes that compact in-stream keep doing so; the gateway replaces the local
  summary wherever graff would have written one, including their near-the-wall
  fallback.
- `GRAFF_HOSTED_COMPACT=0` keeps compaction local. `GRAFF_COMPACT_URL` and
  `GRAFF_COMPACT_MODEL` point it at another gateway or decision model.

## Consequences

Signed-in sessions send their transcript, tool output included, to the
Codegraff gateway each time they compact. Each compaction costs a small
billed request and a round trip, which buys decisions that can be audited and
results that are trimmed rather than paraphrased. A gateway outage or an empty
balance never stops a session; it costs that compaction its quality.
The endpoint may keep more than its six newest messages when it moves its
cut back over a call and its result; graff accepts any such tail. Revisit to
send graff's own working set as `preserveRecentMessages`, or when live-turn
calls can be dropped safely on a given wire.
