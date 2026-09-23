# 0189. Buffered HTTP/2 posts bound memory and own their lifetime

Status: accepted 2026-09-23

## Context

An optional JSON request needs a complete response before parsing. A line-based
reader can grow without a limit when a peer sends JSON without newlines. A
pooled connection also outlives the request arena that owns the parsed result;
allocating the connection from that arena leaves a dangling idle session.

## Decision

Read response DATA in chunks into a fixed 64 KiB buffer, rejecting growth
before copying. Inspect the status before accepting the body. Hold an exclusive
HTTP/2 session lease through the response and return it to the pool only after
END_STREAM. Allocate pooled transport state with an allocator that lives until
pool shutdown, and copy completed response bytes into the caller's result
allocator.

Join the request worker before returning on the deadline or cancellation, so
its input, credentials, and buffers can be released safely. Fall back to
HTTP/1.1 only when connection setup or ALPN fails before sending the POST.
After an ambiguous send, return the error without replaying the request.

## Consequences

Oversized or stalled responses fail the optional request instead of growing
memory or holding its caller indefinitely. A successful pooled session remains
valid after the result arena is destroyed. This helper buffers only small JSON
responses; larger payloads need a separate streaming contract.

`scripts/test-jev-http2.py` exercises the local TLS cancellation, ambiguous
send, and pool-reuse paths without a remote service.
