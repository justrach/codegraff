# HTTP/2 lease ownership model

`Http2Leases.tla` models two concurrent requests, two origins, and three possible session identities. The pool has one idle slot. An active request owns an exclusive lease; a second request can dial a different session while the first is active. The source's connection reader is sequential, so the model deliberately does not permit simultaneous streams on one session. This follows ADR 0162.

| Model step | Implementation |
| --- | --- |
| `Acquire` | `src/http2_pool.zig` `takeIdle` removes the idle pointer under `mu`, closes a mismatched-origin idle session, and `acquire` opens a new session outside the lock when needed. `src/agent_stream_h2.zig` `headTask` obtains the lease before `startLines`; `src/http2_buffered.zig` `tryH2` uses the same pool. |
| `MarkEnd` | The `LineStream.ended` state observed after END_STREAM. `agent_stream_h2.zig` `settleAfterEnd` checks this after the application terminal event. |
| `MarkUnusable` | `Session.reusable()` can reject a connection after GOAWAY; streaming and buffered callers require it before setting `keep`. |
| `Release` | `Lease.release` closes a failed/cancelled or surplus session; a reusable lease fills only an empty idle slot. Both callers defer release until their stream is destroyed. |
| `Cancel` | A cancelled request unwinds its own lease with `keep = false`; it does not close the pool's idle pointer or a different active lease. |
| `Shutdown` | `http2_pool.shutdown` removes and closes only the idle session. |

The baseline checks `IdleActiveDisjoint`, `EveryLeaseOwnsLiveSession`, `OnlyEndedIdle`, `IdleOriginKnown`, and `OccupiedWinnerPreserved`. The last property records the occupied-slot release result: the original idle winner remains in the slot and the surplus lease closes. `Http2LeasesRetainIdle.cfg` removes idle-slot detachment on acquire and produces an `IdleActiveDisjoint` counterexample. `Http2LeasesEarlyReuse.cfg` permits a live request to return a session before END_STREAM and produces an `OnlyEndedIdle` counterexample. The mutations alter actions; the invariants remain unchanged.

This is a finite state-machine check, not a proof of HTTP/2 framing, TLS, cancellation machinery, or the implementation language. A session has one exclusive request at a time; the three identities bound at most two active sessions plus one idle candidate. Request origins are abstract atoms, so case-insensitive host normalization and ports are outside the model. Dial/ALPN failures, stream IDs, connection flow control, and OS socket races are omitted. The model treats `ended` as a reliable signal from the pinned HTTP library and `reusable` as its independent connection-health gate. It states safety only: there is no fairness assumption and no eventual-completion or throughput claim.
