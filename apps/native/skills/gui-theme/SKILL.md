---
name: gui-theme
description: Create or adjust a CodeGraff desktop theme when selected with @gui-theme or $gui-theme in the GUI composer.
---

# GUI theme

This skill is supplied by the GUI for this request. It is not an engine skill
or a terminal theme. Use ordinary file tools to create a portable JSON theme;
do not patch the app, engine, shell settings, or built-in palettes.

Follow the requested mood, colors, and light/dark preference. If the user only
invoked the skill, ask for their preferred look before creating anything.
Otherwise make a coherent first version and iterate from feedback.

## Theme file

Save one JSON file in the theme directory supplied below these instructions
(normally `~/.graff/themes`). The filename must match its `id`, for example
`midnight-garden.json`. Inspect an existing file before replacing it; preserve
other themes. A new id creates a separate choice in Appearance.

```json
{
  "version": 1,
  "id": "midnight-garden",
  "name": "Midnight Garden",
  "base": "dark",
  "colors": {
    "page": "#15201c",
    "canvas": "#101914",
    "surface": "#1c2a23",
    "ink": "#f1f7ee",
    "ink-2": "#c1d4c3",
    "ink-3": "#a3baa6",
    "accent": "#a4d98c",
    "accent-ink": "#b5e79e",
    "accent-tint": "#2c422c",
    "line": "#3e5446",
    "field": "#23342b"
  },
  "font": "system",
  "corners": 10
}
```

The schema is version 1, maximum 16 KiB. IDs use lowercase letters, digits and
hyphens, start with a letter, and are at most 48 characters. Names are at most
60 characters. Base is `light`, `dark`, `website`, or `codegraff`.

Required colors: `page`, `surface`, `ink`, `ink-2`, `ink-3`, `accent`,
`accent-ink`, `accent-tint`. All colors are six-digit hex strings.
Optional colors: `canvas`, `inset`, `hover`, `hover-2`, `line`, `line-strong`,
`field`, `stripe`, `stripe-bg`, `green`, `green-tint`, `red`, `red-tint`,
`orange`, `orange-tint`, `brand-coral`, `brand-gold`.
Unset tokens inherit from the base. For a coherent result, customize surfaces,
borders and status colors too, while preserving recognizable success/error states.
Optional `font`: `geist`, `system`, or `serif`; code retains its monospace font.
Optional `corners`: integer 0–20 pixels for controls, chips and cards.
No arbitrary CSS, URLs, scripts, external fonts, or executable assets.

## Validate and deliver

Parse the JSON after writing it. Check text contrast on both `page` and
`surface`: aim for at least 4.5:1 for all ink tokens, including secondary text
and `accent-ink`. Check selected states, input fields and error/success colors.
Appearance reports schema errors and low-contrast warnings. Correct these
before calling the theme finished.

Tell the user to open Appearance and choose the new theme under My themes.
The panel refreshes while open, without rebuilding or restarting the app.
Selecting a built-in theme restores its defaults. Theme selection remains the
user's choice: creating a file does not silently switch their theme.
The JSON file is shareable using Import theme in another desktop installation.
