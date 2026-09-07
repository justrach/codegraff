# 0086. Native codedb context is local-first

Status: accepted 2026-09-07

## Context

codedb's composer defaults to hybrid advisory rerank: local BM25/symbol
hits plus a hosted embeddings lane. That network hop is why a bare
`codedb context <task>` often sits for seconds (and can ride the 60s
tool deadline) even when the index is warm. ADR 0084 made `--local`
mandatory under repository policy; everywhere else graff still spawned
the hybrid default.

## Decision

Bare `codedb context <task>` dispatches `codedb context --local`. Remote
rerank is opt-in via `--hybrid` or `--semantic`, and those flags are
still refused before spawn when policy or `local_only` requires
on-device retrieval (ADR 0084).

## Consequences

- Typical context calls stay on-device (BM25/symbol/graph) and return
  without waiting on embeddings.
- A caller that wants the hosted rerank must say so.
- codedb's own default is unchanged; graff injects `--local` at spawn.
