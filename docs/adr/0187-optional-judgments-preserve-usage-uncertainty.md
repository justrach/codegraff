# 0187. Optional judgments preserve credential and cost boundaries

Status: accepted 2026-09-23

## Context

An optional judgment runs beside the main model request. Charging or
authenticating it as though it were part of that request hides its route and
can turn a missing receipt into an invented zero.

## Decision

Use the gateway login for this optional request, independently of the active
model credential. The engine owns the behavior for both terminal and ACP
sessions. If the login is absent or the request fails, skip the judgment
without retrying it in the same session.

Count reported tokens from a successful response. Count a charge only when
the authenticated gateway response carries its server-owned, confirmed
settlement receipt in integer micro-USD; never infer a settled charge from a
catalog rate. Without that receipt, leave the charge unknown. Mark a
completed response without valid usage as missing usage, and a failed
request attempt as uncertain. The session tally carries those distinctions
to the terminal summary and ACP usage notification. Scripted mock judgments
never affect the tally.

## Validation

`src/jev_tool.zig` and `src/acp_usage.zig` tests cover confirmed receipts,
successful usage without a receipt, missing usage, failed attempts, unknown
cost, and mock isolation.
