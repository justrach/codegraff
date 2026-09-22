# 0160. Running model picks apply at the next prompt boundary

Status: accepted 2026-09-22

## Context

Changing the desktop model used to restart its worker immediately, so the
picker was disabled during a response (#1082). A follow-up needs an independent
model choice without losing the response already in progress.

## Decision

A model picked during a response is staged per chat and marked “Next”. Apply
it by restarting and resuming that chat at the next prompt boundary, including
an automatically dequeued follow-up. Never cancel or reset the running turn
because its picker changed. Repeated picks replace only that chat's staged
choice; a failed restart keeps the choice available for retry. Choices made
while a restart is in progress remain staged for the following prompt.

## Evidence

`apps/native/lib/next-model.test.ts` covers isolation, replacement, cancellation
of a staged choice, startup failure, and changes during startup.
`apps/native/scripts/test-model-catalog.mjs` drives a streaming response,
changes the model, queues a follow-up, and checks reset/prompt ordering.
