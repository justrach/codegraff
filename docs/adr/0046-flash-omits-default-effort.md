# 0046. Flash models omit default `reasoning_effort`

Status: accepted 2026-08-29

## Context

ADR 0045 ran Codegraff `glm-5.3-flash` SWE after the `-p` learn skip.
Pi 5/6 in 758s (`first` 0.6s). Graff 3/6 in 1353s (`first` 6.9s) with
three 300s timeouts that never edited. Output on the tasks that
finished was 3.5–7.5k tokens. `validated` was 10 calls / 164s vs Pi
5 / 26s.

Pi's `first` is the JSONL `session` line, not first model work — do
not treat 0.6s as a TUI steal. The real gap is that Pi's
`models.json` sets `reasoning: false` / `supportsReasoningEffort:
false`. Graff's codegraff spec has `takes_effort = true`, so an
uncatalogued flash model inherited **default medium**
`reasoning_effort` on every request.

That is the same footgun Gemini already had: default medium maps to
seconds of thinking (2× wall vs Pi). The Gemini skip was
`startsWith("gemini")` only, so `glm-5.3-flash` still thought.

The lean keep-list is already 8 tools (ADR 0024: an rlm-only catalog
failed). Bash / read / edit / codedb / attempt_completion still shipped
interactive-length essays on every `-p` turn.

## Decision

- Omit default `.medium` `reasoning_effort` when the model name is
  Gemini or contains `flash`. `/effort high` (and any explicit
  non-medium) still sends.
- Catalog `glm-5.3-flash` on codegraff (chat completions, 202752 ctx).
  Do not pass `glm-5.3` (that row is zai).
- Compact lean one-shot **descriptions** only (same names and JSON
  schemas). Do not drop to four tools. Do not steal Pi's heap.

## Consequences

- Flash SWE first-token wait is gateway TTFT, not a thinking tax.
- `/effort` remains the only way effort moves (ADR / `effort_route`:
  no auto-flip).
- Revisit if a named flash model needs default thinking — pin it in
  the catalog, do not restore a global medium default.
