# 0040. Native codedb stays when codedb-pro is licensed

Status: accepted 2026-08-27

## Context

v0.0.277 hid and refused native `codedb` (and `read_file`) whenever
`codedb-pro probe` succeeded, so a licensed suite was the only read/search
surface. `rlm codedb(...)` hits the same exec gate. A walk of a foreign
repo then failed with "codedb is blocked while the LICENSED
code-intelligence suite is in charge" and fell through to metered
`inspect`/`search`. Native codedb is local, indexed, and free. The
unlicensed prompt already said "always try it first."

## Decision

Native `codedb` stays in the catalog and runs, licensed or not, including
as an rlm host function. codedb-pro is an extra surface (`read`,
`faster_search`, `meta_search`, `batch`), not a replacement for codedb.
`read_file` and leading shell `cat`/`grep`/`rg` may still hide or
redirect while licensed. Companion write tools stay hidden (they bypass
`/rewind`).

## Consequences

- A licensed session can still `codedb context` / `around` / `callpath` /
  `list_dir` / `status` without loading MCP schemas first.
- `read_file` remains the paid-path default for whole-file bytes.
- Do not re-add `codedb` to `hideBuiltin` or `replacedNative`.
