# 0183. Request policy owns ambiguous retries

Status: accepted

## Decision

A send failure does not prove that a request failed to reach the server.
The HTTP/2 streaming transport must return ambiguous failures to the request
policy instead of replaying the body or silently switching to HTTP/1.1.

HTTP/1.1 fallback remains available before a request is sent, or when a valid
GOAWAY or REFUSED_STREAM response proves the stream was not processed. A
malformed GOAWAY does not provide that proof, and later GOAWAY frames cannot
raise the last accepted stream limit.

The existing request policy still controls bounded retries and backoff. Its
attempt ledger marks failed attempts without usage as unknown, and its retry
events remain observable. This is not an exactly-once guarantee: retrying an
ambiguously delivered request can repeat remote work.

## Validation

Unit tests cover fallback classification and GOAWAY handling. A local fault
fixture injects an error after the body flush and verifies that recovery passes
through the request policy and its uncertainty ledger. The dependency also
reconnects before reusing a session whose failed connection was torn down.

Run `python3 scripts/test-acp-http2-retry.py` after `zig build` to exercise the
pinned dependency through local TLS, HTTP/2, and ACP without provider calls.
