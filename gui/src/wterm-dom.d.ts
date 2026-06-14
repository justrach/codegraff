// `@wterm/dom` exposes a "./css" subpath (see its package.json "exports") that
// resolves to a real stylesheet, imported for its side effects in
// components/workspace-board/TerminalPane.tsx. It has no type declarations, so
// declare it as an ambient module so `tsc -b` accepts the side-effect import.
declare module "@wterm/dom/css";
