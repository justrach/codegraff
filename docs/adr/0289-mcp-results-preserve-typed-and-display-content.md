# 0289: Preserve MCP typed results independently of display content

Status: accepted

## Context

MCP tool results may contain a human-readable summary, images or resources,
and independent `structuredContent`. Treating structured data as an empty-text
fallback silently loses fields. Resource links and embedded resources also need
visible representations rather than an empty result. A server may send a ping
while the client is waiting for initialization or a tool response.

## Decision

The shared MCP client preserves both representations. Ordinary tool output keeps
text, image staging, resource references and embedded text, followed by structured
JSON when it is not already a mirrored JSON fallback. RLM bindings consume the
complete structured JSON when supplied; display summaries do not replace it.
The typed slice borrows from the final owned output, never the response arena.
Shape learning uses the typed result too.

Resource URIs are displayed, not fetched automatically. Unsupported binary/audio
payloads receive explicit notes without dumping encoded data. Request-scoped
stdio readers answer valid inbound pings with an empty result and the same ID,
including during initialization. Existing elicitation, cancellation, matching
responses, and no-replay rules remain intact.

## Consequences

The common registry/execution path gives REPL and ACP clients the same behavior.
No client-only UI change or model prompt change is needed. This does not add
full output-schema validation, audio playback, or an idle background read pump.
Protocol interoperability fixes do not imply a reduction in model generation
latency; that must be measured separately.

## References

- MCP specification, `2026-07-28/server/tools.mdx`: structured and resource content.
- MCP specification, `2025-11-25/basic/utilities/ping.mdx`: bidirectional ping.
- ADR 0029: MCP inside RLM and return shapes.
