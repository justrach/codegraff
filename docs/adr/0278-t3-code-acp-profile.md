# 0278. T3 Code gets its own ACP profile

Status: accepted 2026-10-10

## Context

T3 Code runs any ACP Registry agent through one generic driver and gives each
thread its own agent process. Run against graff over ACP v1, four things broke:

- T3 appends a context block after every prompt, so a slash command arrived
  as `/models` plus T3's context and graff refused it as an unknown command.
- A second thread in the same checkout auto-isolated into
  `.graff/worktrees/session-*`, and because the session `cwd` named the
  owning checkout, `acp_workspace.adopt` kept that tree. Edits never reached
  the folder T3 diffs and checkpoints.
- T3's model picker reads a `model`-category config option; graff only offers
  its model list through the `graff/models` vendor method, so T3 showed one
  "Default" model.
- graff's `/model` duplicated T3's own, and `/yolo` bypassed T3's approval
  modes.

Harness and other clients rely on the opposite behavior for the worktree rule
and read models through `graff/models`.

## Decision

`initialize.clientInfo.name` starting with `t3-code` switches on a profile
(`acp_t3.zig`); no other client sees it.

- A slash command is the prompt's first text block alone; multi-line command
  output goes out as a text block so tables keep their columns.
- The client's `cwd` is entered as named, never kept as an auto-isolated tree.
- `session/new` and `session/load` add a `model` option (`acp_model_option.zig`):
  the reachable models in `graff/models` order, current first, at most 48.
  Choosing one runs `/model <provider> <model>`.
- The advertised commands omit `model` and `yolo`.

## Consequences

graff behaves like a native T3 provider without T3 shipping graff-specific
code, which its contribution guide rules out for registry agents. The
profile keys on a client name, so a T3 rename silently turns it off;
`acp_t3_tests.zig` pins the behavior for the names T3 sends today. Revisit
any rule that later becomes right for every client (the first-block slash
rule is the likeliest) by moving it out of the profile.
