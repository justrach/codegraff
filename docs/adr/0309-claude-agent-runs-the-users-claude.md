# 0309. Claude Agent runs the user's own `claude`

Status: accepted 2026-10-31

## Context

ADR 0281 signs in to an Anthropic Console account (API credits) and ADR 0288
added a native subscription PKCE login; ADR 0288 left room for "a separate
Claude CLI transport" that a user selects explicitly. The Agent SDK route is
that transport: a host application runs the user's installed `claude`
program through the SDK's control protocol, the user signs in with
`claude auth login`, and the host never reads Claude Code's credentials or
sits between Claude Code and Anthropic. The SDK's branding rules allow
"Claude Agent" as the product name and do not allow "Claude Code".

The SDK itself is a TypeScript/Python library; graff is Zig. Its protocol is
plain newline-delimited JSON over the child's stdio, verified against
`claude` 2.1.304:

- `--input-format stream-json --output-format stream-json
  --include-partial-messages` streams the raw Anthropic Messages events
  (`stream_event.event`), the same events graff's HTTP transport parses.
- One `initialize` control request carries the host's in-process MCP servers
  (`sdkMcpServers`) and a system prompt (`systemPrompt` replaces Claude
  Code's, `appendSystemPrompt` extends it). A replaced prompt works on a
  subscription login.
- MCP JSON-RPC is tunnelled through `mcp_message` control requests. Every
  `tools/call` carries the model's tool_use id in
  `_meta["claudecode/toolUseId"]`.
- `mcp_set_servers` removes and re-adds an SDK server, after which Claude
  Code initializes it again and re-reads `tools/list`; `mcp_reconnect`
  refuses SDK servers.
- `client_composed: true` on a user message stops Claude Code from reading
  the text as its own commands or adding its per-turn context (2.1.248+).

## Decision

`claude-agent` is a provider (`.kind = .anthropic`, login `claude_cli`). It
is seated only after `graff login claude-agent` (which runs
`claude auth status`, then `claude auth login` if needed, and writes a
marker naming the binary) or `GRAFF_CLAUDE_AGENT=1`. Once chosen it is the Claude plan: its catalog lists
the models Claude Code's aliases resolve to under their real names
(`claude-opus-5-5`, `claude-fable-5-1`, `claude-sonnet-5-5`,
`claude-haiku-5-5`, and the 5.0 models it still offers), and those names
route to Claude Agent ahead of the `anthropic` provider, the way the ChatGPT
plan's sign-in outranks the Codex login. `anthropic/<model>` still reaches
the API route; `claude-agent/<id>` passes any id Claude Code accepts; the
first `claude-agent-<alias>` names keep working.

`Agent.postLive` routes the provider to `claude_agent.zig`, which returns an
Anthropic SSE body, so `assembleAnthropic`, `stepAnthropic`, `runTools`,
approvals, sinks, ACP, usage and compaction run unchanged:

- One long-running child per graff agent, started with Claude Code's
  built-in tools, settings files, hooks, CLAUDE.md, memory, auto-compaction,
  tool search and advisor off, `dontAsk` permissions, `mcp__graff__*` as the
  only allowed tools, and no saved session. The inherited identity of an
  enclosing Claude Code session (CLAUDECODE, the entrypoint, its messaging
  socket) is removed from the child's environment; the user's own settings
  (CLAUDE_CONFIG_DIR, CLAUDE_CODE_OAUTH_TOKEN, cloud switches) pass through.
- graff's tools are served as the `graff` SDK server. A `tools/call` is
  held: the step ends at the response's `tool_use` stop, graff runs the
  calls (in parallel where its own batching allows), and the next step
  answers each held call by its tool_use id. Results for calls Claude Code
  has not asked for yet are kept until it does.
- graff's history is the source of truth. Each request sends only messages
  the child has not seen; a fresh child (first use, a changed model, effort,
  prompt or folder, a compaction or edit, five idle minutes) gets everything
  it missed as one `<conversation-checkpoint>` user message, without
  thinking text. A changed tool list refreshes the server in place.
- Titles, recaps, judges and compaction summaries run on a throwaway child.
- graff's system prompt replaces Claude Code's by default;
  `GRAFF_CLAUDE_AGENT_PROMPT=claude` keeps Claude Code's and appends graff's.
- Usage is Claude Code's per-response counts; billing is the flat-rate plan.
- `rlm`'s nested `llm_query` reports that it is unavailable (no endpoint).

## Measurements

graff-evals core + rlm + swe (22 tasks; `bind-reuse` left out because it asks
for graff's own `rlm` tool), Sonnet on one subscription login, two
interleaved reps, global MCP off on both sides, `claude -p` with no user
settings, hooks, plugins or CLAUDE.md (`claude-code-clean`):

| arm | pass | wall | median/task | prompt tokens | output tokens |
|---|---|---|---|---|---|
| `claude -p` | 44/44 | 428 s | 8.2 s | 2.19M | 29.0k |
| claude-agent, Claude Code prompt + graff's | 44/44 | 362 s | 6.3 s | 1.06M | 26.2k |
| claude-agent, graff's prompt | 44/44 | 360 s | 6.3 s | 0.85M | 26.5k |

Paired by task and rep, graff's prompt was faster in 33 of 44 runs (median
1.3 s). Calls per task were the same; the difference is request size:
Claude Code's own prompt and tool definitions are about twice graff's, which
is why graff's prompt is the default. A plan's limits count these tokens.

## Consequences

- Claude Code makes the API calls, so graff's Claude request shaping (cache
  breakpoints, effort routing beyond `--effort`, retries and the stall
  ladder, request headers) does not apply; Claude Code retries by itself and
  a failure it reports ends the turn as a readable reply.
- It works only where `claude` is installed and signed in on the same
  machine. Hosted or remote sessions cannot use it.
- An imported conversation still continues on graff's configured provider;
  this provider is never chosen implicitly for one.
- Revisit if the protocol drops `_meta["claudecode/toolUseId"]` (calls would
  then need a PreToolUse hook to learn their id and run one at a time) or
  `client_composed`.
