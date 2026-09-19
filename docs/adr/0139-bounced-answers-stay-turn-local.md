# 0139. Bounced answers stay turn-local

Status: accepted

## Context

A lean retry can refer to an earlier answer that a single-result caller never
received (#1013). Recovering that answer by searching message history also
finds retries from previous turns and can replace an unrelated new answer.

## Decision

Capture a nonempty first answer only when the current `runTurn` actually
bounces it. Keep that value on the turn stack, not in persisted history.
Return it only when the retry performed no tools. A later turn starts with
no captured answer, and tool progress makes the newer answer authoritative.
Apply this choice before unfinished-work reconciliation so its stop notice
is not lost. Explicit informational requests remain exempt from the bounce.

## Verification

The old history scan failed a regression in which a later arithmetic question
returned an earlier answer. The turn-local version passes that regression,
first-answer retention, tool-progress, and empty-answer cases.
