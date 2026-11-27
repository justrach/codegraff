# 0352. A Claude Agent session waiting on graff's tool is not idle

Status: accepted 2026-11-27

## Context

ADR 0309 holds one `claude` child per graff agent and stops it after five
idle minutes; the next request starts a fresh child and replays graff's
history as one `<conversation-checkpoint>` message. Idle was measured from
the end of the last model step (`Session.used_ms`) and checked twice: when
the agent's next request takes the session (`staleBecause`), and when any
other agent returns its session (`session.put` sweeps the map).

A step that stops for graff's tool calls is not the end of the child's turn.
Claude Code is still inside that turn, waiting for graff to answer the
`tools/call` it issues (usually read only on the next request, so
`Session.pending` is often still empty when the session is put back). While a
long build or test runs in the shell tool, a foreground subagent works, or
`ask_user` waits for the user, five minutes pass with the child busy, and
both checks threw it away. The fresh child lost the thinking text the
checkpoint leaves out, rewrote the whole prompt cache, and started later. A
parent blocked on its subagent was also stopped by the subagent's own `put`
sweep, so it started cold with no restart note.

## Decision

- A session is **busy** when its last step stopped for a graff tool call
  (`Session.awaiting`), or when Claude Code has a `tools/call` graff has not
  answered (`Session.pending`). Results graff holds for calls not asked for
  yet (`Session.results`) do not make it busy: they outlive a turn Claude
  Code ended by itself.
- One pure rule, `claude_agent_session.reapAt(now, used_ms, busy)`, decides
  for both the request-time check and the sweep. A session with nothing in
  flight is stopped past `idle_ms` (five minutes), exactly as before, and
  restarts with the note `restart: idle past 5 minutes`. A busy session is
  kept until `busy_ms` (one hour), then stopped the same way, noted
  `restart: tool call open past 60 minutes`.
- `busy_ms` is the leak guard for a session whose owner is gone (a
  subagent cancelled or torn down mid-tool, an abandoned turn). There is no
  teardown hook: agents are stack values built in many places, and a
  retained worker is rebuilt per run with its history restored, so an
  owner's address is not a reliable "gone" signal.

## Consequences

- A tool or a question to the user that runs under an hour keeps the child,
  its reasoning and its cache. Past an hour the prompt cache has most likely
  expired anyway, so the restart costs less than it would have earlier.
- A graff turn that ends on a tool call (`attempt_completion`, `ask_user`)
  leaves Claude Code waiting on that call, so its child is busy too and is
  kept up to an hour while the user is away; the next prompt rides with the
  call's result. A child left that way holds its process for the hour.
- A cancelled subagent's child can stay up to an hour after its owner is
  gone, until another session's `put` or graff's exit (`stopAll`) stops it.
  Revisit with an explicit stop on agent teardown if those accumulate.
