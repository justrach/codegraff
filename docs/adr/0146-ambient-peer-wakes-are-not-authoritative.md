# 0146. Ambient peer wakes are not task-authoritative; daddy directives are

Status: accepted 2026-09-21

## Context

ADR 0004 parks peer bodies and injects a one-line `[peer]` wake. That wake
was still a user-role history line, appended at every root step — including
tool-result continuation and immediately after `attempt_completion`. Ambient
coordination then became the newest instruction and could restart a finished
turn (#1137).

A supervisor ("daddy") agent on the GUI Agent tab needs the opposite: an
explicit directive that *may* steer or wake a named sibling.

## Decision

- Ambient mailbox wakes coalesce by generation, never inject during tool
  continuation, and never start an idle turn after `attempt_completion` until
  a later human prompt. `action=inbox` retires the stale `[peer]` lines.
- A `[daddy]` directive (`peer_message action=direct` / `/daddy`) is named
  control. An idle root may start a turn on it even after completion. The GUI
  Agent tab sends the same prefix into the target conversation.
- Children in one process stay on `agent_message`. Daddy is the
  cross-session path. Surface chrome differs; the engine path is shared by
  REPL, TUI, and `graff acp`.

## Consequences

Parked ambient mail remains readable on the next human turn. Completing a
task no longer reopens on a greeting. Revisit if a structured control
channel replaces the prefixed DM.
