# Desktop design

This is the rule for the graphical app, not a mood board. **Native** (`apps/native`) is the reference. The GUI (`gui/`) matches these radii when those files are touched. The TUI is a different medium — SGR in `src/ansi.zig`, see AGENTS.md — and is out of scope here.

The prompt bar’s 32px corner and circular send are the product shape. Everything else follows the same scale instead of inventing a one-off radius.

## Radius

Do not write `rounded-[Npx]` for chrome. Use the tokens in `apps/native/app/globals.css` (`rounded-chip`, `rounded-control`, `rounded-card`, `rounded-window`, `rounded-composer`, `rounded-full`):

| Token | Size | Use |
|---|---|---|
| `chip` | 8px | Tags, attachment chips, tiny glyphs |
| `control` | 12px | Text fields, rectangular controls, queue rows |
| `card` | 16px | Inner cards, tables, code blocks, user bubbles |
| `window` | 24px | Panes, dialogs, menus, overlays |
| `composer` | 32px | Prompt bar, large sheets |
| `full` | 999px | Icon-only buttons, labelled pills, send |

The one exception: **nested split panes stay `rounded-[6px]`** so a 2×2 grid does not look like stacked soap bubbles.

## Buttons

- **Icon-only** (28×28 / `size-7` / `size-8`): a circle (`rounded-full`). Hover fill is a circle, not a squircle.
- **Send** is a filled circle with the up-arrow. While a turn runs it stays a circle; the stop glyph is a small rounded square *inside* it.
- **Labelled buttons** are pills. `apps/native/components/atoms/Button.tsx` is already `rounded-full` — keep it that way.
- Do not use an 8px radius on a 28px square control. That is the old send button.

## Color

Themes live in `apps/native/app/ui-theme.css` and `appearance.css`. Components use tokens (`bg-surface`, `text-ink`, `border-line`, `bg-accent`), never a one-off hex.

- Accent comes from the active theme (website emerald `#059669`, codegraff cobalt, etc.).
- Red / coral is for errors and destructive actions, not chrome.

## Type

`--font-sans` and `--font-mono` from the theme. Do not ship a second typeface in the desktop app. (The TUI cannot set a font; that stays the emulator.)

## Motion

Enter and layout use `--ease-out-strong`. Do not add bounce, spring, or a new duration unless the file already has that motion. Reduced-motion paths already freeze decorative loops; keep them.

## Custom themes

A theme’s `corners` value (0–20) overrides **chip / control / card only**. Window and composer stay the product radii so the app does not flatten back into a rounded rectangle.

## Do not

- Copy another product’s palette, plus-button, or model picker. Roundness is the borrowed part; the rest is ours.
- Add a per-component radius “because this overlay is special.”
- Change TUI glyphs, SGR, or layout under this document.
- Grow a file past 600 lines to restyle it; restyle in place.
