# 0292. Sol's subscription context default is 500k

Status: accepted 2026-10-18.

## Context

The blanket subscription input cap predates GPT-6.1 Sol. It reduced even a
500,000-token account catalog row to 270,000, causing early compaction.
The [upstream announcement](https://x.com/thsottiaux/status/2109430343346581527)
raises this model's Codex and Work default from 272k to 500k. The larger
advertised maximum is a separate value, not a reason to select it
automatically.

## Decision

Use 500,000 for the exact `gpt-6.1-sol` model on `codex` and `chatgpt-new`,
in both offline rows and the subscription clamp. Continue honoring smaller
provider catalog windows. Keep other subscription models at the existing
conservative cap. Leave direct API and gateway windows unchanged.

The shared provider context remains authoritative for the engine, children,
REPL and ACP context reporting. Keep the compaction percentage unchanged:
its default 80% now starts compaction at 400,000 for this subscription model.

## Consequences

Long sessions retain more history without opting into the maximum window.
A stale smaller account catalog stays conservative until refreshed. This
change does not increase account quotas or promise that larger sessions use
the same amount of subscription allowance. Revisit the cap only with new
route-specific evidence, not a name-only API maximum.

## Addendum (2026-11-20)

Live ChatGPT/Codex subscription probes verified that `gpt-6.2-sol` (500k
catalog `context_window`, 872k `max_context_window`) and `gpt-6.2-astra` (272k
catalog `context_window`, 872k `max_context_window`) both accept ~485k+ input
tokens on the subscription route with exact start/end recall. Both models now
use the 500,000 subscription window (`compactAt()` = 400,000) in offline rows,
in the subscription clamp, and when live Codex/ChatGPT catalog discovery
advertises a wider `max_context_window` on `gpt-6.2-astra`. Accounts whose
catalog row does not advertise a wider `max_context_window` remain at the
row's narrower `context_window`.
