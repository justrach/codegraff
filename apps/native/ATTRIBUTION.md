# Attribution

## Beautiful UI

Copied from https://github.com/slev12397/beautiful-ui (MIT).
See `LICENSE.beautiful-ui`.

- `app/globals.css`
- `components/primitives/*`
- `components/atoms/*`
- `components/site/ThemeSync.tsx`, `ThemeToggle.tsx`
- fonts / token approach from `app/layout.tsx`

## merjs

Native window pattern from https://github.com/justrach/merjs
`examples/desktop/main.zig` (MIT). See `LICENSE.merjs`.

merjs is not vendored as a web framework here. The UI is Next.js so the
React primitives can be used as-is. The Zig file in `desktop/` is the
WKWebView shell only.

## Cuelume

Interface sounds use the `cuelume` package (MIT) by Daniel Belyi, synthesized
in the page. Off until the user turns them on. License:
`third-party/cuelume/LICENSE`. Also listed in `THIRD_PARTY_NOTICES.md`.

https://github.com/Danilaa1/cuelume

