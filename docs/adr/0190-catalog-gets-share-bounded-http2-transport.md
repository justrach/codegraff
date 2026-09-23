# 0190. Catalog GETs share bounded HTTP/2 transport

Status: accepted 2026-09-23

## Context

Dynamic model catalogs are startup inputs. Some providers paginate them, and a
later page can fail after earlier pages were valid. The old HTTP/1.1 fetch
followed redirects and accepted unbounded response bodies. The small response
limit for optional JSON POSTs in [0189](0189-bounded-buffered-http2-posts.md)
cannot accommodate complete catalogs with verbose model metadata.

## Decision

Use the same exclusive HTTP/2 pool and joined deadline for catalog GETs. Keep
the page walk and its valid-prefix/cache fallback in the catalog layer. Bound
each page at 16 MiB and reject larger responses before parsing. A page larger
than the picker response is valid; the transport limit must not silently turn
it into a missing catalog. Read the status before the body on both HTTP/2 and
HTTP/1.1, including failed responses whose bodies stall or exceed the cap.

Follow up to three GET redirects within the same deadline on either protocol.
Keep catalog headers on same-origin redirects; send only non-credential Accept
on a scheme, host, or port change. HTTP/1.1 fallback is allowed only before an
HTTP/2 request is sent. The transport allocator owns pooled sessions until
shutdown; the completed page is copied to the result allocator.

## Consequences

Catalog discovery can reuse an HTTP/2 connection across pages without making
startup depend on a partial response or unbounded body. Each concurrent fetch
may temporarily reserve its page limit. A response beyond 16 MiB falls back
to the existing cached or baked catalog rather than activating a truncated
list. The offline TLS fixture covers redirects, credentials, pagination,
large valid pages, limits, status-first failures, and cancellation.
