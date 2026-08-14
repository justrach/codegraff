# Repository instructions

## Terminal UI: what's ours to change

- **Colors, bold/dim, glyphs, layout are ours.** Styling travels in the output byte stream as SGR escape sequences, so the app controls it per character. The palette lives in `src/ansi.zig` (the accent is codegraff.com's emerald `#059669`; coral/red hues are reserved for errors).
- **The font is not ours.** The terminal emulator owns the typeface — it loads the font, measures the cell grid, and rasterizes glyphs itself; the wire protocol has no sequence for an app to request a font. (xterm's legacy `OSC 50` is unimplemented by modern emulators and would hijack the user's whole terminal — do not emit it.) If a user asks to "change the REPL font," the answer is their terminal's config, e.g. `font-family = Geist Mono` (the site's typeface) in Ghostty — never a code change here.
- **HDR/wide-gamut color is not ours either.** Truecolor SGR is 8-bit sRGB per channel — the protocol's ceiling; no sequence expresses Display P3 or EDR headroom, and macOS terminals clip app colors to SDR regardless of the panel. Pick values that look right on both P3 and sRGB displays (as `#059669` does); that's the whole lever.

## Driving the pager (no PTY, no Ghostty window)

Do not spawn `graff tui` or a terminal emulator to inspect or click the pager.
The headless session is `TUI/sim.zig` (`Term`): the same `key.next` → `keys.handle`
→ `render` → `dump.visible` path Ghostty uses on a real TTY.

```zig
var term: @import("sim.zig").Term = undefined;
term.init(alloc, 80, 24);
defer term.deinit();
_ = term.typeText("/help");
_ = term.enter();
const vis = try term.screen();          // glyphs a user would see (no SGR)
const rows = try term.annotated();      // " 12|  ◆ Called 2 tools"
_ = try term.clickText("Called");       // click the first matching glyph
_ = try term.hoverText("[Image #1]");   // hover an image chip
const lay = try term.layout();          // overlay / focus / origins / images / pending
```

High-level helpers (`typeText`, `enter`, `clickText`, `hoverText`, `clickAt`,
`hoverAt`) are enough for most work. When you must speak Ghostty's wire:

| input | bytes |
|---|---|
| printable | the UTF-8 itself |
| Enter | `\r` |
| click at (col, row) | `ESC [ < 0 ; COL ; ROW M` (1-based cells) |
| hover | `ESC [ < 35 ; COL ; ROW M` |
| bracketed paste | `ESC [ 200 ~` … body … `ESC [ 201 ~` |
| CSI-u (Ctrl+P) | `ESC [ 112 ; 5 u` |

Feed those with `term.feed(bytes)`. Coordinates are 1-based screen cells, same
as SGR mouse. Read `term.annotated()` to pick a row, then `clickAt(x, y)`.

`/debug` stays the observability HUD; `term.layout()` is how you see why a
click missed (overlay, prompt-origin, mid-origin).

## File size

- Keep every hand-written source file at or below 600 lines of code.
- When a change would push a file past 600 LOC, split cohesive responsibilities into focused sibling modules as part of the same change.
- If a touched file is already over 600 LOC, do not grow it; move it toward the limit before adding more behavior.
- Generated files, vendored dependencies, lockfiles, and machine-produced artifacts are exempt; change their generator or source instead of hand-editing them.

## Tests must be reachable

- `zig build test` only runs the tests in files the test root pulls in. A new module's `test {}` blocks compile to nothing until something references it, and the suite still reports green.
- A new test-bearing module needs a reference in `src/main.zig`'s `test {}` block: `_ = @import("your_module.zig");`.
- Prove it with the count, not with hope: the suite total must go up by the number of tests you added. `scripts/eval-tier1.sh --only reach` fails on any file that declares tests nothing imports.

## Before you push

Install the tracked hooks once, and the checks run themselves:

```bash
scripts/install-hooks.sh
```

That points `core.hooksPath` at `.githooks/`, whose `pre-push` runs **tier 1** of the internal eval set: `zig fmt`, the 600-line ceiling, test reachability, `zig build`, the unit suite plus a count that may grow and never shrink, the named goal/loop/todo invariants, and SDK drift. It is deterministic and offline (no provider calls, no network, no spend) and takes about 20 seconds warm. A push that only touches docs skips it.

```bash
scripts/eval-tier1.sh                 # run it by hand
scripts/eval-tier1.sh --only sdk      # rerun one check
scripts/eval-tier1.sh --list          # the check names
git push --no-verify                  # emergency skip (GRAFF_SKIP_PREPUSH=1 also works)
```

Failures name the invariant, say which regression it guards, and print the command that reruns only that check. The required invariants and the docs-only path list are data in `scripts/eval/tier1-manifest.json`.

Two rules the hook enforces that are easy to trip:

- **The suite count is a ratchet.** If it drops, either restore the tests or lower `test_count_baseline` in the manifest in the same commit, with a reason in the message. Nothing raises it for you: bump it at each release cut, and tier 1 warns once the real suite has run more than `test_count_slack` (25) tests ahead of the floor, because a floor that far behind would not notice a whole module falling out of the test root.
- **The SDKs are generated, not written.** Run `python3 sdk/generate.py --harness ./zig-out/bin/graff` after any change to the model catalog, tool schemas, or provider list, and commit the result.

## Tier 2: model-backed behavior

Behavior regressions do not show up in a unit suite. **Tier 2** runs the harness for real, so it is opt-in and never in the hook. Cases are data in `evals/harness_behavior.jsonl`, one line each, carrying the regression it guards. The model is scripted (`scripts/eval/mock_model.py`), so the default run is offline and free.

```bash
python3 scripts/eval-tier2.py                 # every case
python3 scripts/eval-tier2.py --list          # the cases and what they guard
python3 scripts/eval-tier2.py --only <id>
python3 scripts/eval-tier2.py --dump <id>     # every event and request from one case
```

Add a case when you fix a behavior bug: script the model replies that provoke it, then assert on the events the harness emitted or on what it sent back to the model. Run it against a real provider with `--provider`/`--model` when you care how the model behaves rather than how the harness does.
