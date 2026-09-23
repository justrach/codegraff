# 0162. HTTP/2 streams own exclusive sessions

Status: accepted 2026-09-23

## Context

The HTTP/2 connection reader is sequential, not a stream multiplexer. Returning
one shared mutable session after unlocking the pool allowed concurrent parent
and child requests to read each other's frames. Switching origins or cancelling
one request could also close another request's active session.

## Decision

The process pool holds at most one idle session. A request removes that session
under the pool mutex and owns an exclusive lease until its stream is destroyed.
Concurrent requests dial independent sessions outside the mutex. Only a stream
that reached END_STREAM can return its session to an empty idle slot; failed,
cancelled, or surplus sessions close through their own leases.

## Consequences

Sequential requests retain connection reuse. Concurrent requests pay for
separate connections rather than serialize behind long streams. Cancellation
cannot invalidate another request's connection. True HTTP/2 multiplexing would
require a connection-owned reader and per-stream dispatch before relaxing this
ownership rule.

The local TLS integration test gates responses on simultaneous parent and
background-child requests, while unit tests cover lease ownership and release.
This corrects a demonstrated transport hazard; it does not establish the cause
of a separately reported resolver crash.
