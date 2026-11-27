# 0354. nanocua's input belongs to the agent work that first uses it

Status: accepted 2026-11-27. Amends [0314](0314-nanocua-is-grafts-computer-use.md).

## Context

Input in nanocua was one app-wide Boolean (`policy.Policy.allow_input`). Once a
person turned it on, every agent connection could click and type until they
turned it off, so later work inherited what was given for earlier work, and two
agents' work shared it (#1931).

nanocua receives no turn boundary. graff's `tools/call` carries the tool name,
the model's arguments and a progress token, nothing about the turn; ADR 0313
removed the turn metadata graff once sent computer-use servers. What nanocua
does see is a connection: each graff process (a REPL session, or the one
`graff acp` behind a Harness chat) runs its own `nanocua mcp`, which opens one
socket connection to the app on its first `tools/call` and keeps it until graff
stops that server. Sub-agents call through their root's registry, so they share
its connection.

## Decision

- Turning input on (the panel's switch, or Allow on a question) opens a grant
  that nobody holds yet.
- The first connection whose acting call the policy lets through holds it. From
  then on only that connection may act. Another connection's acting call is
  refused, saying input belongs to another agent's work and what the user can do.
- When the holder's connection closes, input turns off. Later work needs a
  person to turn it on again, exactly as at launch.
- Turning input off (the panel, `nanocua ctl off input`) ends the grant at once.
  Stop is unchanged and separate: it refuses everything and leaves the grant as
  it was, so Resume does not hand input to anyone new.
- Looking (`list_apps`, `get_ui_tree`, `screenshot`) is unchanged for every
  connection (ADR 0318). The whole-screen switch is unchanged; acting with it
  still needs the input grant.
- `nanocua ctl status` adds `inputHeld`; the panel says "Input on" until a
  connection holds it and "Acting" once one does.

Nothing here turns anything on. Each rule only adds a refusal to what the
Boolean allowed, and every unclear case refuses.

## Consequences

- Input ends with the graff session's connection, not with its turn: a REPL or a
  Harness chat that took input keeps it across turns until graff exits, its
  `nanocua` server is reconnected, the app quits, or the user turns it off. A
  true turn boundary needs graff to send one, such as a host-set turn id in each
  `tools/call`'s `_meta` that nanocua binds the grant to (an absent id refused
  once a grant carries one). That is host metadata for one server, which ADR
  0313 removed, so it needs its own record.
- Two agents can no longer act at the same time. The second is told to wait; the
  user hands input over by turning it off and on.
- A `nanocua` server the user configures with `"shared": true` puts every
  session behind one connection, so they would share one grant. graff's own
  entry is not shared.
- The grant lives in the app's memory. Quitting the app ends it, and input is
  off at the next launch, as before.
