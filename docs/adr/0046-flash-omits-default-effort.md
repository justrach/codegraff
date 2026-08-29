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

- Flash / Gemini default `.medium` is sent as **`low`**, not omitted.
  Omitting the field still bills `reasoning_tokens` (27 on a `pong`;
  SWE dumps 1.9MB `reasoning_content`). `low` bills 0. `none` is a
  400. `/effort high` still sends high.
- Catalog `glm-5.3-flash` on codegraff (chat completions, 202752 ctx).
  Do not pass `glm-5.3` (that row is zai).
- Compact lean one-shot **descriptions** only (same names and JSON
  schemas). Do not drop to four tools. Do not steal Pi's heap.
- Root `-p` uses the streaming transport (`usesLiveTransport` = `!sub`).
  `out=null` / `stream_quiet` mute paint only. The 5-minute
  `postWatched` deadline is for subagents, not one-shots.

## Consequences

- Flash SWE wall is generation without thinking novels, not Zig vs JS.
- `/effort` remains the only way effort moves (ADR / `effort_route`:
  no auto-flip).
- `-p` writes `calling <model>` to stderr at start and drops the
  call-2 stdout pulse. Eval `first_out` is no longer "time to model
  call 2"; stdout stays the answer.
- Revisit if a named flash model needs default thinking — pin it in
  the catalog, do not restore a global medium default.

## Confirm (2026-08-29, after this revision)

`run-20260829-041235.jsonl`, Codegraff `glm-5.3-flash`, `--suite swe
-j 6`. No `reasoning_effort` on the wire. Local boot is 7ms; a
`pong` one-shot is 6.1s / 10 out (gateway TTFT). Pi `first` 0.6s is
still the JSONL `session` line.

| | pass | wall | first | out |
|---|---:|---:|---:|---:|
| ADR 0045 | 3/6 | 1353s | 6.9s | 15k |
| after (thinking off) | 3/6 | 1247s | 6.7s* | 21k |

\*first was the call-2 stdout pulse. `validated` 164s / 46k / 10 →
**57s / 11k / 4**. `json-stream` and `cookie-store` still SIGKILL at
300s after that pulse: the second model call took `postWatched`
(~250s of silence, then `retry` / 5xx) because `-p` gated `live` on
`out != null && !stream_quiet`. Root one-shots now `postLive` so the
30s head-stall fires. `label-sort` finished (174s) but still fails
the hidden check. Do not steal Pi's heap.

## Confirm (2026-08-29, after streaming `-p`)

`run-20260829-043927.jsonl`, Codegraff `glm-5.3-flash`, `--suite swe
-j 6`. Root one-shots `postLive`. Eval `first` is the stderr `calling`
line (~0.03s), not gateway TTFT.

| | pass | wall | notes |
|---|---:|---:|---|
| ADR 0045 | 3/6 | 1353s | thinking on; 3× 300s `postWatched` |
| thinking off | 3/6 | 1247s | still `postWatched` |
| **this cut** | **4/6** | **1311s** | 26 calls / 157k in / 29k out |

`json-stream` **passed** in 280s (was SIGKILL at 300s after a silent
second `postWatched`). `validated` 106s / 6 calls. `map-conflict`
116s. `config-parse` 208s.

`cookie-store` still SIGKILL at 300s: call 2 traced `first_token` at
11.5s then never completed — a live stream, not the 5-minute watched
POST. `label-sort` was mid-turn (call 2 was 219s / 1.9MB SSE) when
the cap hit. Do not steal Pi's heap. Do not shrink the keep-list.

## Confirm (2026-08-29, `reasoning_effort=low`)

`run-20260829-045547.jsonl`. Gateway A/B: omit = 27 reasoning_tokens
on `pong`; `low` = 0; `thinking.disabled` still thinks; `none` is 400.

| | pass | wall (sum) | out | calls |
|---|---:|---:|---:|---:|
| Pi (ADR 0045) | 5/6 | 758s | 27k | 35 |
| graff omit | 4/6 | 1311s | 29k | 26 |
| **graff `low`** | **5/6** | **286s** | **4.7k** | 38 |

Same miss as Pi (`label-sort` hidden check). `cookie-store` 115s
(was 300s SIGKILL; Pi 301s). `json-stream` 36s (was 280s; Pi 117s).
Do not steal Pi's heap. Do not shrink the keep-list.
