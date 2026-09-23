# 0176. Completed streams do not replay on trailer timeout

Status: accepted 2026-09-23

## Context

A streamed response can contain a terminal choice and usage while its connection
remains open. The reader already accepted a subsequent connection close, but a
silent trailer deadline retried the completed request and discarded its usage.

## Decision

Recognize a terminal choice structurally, with a cheap check that rejects ordinary
null-marker chunks before parsing. Continue reading for a separate usage trailer.
If the existing watchdog deadline then expires after valid completion, retire the
connection and return the buffered response. Apply the same rule to both stream
transports. Cancellation remains cancellation; an unterminated response still
fails and follows the existing retry policy.

A completed response without usage increments the observed call count and marks
token and cost totals incomplete. Preserve reported subtotals without treating
unknown usage as zero or mixing reported charges with list-price estimates.

Track failed request attempts without reported usage separately from successful
calls. Begin tracking only when invoking transport, after request validation;
preserve uncertainty even if a later retry succeeds. The counter describes outer
request attempts, not individual socket dials. Missing or malformed Responses
usage is also unknown. Text summaries label known subtotals, while JSON and SDK
results expose separate usage-completeness and missing-usage fields.

## Consequences

The fix avoids replaying completed work without shortening the normal trailer
wait. Offline unit and TLS/HTTP2 cases cover delayed usage, omitted usage, empty
completed output, normal termination, and a genuinely unterminated response.
This does not recover failed-attempt usage or establish those attempts' charges.
