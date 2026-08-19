# 0005. Standing goal lives in the prefix; user-message steering is change-only

Status: accepted 2026-08-18

## Context

#318 restates `--goal` so the model cannot forget it. The implementation
injected a long todo-coaching essay on the **user** turn, then refreshed it
every 8 turns. That is the opposite of a prompt-cache prefix: the essay
ages out of the cached head and re-enters as a suffix, paying again.

J-Space's useful rule (tiny active set, pull the rest) is the same cut
ADR 0004 applied to peer speech. The standing objective is a single fact
the prefix can hold. The essay is onboarding, not a heartbeat.

## Decision

- A one-line `[standing goal: …]` rides the system-prompt funnel
  (`pinStandingGoal`). Startup and compact re-compose for free; `/goal`
  change busts the prefix once.
- `steeringGate` still injects the long essay on first sight and on
  objective change. `refresh_turns` is 0: no timed re-paste.
- Long-horizon control beyond that is the bundled `jspace` skill, loaded
  on demand. Do not vendor a third-party suite into the resident catalog.

## Consequences

- `--goal` still reaches every request (the prefix is on every request).
- A paused or cleared goal disappears from the prefix.
- Revisit if a provider ignores the system prompt; then the essay would
  have to return as a user-turn inject.
