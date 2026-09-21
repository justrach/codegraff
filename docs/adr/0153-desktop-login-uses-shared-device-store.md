# 0153. Desktop login writes the shared device-code store

Status: accepted 2026-09-21

## Context

The desktop GUI had no login surface. ACP advertised terminal `graff-login`
only, and an unauthenticated launch told the user to run `graff login` and
restart the agent. A GUI login cannot send credentials over the agent
protocol today.

## Decision

Login with Codegraff in the GUI runs the existing device-code flow
(`POST /v1/device/start` → show URL and user code → poll `/v1/device/poll`)
and writes `~/.simple-harness-codegraff.json` with the same 0600 posture
as `graff login`. The renderer never receives the key. After approval or
logout, local ACP workers are retired so the next spawn rereads the store.
Remote agent hosts stay terminal-login only until the protocol grows a
credential channel.

## Consequences

Same-machine REPL, TUI, and GUI share one store. First-run onboarding and
the sidebar account panel are chrome only; they do not invent a second
auth path. Revisiting would need an ACP credential method.
