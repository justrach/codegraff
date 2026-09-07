# 0084. Native codedb context honors local-only retrieval

Status: accepted 2026-09-07

## Context

codedb's default `context` composer may send relative paths and bounded
snippets to a hosted embeddings lane for advisory rerank. The tool result
then reports retrieval-privacy metadata and a remote-retention policy
(`none_by_codedb_policy`). #765: that is not equivalent to no network
egress. Project instructions that prohibit transmitting working data had
no effect, and the native schema had no per-call local-only control.

## Decision

When repository policy (AGENTS.md / HARNESS.md / CLAUDE.md phrases, or
`.graff/policy.json` / `.graff/retrieval-policy`) or `local_only=true`
requires on-device retrieval, native `codedb context` dispatches
`codedb context --local` and never hybrid/semantic rerank. If that
boundary cannot be guaranteed (caller asked for `--hybrid`/`--semantic`
under the policy), refuse before spawn and explain. Do not redirect
ordinary reads to codedb-pro (ADR 0040).

## Consequences

- Repos that forbid transmitting working data stay on local BM25/symbol/graph.
- Callers can enforce the boundary with `local_only` even when policy files
  are silent.
- Hybrid remains the default where policy does not require local-only.
- Revisit only if codedb grows a stronger in-process local composer that
  graff should prefer over `--local`.
