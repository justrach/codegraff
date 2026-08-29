# 0040. Native codedb (and read_file) stay the default readers

Status: accepted 2026-08-27

## Context

v0.0.277 hid and refused native `codedb` and `read_file` whenever
`codedb-pro probe` succeeded, so a licensed suite was the only read
surface. `rlm codedb(...)` hit the same exec gate. A walk of a foreign
repo then failed with "codedb is blocked while the LICENSED
code-intelligence suite is in charge" and fell through to metered
`inspect`/`search`. Native codedb is local, indexed, and free.

## Decision

Ordinary reads use native `codedb` or `read_file`, licensed or not,
including as rlm host functions. Do not hide, refuse, or redirect those
to `mcp__codedbpro__read`. codedb-pro is extra search/batch
(`faster_search`, `meta_search`) when codedb cannot answer — not the
default reader. Leading shell `grep`/`rg` may still point at zigrep.
Companion write tools stay hidden (they bypass `/rewind`).

## Consequences

- A licensed session can `codedb context` / `around` / `callpath` /
  `list_dir` / `status` and `read_file` without loading MCP schemas.
- `cat`/`head` of source are not rewritten to pro read; #626 still
  steers a concrete source-file scan toward codedb.
- Do not re-add `codedb` or `read_file` to `hideBuiltin` or
  `replacedNative`.
