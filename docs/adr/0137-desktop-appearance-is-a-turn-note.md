# 0137. Desktop appearance for drawn pages is a turn-local note

Status: accepted 2026-09-17

## Context

`render_html` snapshots run in an opaque origin (ADR 0107), so they cannot read
the desktop's CSS variables. Putting the live palette in `prompt_text` or the
`render_html` tool schema would change the cached prefix / toolset hash on every
appearance switch.

A labeled "Rendered view" card also framed the page in a 620px product well,
so a cream desktop got a dark slab (or the reverse) instead of a figure in the
turn (#1006).

## Decision

On the desktop, resolved appearance tokens (`page`, `surface`, `ink`, and the
rest of the existing token set) ride `session/prompt` as a small turn-local
note. They are not written into `prompt_text` and not into the tool catalog.
Drawn HTML uses that palette unless the user already named colors this turn.

A model-drawn page has no product header and no 620px well. Close/open stays a
quiet control. MCP app results keep their own chrome.

## Consequences

A theme switch does not bust the prefix cache. Existing snapshots still have
whatever colors the model hardcoded; new pages match `--page` / `--surface` /
`--ink` unless the turn already names a palette. The opaque frame and CSP
sandbox are unchanged.
