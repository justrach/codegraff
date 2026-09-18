# 0124. `rlm` is listed whenever it is available

Status: accepted

Supersedes [0030](0030-rlm-late-showcase.md).

## Context

ADR 0022 made `rlm` the default loop (`--old` restores structured-only).
ADR 0030 then hid it on small turns and only advertised it after `--rlm`,
a ≥4 native batch (`read_file` / `codedb` / `bash` / `webfetch`), context
≥50% of `compactAt`, or an explicit load.

That gate is the reason Astra in Graff never entered the programmatic
loop. Local Codex Astra recordings put discovery and several tools inside
one `exec` on the first round. Graff's sampled Astra turns stayed on
serial `read_file` / `bash` because the model never emitted a 4-wide
batch, never crossed half of compactAt, and never saw `rlm`. ADR 0030
already named that failure mode as the revisit condition.

A batch-size check cannot be how a default loop is discovered.

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

First-turn catalogs are larger by the `rlm` spec. One-shots can call
`rlm` without a warmup batch. Linear MCP structured paths still work;
they are not forced into `each()`. A later measurement can still compare
`--old` against the default loop. Do not hide `rlm` again because a
short task did not need it.
