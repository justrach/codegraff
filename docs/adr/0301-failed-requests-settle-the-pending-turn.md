# 0301. Exhausted request retries settle the pending turn in history

## Context

A request that exhausts its transport or server retries returns an error while
leaving its user prompt as the last message. The duplicate-turn guard correctly
rejects consecutive host replays, but cannot distinguish that unanswered prompt
from a new, intentional retry. After reconnecting, the same prompt can therefore
return without making any model request. Saving and loading preserves the trap.

## Decision

At the shared request loop's terminal retry boundary, append a truthful assistant
marker saying the model request did not complete and earlier work remains in the
conversation. It is a historical failure boundary, not a fabricated answer or a
claim that tools did not run. The next identical prompt is a new user turn, both
in memory and after saving/loading. REPL, JSON and ACP use the same engine path.

Keep bounded retries, authentication handling, cancellation, duplicate-host
protection and provider selection unchanged. Do not stream the historical marker
as an additional answer or restart the failed request automatically. Ordinary
cloud inference still requires connectivity; existing local-model routes remain
the way to perform inference without it.

## Consequences

A saved conversation retains the failed attempt and its preceding tool results,
so reconnecting does not require restarting or replacing the conversation. The
marker also covers exhausted throttling/server retries, which otherwise leave
the same ambiguous trailing prompt. It is not a promise to resume a failed turn
without a new prompt, and does not add connectivity probes or automatic fallback.

`scripts/test-offline-recovery.py` drives actual ACP v1/v2 and JSON processes
against a failing loopback service, restores that service, and retries the exact
same prompt. ACP also reloads the failed checkpoint before retrying. The fixture
uses fake credentials and does not change the host's network configuration.
