# 0311. Claude Agent refreshes tools in place; a finished task still hears addressed mail

Status: accepted 2026-11-02

## Context

Two defects came out of one test: a finished worker owns a task, and three
follow-ups for it arrive as peer mail while five unrelated room lines arrive
around them.

**Claude Agent dropped the call that loaded a tool.** When graff's tool list
changed (usually `load_tool_schemas`, loading `peer_message`), the next step
removed graff's SDK MCP server from Claude Code and added it back
(`mcp_set_servers {}` then `{graff}`), so Claude Code would re-read
`tools/list`. The `load_tool_schemas` call was still held at that moment.
Removing the server failed it with "Connection closed", and the model often
ended its turn on that error. In other turns the model went on to call the
tool and got "No such tool available". Against real Claude Code 2.1.304, a
held call failed on every reset. With `notifications/tools/list_changed`
sent instead, Claude Code re-read the list and the model called the new tool
in the same turn.

**Whether a follow-up woke the worker depended on how its last turn ended.**
Commit a53242d4 (#1137) made a final answer settle the task: room mail
stays parked for the next human prompt, and only mail addressed to the
session starts a turn. `attempt_completion` kept an older, stricter latch
that blocked addressed mail too. A model that ends its turns with
`attempt_completion` never heard a follow-up sent straight to it; a model
that ends with a plain answer did.

## Decision

- The claude-agent transport refreshes a changed tool list by sending
  Claude Code an MCP `notifications/tools/list_changed` for graff's server (a
  client-to-CLI `mcp_message`), then serving the `tools/list` it sends back
  before anything else. The server stays connected, so held calls stay open.
  graff's MCP `initialize` result declares `tools.listChanged`. If Claude Code
  does not re-read the list within 15 seconds, graff starts a fresh session,
  which reads the list at start.
- The results sent after a refresh carry one line telling the model that
  graff's tools are named `mcp__graff__<name>`. `load_tool_schemas` prints
  schemas under graff's own names, and the model's first call to a tool it
  had just loaded used that bare name, which Claude Code rejects ("No such
  tool available"); the turn went on, but that call was wasted.
- A turn started by a peer wake ("peer_message action=inbox") preloads
  `peer_message` with its first request, as a request naming subagents
  preloads `subagent` (ADR 0231). Without it the woken turn's first call was
  to the unloaded tool; on Claude Agent, Claude Code refuses that call itself,
  so graff never answered it, and the transcript mismatch forced a fresh
  session.
- `attempt_completion` settles the task exactly as a final answer does:
  room mail stays parked and readable until the next human prompt, and mail
  addressed to this session (a DM, or the user's own `/tell`) can start a
  turn. `yield_turn` keeps its strict latch: it waits on the person.

## Consequences

Loading a tool on Claude Agent no longer costs the turn or a fresh process.
A peer can hand a finished worker a follow-up by addressing it, whatever the
model ended with; unaddressed room chatter still never wakes it. Revisit the
second rule if addressed mail is used to spam finished workers.
