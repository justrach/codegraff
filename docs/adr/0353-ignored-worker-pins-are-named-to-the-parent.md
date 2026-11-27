# 0353. Ignored worker pins are named to the parent

Status: accepted 2026-11-27

## Context

A `subagent` call may pin `model` or `tier` (#292). A pin that cannot be
honoured is soft by design: the child still runs, on the seat it would have
had, and `Outcome.describe` wrote the reason to the trace. Nothing reached the
tool result. A parent that asked for a stronger worker got the cheapest ladder
rung and learned it only by asking the child, then spent calls guessing why.
The trace note also said "kept the session default" when the seat was the
ladder's.

The commonest cause was spelling. `modelForProvider` and `/model` normalise
`-`, `_` and spaces away but keep `.`, so "opus 5.5" (`opus5.5`) never met
`claude-opus-5-5` (`claudeopus55`), while the same family written
`claude-opus-5-5` resolved.

## Decision

- An ignored pin stays soft, but every tool result the parent receives for
  that child starts with one bracketed line: the pin, why it was ignored, the
  model that actually ran, and how to get what was asked (for a name, at most
  six exact catalogue ids it could mean). The foreground result, the
  background report and `agent_output` start with it; the background receipt
  carries it on the line under `[agent N started: …]`, which SDKs parse.
  The trace note is the same line. Both REPL and ACP go through
  `execSubagent`, so both get it.
- When exact, alias and substring matching find nothing at all, a model name
  is tried once more with `.` also ignored and a leading provider id dropped.
  Spawn pins, `--subagent-model`, `/model` and `--model` share this last
  resort, so they agree on what "opus 5.5" means.
- An ambiguous name still resolves to nothing. The last resort only runs on
  zero matches, and it too requires a unique row. The candidate list is how
  the parent recovers.
- The spawn's `route` trace and trajectory lines record `requested_model`,
  `requested_tier` and the pin outcome beside `resolved_model`. The `--json`
  `agent_route` event is unchanged.

## Consequences

`normalizeModelAlias` is untouched, because it also keys price, context and
alias-equality lookups. `looseModelKey` is consulted only after everything
else misses, so nothing that resolved before resolves differently. Tests:
`src/subagent_pin_note_tests.zig`, the pin cases in
`src/http_client_trajectory_tests.zig`, and Tier 2
`subagent-ignored-model-pin-is-named`.
