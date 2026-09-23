# 0177. Owned async tool execution

Status: accepted 2026-09-23

## Context

A completed direct tool call can arrive while the response is still generating.
Waiting for the entire response unnecessarily serializes independent network
lookups. Starting work without owning its arguments, cancellation, and result
delivery can instead duplicate execution or outlive a turn.

## Decision

Arm early execution only in the root turn, on explicitly supported Responses
routes and models. Advertise and execute only direct read-only network lookups;
programmatic, hosted, mutating, child, evaluation, and compaction paths retain
their existing semantics. An environment switch disables the capability.

Dispatch only complete output items carrying the async flag and original call
identifier. Own arguments and results until delivery, deduplicate identifiers,
and stop early admission at a synchronous or unknown predecessor. Hosted schema
discovery is exempt because it has no pending local execution or mutations;
it never becomes a locally dispatched async job. Admission and
UI lifecycle remain on the owning thread. Join work before the next request,
deliver each result under its original identifier, and never substitute a
placeholder acknowledgement for a result. Interrupted responses cancel and join
owned work, close announced UI events, and cannot transparently replay or fall
back after work has been admitted.

RLM keeps its existing leading-read-only speculation and ordered execution from
ADR 0175. Native async metadata does not make a programmatic tool safe to run
concurrently. Cross-turn pending jobs require a separate design.

## Consequences

Independent generation and lookup latency can overlap without broadening the
mutation concurrency contract. Unit tests cover policy, ownership, ordering,
cancellation, and duplicate delivery; transport fixtures cover both streaming
paths and interrupted responses. Model usage is recorded before the cancellable
join so an interrupted lookup does not erase already reported usage.
