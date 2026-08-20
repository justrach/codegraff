# 0012. Line REPL chrome is a WORKING block plus a bare ›

Status: accepted 2026-08-20

## Context

The default `graff` session is a line REPL, not `graff tui`. Stuffing goal,
checklist, model, cwd, context, and cost into `[model · …] ›` and a
`Goal … · 2/4 todos` row gave every fact the same visual weight. Tool lines
that said `✓ bash ·` named the harness, not the work.

Variations 4 (tool tree) and 5 (git-style status) were the ones we wanted:
execution is a graph, standing work is persistent state, and the input line
should be the eye's rest.

## Decision

- Standing goal and its checklist render as a `WORKING` block above the prompt,
  not as badges on the input line. A progress bar sits under `N of M` so the
  checklist is state, not more narration.
- The prompt is a bare `›`. Model, ctx, cost, `/resume N`, and a staged image
  sit on one dim line above it.
- Parallel tool batches are a `├─` / `└─` tree. Sequential calls are flat.
  There is no `↯ N in parallel` tally when everything succeeded.
- Result lines use a short verb (`test`, `edit`, `read`), never `bash`.
  Announce lines stay off the default transcript.

## Consequences

The pager (`graff tui`) keeps its own chrome; it still receives the same
`.prompt_ready` / tool events. Operational badges that change what the next
turn will do (Plan, Strict, Fast, Fallback) remain on the dim status line.
`/help` still lists keys; they are not reprinted every session.
