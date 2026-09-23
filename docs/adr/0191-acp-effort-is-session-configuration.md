# 0191. ACP effort is session configuration

Status: accepted 2026-09-23

## Context

ACP clients need a standard way to show and change the active thought level. A
slash command alone is invisible to generic clients, and a picker must not
offer effort values the current model rejects.

## Decision

`session/new` and `session/load` return a `thought_level` select option derived
from the active model's effort allowlist. `session/set_config_option` validates
the session, option and value, then changes the same state as `/effort` and
returns the complete option list. Agent-originated `/effort` or `/model`
changes publish a complete `config_option_update` when the option state
changes. A setter received during a prompt stays in the ordinary request queue
and applies to the next turn; it does not steer or cancel the running prompt.

## Consequences

Generic ACP clients and existing slash-command clients share one effort state.
An explicit selection can change the next model request's cached prefix, while
the active request remains stable. Models without effort support expose no
thought-level option.
