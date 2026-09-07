# 0092. Native codedb context is local-first

Status: accepted 2026-09-07

## Context

codedb's composer defaults to hybrid advisory rerank: local BM25/symbol
hits plus a hosted embeddings lane. A bare `codedb context <task>`
therefore waits on a remote dependency even when the index is local.
ADR 0084 made `--local` mandatory under repository policy; everywhere
else graff still spawned the hybrid default.

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
