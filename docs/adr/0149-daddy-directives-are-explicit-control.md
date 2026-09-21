# 0149. Daddy directives are explicit supervisor control

Status: accepted 2026-09-21

## Context

ADR 0147 already parks ambient `[peer]` wakes: they are not a new task, do
not inject during tool continuation, and do not idle-wake after
`attempt_completion`. A supervisor ("daddy") agent on the GUI Agent tab
needs the opposite: an explicit directive that *may* steer or wake a named
sibling.

## Decision

- A `[daddy]` directive (`peer_message action=direct` / `/daddy`) is named
  control. An idle root may start a turn on it even after completion. The GUI
  Agent tab sends the same prefix into the target conversation.
- Children in one process stay on `agent_message`. Daddy is the
  cross-session path. Surface chrome differs; the engine path is shared by
  REPL, TUI, and `graff acp`.

## Consequences

Ambient mail stays on ADR 0147. Completing a task no longer reopens on a
greeting, but a named `[daddy]` line can. Revisit if a structured control
channel replaces the prefixed DM.
