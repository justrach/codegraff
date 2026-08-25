# 0030. Hide `rlm` on small turns; showcase later (sPTC rides unfold)

Status: accepted 2026-08-25

## Context

L and N (Linear MCP, `--no-lean`, no `each()` hint) are the cheap path:
structured `load_tool_schemas` → list + comments → `report.json`. They
never call `rlm`. Advertising the spec on every turn still costs:

- `--no-lean` spliced `rlm_spec.system_note` onto the always-on prefix
  (~360 bytes, every request) and listed `rlm` among Folded-native tools;
- `--lean` / `-p` unfolded the full schema onto the catalog (ADR 0024:
  one-shots were doing N structured calls instead of one script).

sPTC (`src/spec_ptc.zig` + `rlm.feedLive`) is not a catalog tool. It
only runs when an `rlm` script streams. Listing `rlm` is what invites
speculation — and on grok-4.6, an `each()` hint is a footgun (ADR 0029).
Showcasing because MCP slims would push Linear back into that dialect.

## Decision

Fold `rlm` whenever it is available, including `--lean`. Omit it from
the Folded-native listing and from `composeBase` / lean notes until a
showcase. Do not splice `system_note` onto the prefix (ADR 0011).

Showcase (listing + `markLoaded`, so the next catalog can carry the
schema and sPTC is live) when:

- `--rlm` / `setFromCli(true)` — immediate;
- a structured batch of **≥4 native** host tools (`read_file`, `codedb`,
  `bash`, `webfetch`) — the scatter-gather that sPTC overlaps;
- explicit `load_tool_schemas tools=["rlm"]` (already `markLoaded`).

Do **not** showcase on MCP-only fan-out, first slim, or fat-payload
size. `/new` and `/clear` hide a session-discovered showcase; `--rlm`
sticks for the process.

## Consequences

- L/N keep the structured MCP path: no `rlm` name, no system note, no
  sPTC invitation. Token win is prefix + listing, not another hint.
- Scatter-gather one-shots pay one wide native batch, then see `rlm`
  and can stream-speculate. `--rlm` skips the wait.
- Auto-load on a confident `rlm` call still works (`gateExec`).
- Revisit if a measured coding one-shot regresses to N serial reads
  because the model never emits a 4-wide batch and never sees `rlm`.
