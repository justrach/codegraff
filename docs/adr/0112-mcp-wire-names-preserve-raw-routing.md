# 0112. MCP wire names preserve raw routing

Status: accepted 2026-09-14

## Context

MCP configuration keys and tool names can contain characters rejected in
function declarations. Deferred loading delays the rejection until a later
request. Replacing punctuation with underscores alone can alias distinct tools.

## Decision

Encode unsafe UTF-8 bytes as `_xHH`, and escape literal escape markers and
server delimiters. Preserve ordinary short identifiers. Reserve `_h` for
empty or oversized components, represented by 96 bits of a SHA-256 digest.
Bound the complete qualified name to 64 ASCII characters. Names depend only
on raw identity, so concurrent discovery and restarts produce the same names.

Store the raw server name on each tool. Use it for eager policy, grouping,
and server-based selection; use the original tool name for MCP dispatch.
Only model-visible identifiers use the encoded name.

## Consequences

Deferred and eager catalogs share the same safe identifiers. Loading remains
subject to existing consent and deferral checks. Previously invalid or oversized
names change, so their saved schema selections must be loaded again. Hashes
have a finite collision probability; ordinary escaped names remain reversible.
