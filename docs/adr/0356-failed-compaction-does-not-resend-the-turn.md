# 0356. A compaction that spent its retry ladder ends the turn

Status: accepted 2026-11-27

## Context

The pre-send gate compacts when a turn's context is over the compaction
line. On a blob-anchored first-party Responses route near the wall, that is
a forced server pass (ADRs 0089, 0259). The pass goes through `request()`
with its own transport retry ladder. In #1930 every attempt failed
(name-resolution failures). `compactOrRecover` reported the error and
preserved the opaque history, as ADR 0089 requires. The turn then sent its
answer request: the same conversation, at almost the same size, under a
fresh retry ladder. One turn paid two full ladders of a full-size body into
an outage that did not depend on the payload. On the line REPL, the
post-failure compaction then started a third.

The answer request is not over the window here (the forced pass runs at
95%), so sending it is not wrong in itself. What is wrong is resending an
unchanged payload after the same transport has just failed a full retry
ladder. ADR 0183 makes the bounded request ladder the retry policy, and
ADR 0058 already stops resending a pinned turn that does not shrink.

## Decision

`compact_send_gate.afterCompaction(ladder_spent, history_changed)`: when the
gate's compaction request gave up after its full retry ladder (transport
give-up including 429/5xx statuses, or the stall/drop reconnect budget) and
nothing rewrote history, the turn ends. It returns `ApiError` with a
specific message: compaction failed after its retries, the uncompacted
conversation was not resent, the user can send again once the provider is
reachable, run `/compact`, or start a new chat, followed by the compaction's
own error. A compaction that the provider answered (a refusal or malformed
output) still sends the answer as before, and so does one that trimmed or
summarized history, because the payload is then different.

The rule lives in the shared turn loop, so the line REPL and ACP behave the
same. The REPL's post-failure compaction is skipped after a spent ladder,
which ACP never ran.

## Consequences

During an outage, a turn over the compaction line costs one retry ladder
instead of two (three on the REPL). The cost: if the network recovers in
the moment between the compaction giving up and the answer being sent, that
turn fails where it might have succeeded, and the user sends the message
again. In-body overload envelopes (`afterServerErrorOrParseReject`) do not
set `ladder_spent`; extend the flag if those are seen to repeat the same
way. Guarded by `scripts/test-acp-compaction-failure-resend.py` (Tier 1
`shell`, CI) and the pure-rule test in `compact_send_gate.zig`.
