# 0043. Reuse warmed TLS state on the networks we already speak

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

## Consequences

A modern MCP connect plus the next list is one TCP accept on keep-alive.
WSS reconnects skip the CA disk walk. Revisit only if a shared `std.http.Client`
is shown unsafe for the concurrent initialized+list pair, or if a host CA
rotation must be picked up mid-process without restart.
