# 0140. `rlm` is listed whenever it is available

Status: accepted

Supersedes [0030](0030-rlm-late-showcase.md).

## Context

ADR 0022 made `rlm` the default loop (`--old` restores structured-only).
ADR 0030 then hid it on small turns and only advertised it after `--rlm`,
a ≥4 native batch (`read_file` / `codedb` / `bash` / `webfetch`), context
≥50% of `compactAt`, or an explicit load.

The gate prevents first-turn discovery of the default loop and encourages
serial tool calls before batching is available. A batch-size check cannot
be how a default loop is discovered. ADR 0030 already named that failure
mode as the revisit condition.

#868 already put the spec on the catalog head when available. The leftover
0030 gates (`listed`, `noticeWideNative`, `noticeContext`) still treated
it as hidden. This record kills those gates.

## Decision

When `rlm` is available, it is on the root catalog from turn one — full
schema, no ≥N tool gate, no compactAt gate. `--old` / `--no-rlm` /
`GRAFF_OLD=1` / `GRAFF_RLM=0` still hide it. Do not splice
`rlm_spec.system_note` onto the prefix (ADR 0011). MCP fan-out still
does not change listing.

`noticeWideNative` and `noticeContext` remain as no-op call sites so
agent_tools / agent.zig do not churn; they must not be reintroduced as
gates.

## Consequences

First-turn catalogs already include the `rlm` spec (#868). One-shots can
call it without a warmup batch. Linear MCP structured paths still work;
they are not forced into `each()`. Do not hide `rlm` again because a
short task did not need it.
