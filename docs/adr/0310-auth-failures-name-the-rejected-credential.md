# 0310. Authentication failures name the rejected credential

Status: accepted 2026-11-01

## Context

A provider can hold a sign-in (a flat-rate plan) and a metered API key at the
same time (#471). The plan is seated first; when it reports a quota cap,
`handOffExhaustedPlan` promotes the parked key for the rest of the session.
Every terminal authentication rejection used one text, "provider
authentication failed: sign in again or check the API key", whichever seat
failed. Clients read "sign in again" as signed out, so a rejected API key —
including the key a spent plan just handed over to — showed a sign-in prompt
although the sign-in was fine and could not fix it.

ADR 0285 already carries a `reauth_required` action for sign-in seats on the
ChatGPT routes; metered seats carried nothing.

## Decision

`auth_recovery.failureText` words the rejection after the seat
(`Provider.source`) and whether the seat is a promoted key
(`credential_failover.promoted`):

- Sign-in seat: `<Name> sign-in was rejected: sign in again (<login command>)`.
  It keeps "sign in again", so existing clients still read it as signed out.
- Key seat: `<Name> API key was rejected (<source label>): replace or remove
  the key. Your sign-in is not affected.`
- Promoted key: `<Name> plan is out of usage, and the fallback API key was
  rejected (<source label>): replace or remove the key, or wait for the plan
  to reset.`

Both key texts carry the stable phrase "API key was rejected" and never "sign
in again", "log in again", "not signed in", "unauthorized", "authentication
failed" or "invalid api key". The same text is used when the failure lands
after async tools started. Provider failover and subagent failure classes
treat the new texts as the old one.

A key seat's failure carries fixed metadata with no login action:

```json
{ "kind": "api_key_rejected", "provider": "anthropic" }
```

ACP v1 returns it as `error.data` on `-32603` (only a sign-in action is
`-32000`, authentication required). ACP v2 puts it on the failed idle update's
`_meta["graff/recovery"]`, never on `_meta["graff/reauth"]`, which clients read
as signed out. `reauth_required` and its wire positions are unchanged.

## Consequences

A client can tell "replace the key" from "sign in" without parsing provider
words, and an old client no longer offers a sign-in for a rejected key. The
generic message text is gone; anything matching it must match the new phrases.
