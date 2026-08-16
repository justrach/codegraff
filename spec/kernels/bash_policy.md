# Kernel: bash / plan-mode policy

Source of truth: `lean-proofs/Graff/BashPolicy.lean`.

`readOnlyAllowed` is plan mode's auto-run gate:

1. trim space/tab
2. `isSimple` — no `;|&><\`$` / newlines / tab / NUL
3. not `escapesCwd` — no `/`, `~`, `=/`, `=~`, or `..` component
4. `matchesPrefix` against `read_only_seed` (whole-word, space boundary)

`readOnlyExternal` is the #64 twin: simple + seed verb + escapes cwd.
It is never auto-allowed. `zig build` / `zig fmt` are in `seed` but not
in `read_only_seed`.

Not modelled: argv quoting, cmd.exe, the mutable approvals allow-list.
