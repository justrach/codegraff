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

Zhang / Li / Khattab (MGH, 2026) argue the other half: RLM's job is
length generalization — expanding the decomposition space so the root
can chunk near-infinite context — not replacing structured tools on
short in-distribution turns. Their 32k/1-needle RL curriculum is how a
small model *learns* that decomposition; it is not a production
token-floor. A naive "fat first payload" trigger is the MCP-slim case
already rejected. The signal that matches the paper is the existing
session meter (`effectiveContextTokens` / `compactAt`): the root is
actually seeing OOD-length context.

## Decision

Fold `rlm` whenever it is available, including `--lean`. Omit it from
the Folded-native listing and from `composeBase` / lean notes until a
showcase. Do not splice `system_note` onto the prefix (ADR 0011). Do
not put `rlm` in the `load_tool_schemas` listing: that rewrites the
tools **head**. Discovery is `markLoaded` so the next catalog carries
the schema on the **tail**.

Showcase when:

- `--rlm` / `setFromCli(true)` — immediate;
- a structured batch of **≥4 native** host tools (`read_file`, `codedb`,
  `bash`, `webfetch`) — the scatter-gather that sPTC overlaps;
- `effectiveContextTokens() ≥ 50%` of `provider.compactAt()` — the
  existing overflow meter, not a second counter;
- explicit `load_tool_schemas tools=["rlm"]` (already `markLoaded`).

`GRAFF_RLM_CONTEXT` overrides the size gate: unset = 50% of compactAt;
`0`/`off` disables; `1`–`100` or `50%` is a percent; `32k` / `32768`
is an absolute floor (Zhang's curriculum, opt-in).

Do **not** showcase on MCP-only fan-out, first slim, or fat-payload
size. `/new` and `/clear` hide a session-discovered showcase; `--rlm`
sticks for the process. `--old` resets discovery.

## Consequences

- L/N keep the structured MCP path: no `rlm` name, no system note, no
  sPTC invitation. Token win is prefix + listing, not another hint.
- Scatter-gather one-shots pay one wide native batch, then see `rlm`
  and can stream-speculate. `--rlm` skips the wait.
- A long session (or a huge user paste) that crosses half of compactAt
  gets the RLM decomposition space without a prefix essay. Tools-head
  bytes stay identical; only the tail grows.
- Auto-load on a confident `rlm` call still works (`gateExec`).
- Revisit if a measured coding one-shot regresses to N serial reads
  because the model never emits a 4-wide batch, never crosses 50% of
  compactAt, and never sees `rlm`.
