# 0360. Scope bundled input to a Graff turn

Status: accepted 2026-11-27

## Context

A bundled NanoCUA process can outlive the turn that asked it to act. Revoking
input when its MCP connection closes would otherwise keep permission until
the session ended.

## Decision

Bundled Graff uses a new connection for each turn, with an explicit scope
handshake. The separate user consent for Graff's next turn attaches to the
first scoped connection to act. Closing that connection or revoking consent
expires queued and in-progress input. Stop also revokes active turn grants.
Other MCP clients still follow the connection-scoped input grant in ADR 0354.

## Consequences

The NanoCUA panel can stay open while the turn ends and its grant expires.
Both types of input grant require explicit user consent.
