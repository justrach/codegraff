# 0050. Reuse warmed TLS state on the networks we already speak

Status: accepted 2026-08-29

## Context

The harness already talks to three networks: provider HTTP/SSE (and WS),
MCP Streamable HTTP, and the Codegraff gateway. Two patterns were wasting
a handshake on every first useful call:

1. MCP Auto's modern `tools/list` probe and the legacy
   `notifications/initialized` notify each built a throwaway `std.http.Client`,
   so a successful probe's keep-alive died before `tools/call`, and initialized
   paid a second TLS for a fire-and-forget 202.
2. Every WSS dial (`ws.WsClient.connect`) rescanned the host CA store from
   disk, even though launch already warms the HTTP client's bundle.

ADR 0002 (xAI WS full-resend), 0009/0011/0028 (prompt-cache keys), and 0035
(deferred MCP join) stay untouched: this is transport reuse, not wire shape.

## Decision

- MCP HTTP probe and `notifications/initialized` use `server.transport.http`.
  Do not construct a per-call client for those paths.
- WSS TLS uses a process-lifetime CA bundle warmed once (`http_warm.ensureProcessCa`).
  A reconnect must not walk the host store again.
- WS→SSE fallback keeps the Agent's prewarmed HTTP pool (`postStream`). Do not
  introduce a fresh client on that latch: WS never used the HTTP pool, and a
  new TLS would be strictly more expensive.
- MCP Streamable HTTP advertises the std client's default Accept-Encoding
  (gzip/deflate) and decompresses Content-Encoding. Do not omit it: a tools/list
  catalog is the fat payload on that network, and provider POST already accepts
  compression.

## Consequences

A modern MCP connect plus the next list is one TCP accept on keep-alive.
WSS reconnects skip the CA disk walk. MCP catalogs can travel gzip-compressed.
Revisit only if a shared `std.http.Client` is shown unsafe for the concurrent
initialized+list pair, a host CA rotation must be picked up mid-process without
restart, or a server is broken by Accept-Encoding.

## Measured (2026-08-30, this host)

| Path | Before | After | Left on the table |
|---|---|---|---|
| MCP modern connect + next `tools/list` | 2 TCP accepts (throwaway probe client, then the persistent one) | 1 accept, 2 POSTs | nothing — keep-alive is the rest |
| WSS CA disk walk | 1 `rescan` per connect, including every reconnect | 1 per process | launch still walks once for the HTTP client (~5–7 ms, 144 certs / 154 KB here). Cloning that bundle into the process one saves one launch scan and risks a double-free; not worth it |
| MCP `tools/list` catalog (40-tool fixture) | 6110 B raw (`Accept-Encoding` omitted) | 320 B gzip (5% of plaintext) | only if the server ignores gzip — then we still send the header and read identity |
| WS→SSE latch | prewarmed Agent HTTP pool | unchanged | a fresh client would add a TLS handshake |
| xAI / Codex WS turn body | full history | unchanged | ADR 0002: no `previous_response_id` chain |
| MCP OAuth token / login 401 probe | throwaway `std.http.Client`; login probe omits encoding | unchanged | not on the turn path |
