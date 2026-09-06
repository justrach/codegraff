# README imagery

The README uses CodeGraff's workshop artwork: black field mice in coral coats,
textured paper, ink, cobalt, and restrained editorial typography. Desktop plates
add rounded presentation frames and soft shadows around actual GUI captures.
The desktop sequence moves from White on rice paper, through the warm CodeGraff
palette on coral, to Black on cobalt. The screenshots are unchanged; the window chrome outside them is presentation
decoration. README links open the original PNGs for closer inspection.

## Regenerate

Install the desktop dependencies with `bun install` in `apps/native`, then run
from the repository root:

```sh
apps/native/node_modules/.bin/electron docs/media/render-readme.cjs
```

The renderer uses a temporary Electron profile, blocks network requests, waits
for fonts and images, checks viewport bounds, and writes PNGs into `docs/images`.
The outer corners have a 48-pixel radius and transparent pixels, so they blend
into either GitHub theme. Export checks verify all four corners are transparent.
Exports have a fixed width of 1920 pixels on both standard and Retina displays.

`readme-plates.cjs` owns the copy, artwork selection, and source screenshot paths;
`readme-plates.css` owns the layout. Original artwork is in `art/`. Keep real
conversation data out of source captures; use the desktop's scripted visual
fixtures described in [the visual test guide](../../apps/native/electron/VISUAL-TESTS.md).

For the official typography, set `GRAFF_DESIGN_FONTS` to a local directory
containing licensed `SinarGrotesk-SemiBold.woff2` and `Gramatika-Regular.woff2`.
Font files are not redistributed here. Without that variable, the layouts use
system fonts. Review the rendered images after changing typography or copy.
