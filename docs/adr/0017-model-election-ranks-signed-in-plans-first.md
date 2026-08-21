# 0017. Model election ranks signed-in plans first

Status: accepted 2026-08-21

## Context

The same model is often three seats: Codex (a ChatGPT plan), Codegraff
(gateway credits), and a metered vendor key. Opening `/models` (TUI
overlay; line-REPL table) used to walk `pricing.models()` in catalog
order, so a signed-in Codex row sat wherever the bake put it — often
below Codegraff. The TUI picker already preferred plan once the user
typed; the empty list and the line-REPL dump did not. Two ranking
functions (TUI `CostClass` weights vs REPL `sub_login`) were a drift
waiting to happen.

## Decision

One rank, in `src/models_rank.zig`, imported as the `models_rank` build
module (Zig 0.17 will not let the harness and TUI file-import the same
source). Both frontends call it:

1. a credential beats no credential (a signed-in paid seat is usable;
   an unsigned plan is only a map entry);
2. then plan, then local, then credits, then api;
3. then catalog index.

Empty query and typed query share (1) and (2). A typed query adds the
existing name/fuzzy score on top. Do not hide unpaid rows.

## Consequences

The empty `/models` list is no longer "the map of what exists" in
catalog order; it is an election. Catalog order remains the tie-break
and the source of the rows. Revisit if a user needs a stable
alphabetical or provider-grouped dump — that would be a separate
command or a sort toggle, not a silent revert of this rank.
