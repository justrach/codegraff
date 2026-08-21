# 0019. codedb one-shots beat hop chains

Status: accepted 2026-08-21

## Context

[graphify](https://github.com/safishamsi/graphify) spends fewer agent
calls because the verbs are neighborhoods, not lookups: `query` (task
subgraph), `explain` (ego graph), `path A B` (shortest chain). codedb
already has the same primitives — `context <task>` (task-shaped
composer), `callpath A B` (resolved call graph BFS), PageRank god-nodes
inside the index — and it is deterministic AST, not an LLM extractor.
The harness advertised `search` / `symbol` / `callers` / `outline` as
siblings, so models paid 3–5 round-trips for one question. `callpath`
was implemented in codedb and blocked here.

## Decision

The catalog advertises five commands only: `context <task>`,
`around <name>` (def body + callers in one harness call), `callpath A B`
(`path` is an alias), `list_dir <path>`, `status`. Hop verbs
(`search` / `symbol` / `callers` / `outline` / `read` / …) stay
callable so a follow-up is not a dead end; they are not named in the
tool description or the system prompt. Do not add a graphify-style LLM
extract / wiki / GRAPH_REPORT inside graff — that is a different
product. Do not add a sibling catalog tool for "ask the graph."

## Consequences

- First-touch orientation is one model hop when the model follows the
  description.
- `around` is two codedb CLI spawns, one tool result. A codedb release
  with a native `explain` can replace the composer later.
- graphify still wins on multimodal docs/images and a written wiki;
  codedb still wins on local, labeled, sub-millisecond structural edges.
