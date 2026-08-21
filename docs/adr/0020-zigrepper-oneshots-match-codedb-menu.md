# 0020. Zigrepper one-shots match the codedb menu

Status: accepted 2026-08-21

## Context

ADR 0019 advertises five codedb one-shots on the native catalog. The paid
suite (zigrepper / `codedb-pro`) still advertised hop tools (`read` /
`faster_search` / `meta_search` / `symbol_search`) so a licensed session
paid 2–5 MCP round-trips for the same *kind* of question. Native `codedb`
is the free in-process index; codedb-pro is the metered companion. They
are not substitutes.

## Decision

Zigrepper ships the same five one-shots (`explain` / `context` /
`callpath` / `list_dir` / `status`) on its own catalog so the paid tool
can answer those questions in one RPC. Hop twins stay dispatchable.
Do not add those verbs to the native catalog or change `read_file` /
`bash` / `edit_file`.

When codedb-pro is licensed, native `codedb` stays callable. Do not
block it and do not redirect it through `mcp__codedbpro__*`. Licensed
enforcement covers `read_file` and leading shell searches only.

Unlicensed sessions keep the conservative “try free codedb first” note.

## Consequences

- A licensed session can use native `codedb around` and
  `mcp__codedbpro__explain` in the same turn — different engines.
- Licensed refusals name pro read/search, never “use pro instead of codedb”.
- Zigrepper must ship the five tools (hops remain callable).
- Native codedb pairing (ADR 0019) is unchanged.
