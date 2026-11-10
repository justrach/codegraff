# 0246. Jev picks each turn's effort, alongside the first request

Status: accepted 2026-10-03

## Context

Logged in to Codegraff, graff offers GPT-6 and MiMo v2.6 models the
`jev_effort` tool, which asks the hosted Jev selector to choose the
reasoning effort. In eval runs the models never called it: across 132 graff
runs on two models the tool was offered every time and called none. The
ChatGPT-plan sign-in, `chatgpt-new` (ADR 0229), was also not eligible, so
most ChatGPT-plan users were never offered Jev at all.

Asking Jev before a turn's first request worked but cost a call's wait,
about a third of a second in the median, on every turn.

## Decision

- `chatgpt-new` GPT-6 models are eligible for Jev, like `codex` and `openai`.
- When `GRAFF_JEV_AUTO=1` is set and a root turn starts on an eligible model at
  the untouched session default effort with a cold prompt cache, graff asks Jev
  itself, concurrently with the turn's first model request. The pick applies
  from the turn's next request, where pending selections are already applied, so
  it adds no wait.
- By default `GRAFF_JEV_AUTO` is off (`false`): on Responses, `reasoning.effort`
  is rendered into token 0 of the server's Harmony system message, so applying a
  different effort on request 2 (after request 1 warmed the prompt cache) and
  restoring the default at turn end invalidates 100% of the prompt cache
  mid-turn (#1320).
- The pick holds for that turn and is never saved. An effort the user explicitly
  chose (including `medium` via `/effort` or the ACP thought-level selector) or
  a turn that already has a warm prompt cache (`last_cache_read > 0`) is never
  overridden, an effort changed during the turn is kept, and a pick still in
  flight when the turn ends is canceled and dropped. A canceled pick does not
  open Jev's session circuit; a failed one does, as before.
- Jev sees a summary built locally from the request: its words, with code,
  paths, file names, URLs, emails, identifiers and number-heavy or long
  tokens dropped, at most 280 bytes. `GRAFF_JEV_AUTO=1` turns the per-turn
  pick on; the tool is unchanged.

## Consequences

Every eligible turn makes one gateway call; its charge is negligible. A
turn's first request always runs at the default effort, so a one-request
turn gets no benefit. On the eval tasks Jev picked the default effort every
time, so time and pass rates were unchanged. Revisit if Jev's picks start to
cost time or accuracy, or if starting the turn at the previous turn's pick
proves worth it.
