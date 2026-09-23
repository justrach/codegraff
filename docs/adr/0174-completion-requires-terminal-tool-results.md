# 0174. Completion requires terminal tool results

Status: accepted 2026-09-23

## Context

A shell call can return successfully while its process is still running. Such a
receipt is not evidence that verification passed. Reading a background job also
needs to preserve its terminal exit status instead of returning unconditional
success.

## Decision

Tool results carry an explicit pending bit separately from errors and cancellation.
Deferred completion rejects pending, failed, or cancelled companion results.
Background output reports a failure for a nonzero or abnormal terminal exit.
Normal background launch remains a successful launch with pending work.

## Consequences

Verification and completion may share a response only after the executed check
produces a successful terminal result. Tests cover pending launches and resumed
successes and failures. The prompt does not ask for redundant verification merely
to combine it with completion.
