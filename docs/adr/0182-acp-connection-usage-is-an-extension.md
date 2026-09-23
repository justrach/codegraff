# 0182. ACP connection usage is an extension

Status: accepted

## Decision

Expose cumulative usage since the current connection through the custom
`_codegraff/usage` notification, advertised in `agentCapabilities._meta` under
`codegraff/usage`. Its parameters bind the receipt to `sessionId` and contain a
`usage` object with `scope: "connection"`. This is a Codegraff extension, not a
new member of the standard ACP session-update union.

Emit the receipt after the provider turn returns, including failure and
cancellation, after request uncertainty accounting has settled. Serialize the
whole notification under the existing shared output lock. Delivery is best-effort
and deferred until after turn tracing and checkpoint work; a disconnected client
cannot replace the original outcome with a metadata-write error. Historical conversation
loading does not restore billing totals; clients label the reading "Usage since
connection" rather than implying an all-time session bill.

Token fields are known subtotals. Include cached-read and cache-write counts,
completed calls missing usage, and failed request attempts without usage.
`usage_complete` is false whenever either unknown-usage counter is nonzero.
`cost_usd` is null unless usage and pricing are complete; subscription or unpriced
calls do not imply a zero bill. `known_cost_usd` remains a separate known metered
subtotal. Clients must not derive context occupancy from these billing counters.

The desktop client accepts usage only for its active session, normalizes it to a
client-only reducer event, and displays incomplete totals explicitly. New turns
start without a previous usage receipt. Network retry notices already emitted by
the harness appear in the retry indicator rather than answer prose. Existing
provider retry behavior and request budgets remain unchanged.

## Validation

Tests cover wire serialization, uncertainty after real failed and recovered
requests, terminal-error delivery, client session binding, known subtotals,
subscription billing, cache counts, and retry-notice rendering. The integration
fixture uses only a local scripted HTTP server.
