# Architecture

`simple-harness` is a terminal agentic loop built with Zig 0.17 dev and one
vendored TUI dependency. It talks to
two LLM providers, runs tools (including subagents and MCP servers) in
parallel, and compacts its own context. This document explains how the
pieces fit together.

```
                         ┌──────────── REPL (main) ────────────┐
   stdin ──line──▶       │  read line / slash command          │
                         │  append user msg → Agent.runTurn    │
                         └──────────────┬──────────────────────┘
                                        │
                ┌───────────────────────▼────────────────────────┐
                │                  Agent.runTurn                  │
                │  buildBody → POST → step{Anthropic,OpenAI}      │
                │            ▲                     │              │
                │            │   loop until        ▼              │
                │            │   no tool calls   runTools         │
                │            └─────────────────────┤             │
                └──────────────────────────────────┼─────────────┘
                                                    │
                  ┌──────────────── runTools ───────┴───────────┐
                  │  meta tools  ──── handled inline (state)    │
                  │  everything else ── io.async fan-out ──┐    │
                  └────────────────────────────────────────┼────┘
                                                           │
              ┌──────────────┬──────────────┬─────────────┴────────┐
              ▼              ▼              ▼                      ▼
            bash         read/write     subagent              mcp.Registry
        std.process    Io.Dir.cwd    (Agent.runTurn,          JSON-RPC 2.0
                                      one level deep)          over stdio
```

## Files

| File | Role |
|------|------|
| `src/main.zig` | The whole agent: provider routing, the turn loop, both wire formats, tools, subagents, compaction, the REPL and slash commands. |
| `src/mcp.zig` | MCP client: spawns stdio servers from `.mcp.json`, JSON-RPC handshake, tool discovery, tool dispatch. |
| `build.zig` | Single executable target; `zig build run`. |

Everything is one binary. The std HTTP client brings its own TLS, so there is
no libcurl/openssl link step; the result is a self-contained executable that
compiles in well under a second.

## Core abstraction: `Agent`

A single `Agent` struct is the unit of execution. It owns a message history
(`std.json.Array`), a provider, an arena for that history's lifetime, and the
loop methods. **The root REPL agent and every subagent are the same type** —
a subagent is just an `Agent` with `sub = true`, a fresh arena, an empty
history, and `out = null` (so it logs to stderr instead of stdout).

`runTurn` is the loop:

1. `buildBody` serializes the request for the current provider.
2. `post` sends it (thread-safe `std.http.Client.fetch`).
3. `stepAnthropic` / `stepOpenAI` parse the response, echo the assistant
   turn into history verbatim, collect tool calls, dispatch them, append the
   results, and return either the final text (turn done) or null (loop).

## Providers

Two axes, decoupled: a **wire format** (`Provider.Kind` — `anthropic` vs
`openai`) and an **auth style** (`Provider.Auth` — `x_api_key` vs `bearer`),
so e.g. minimax serves the Anthropic Messages format with bearer auth. The
`provider_specs` table (endpoint, kind, auth, env var, default model — values
from models.dev/api.json) is the single source of truth; `post()` picks the
header by `auth` and adds `anthropic-version` whenever `kind == .anthropic`.

`Keys` holds one optional key per spec. `Keys.providerFor(model)` walks
`model_table` (provider-tagged rows) and picks the first row whose provider
has a key; unknown `claude*` → anthropic, other unknowns → codegraff.
`defaultProvider()` is the first key-bearing spec on its default model.
`Provider.context` (from `contextFor`) drives `compactAt()` = 80% of the
window, so compaction is per-provider-per-model.

| Provider | Kind | Auth | Key env |
|---|---|---|---|
| anthropic | anthropic | x-api-key | `ANTHROPIC_API_KEY` |
| codegraff | openai | bearer | `CODEGRAFF_API_KEY` |
| deepseek | openai | bearer | `DEEPSEEK_API_KEY` |
| openai | openai | bearer | `OPENAI_API_KEY` |
| minimax | anthropic | bearer | `MINIMAX_API_KEY` |
| xiaomi | openai | bearer | `XIAOMI_API_KEY` |
| codex | responses | bearer | `~/.codex/auth.json` (ChatGPT OAuth) |
| claude | anthropic | bearer | Claude Code OAuth (`~/.claude/.credentials.json` or macOS keychain) |

`Provider.Kind` has a third variant, `responses` — the OpenAI **Responses
API** as served by the ChatGPT backend (Codex login). `loadCodexAuth` reads
the access token + account id from `~/.codex/auth.json` at startup and injects
them into the codex key slot (its `env_key` is a non-existent var, so env
never populates it). `post()` adds the `chatgpt-account-id`, `OpenAI-Beta`,
`originator`, and `session_id` headers for that kind. `buildBody` emits the
Responses shape (`instructions` + `input` items + flat function `tools` +
`stream:true`); since the backend only streams, `request()` buffers the SSE
and `parseResponses` collects the `response.output_item.done` items into a
synthetic `{output, usage}` object that `stepResponses` consumes — appending
message/function_call/reasoning items verbatim (they're valid next-turn input)
and emitting `function_call_output` items for tool results.

The `claude` provider is the **subscription-login** analogue of codex, on the
Anthropic side: same `anthropic` wire format as the `anthropic` provider, but
it authenticates with the Claude Code subscription instead of an API key.
`loadClaudeAuth` reads the `sk-ant-oat…` OAuth access token from Claude Code's
credentials at startup — `~/.claude/.credentials.json` on Linux, or the macOS
login keychain (service `Claude Code-credentials`, read by spawning the
`security` CLI) — and injects it into the `claude` key slot (its `env_key` is a
non-existent var). Two extra requirements gate that token to the official
client, both satisfied for this provider: `providerHeaders` adds
`anthropic-beta: oauth-2025-04-20`, and `buildBody` sends `system` as an array
of text blocks whose **first** block is exactly the Claude Code identity line,
with the harness's real prompt as a second (cache-broken) block. Routing places
`claude` late in `provider_specs`, so a real `ANTHROPIC_API_KEY` always wins for
the same model name; the subscription is the fallback. The token is read, never
refreshed — on a 401 after expiry, run `claude` once to refresh it (same caveat
as codex).

### Streaming

Agent requests stream on **all three** wire formats, root and subagent alike
(`Agent.usesLiveTransport`, #682). `-p`, compaction and subagents set
`out=null` / `stream_quiet` to mute paint, not to leave the stall-watched
path; the buffered `postWatched()` path serves only the remaining
non-turn callers (compaction summary, rlm queries). When live,
`buildBody` adds `stream:true` (openai also gets
`stream_options:{include_usage:true}` so token counts survive — dropped and
retried once if a provider rejects it, same pattern as the soft-strict
`tool_choice` retry) and `postStream()` issues the request with the low-level
`std.http.Client.request` API, pumping the body line-by-line via
`Reader.streamDelimiterEnding`. Each SSE line is teed: appended to the full
body buffer, and `printDelta` prints the text delta for the active format
(`content_block_delta`/`text_delta`, `choices[0].delta.content`, or
`response.output_text.delta`) immediately. Afterwards the buffered events are
reassembled into the exact non-streaming response shape — `assembleAnthropic`
(accumulates per-index content blocks incl. thinking/signature and
`partial_json` tool inputs, merges `message_start`/`message_delta` usage),
`assembleOpenAI` (joins content deltas, merges `tool_calls` fragments by
index, picks up the final usage chunk), and the pre-existing `parseResponses`
for codex — so `step*`, history echo, compaction, and `/save`/`/resume` are
untouched. A non-SSE body (error envelope, or a provider that ignores
`stream`) produces no deltas and falls through to the regular JSON parse.
`streamed_text` tells `step*` not to re-print text that already streamed.

The two formats differ in three places, all isolated to `buildBody` and the
two `step*` functions:

- **Request shape** — Anthropic has top-level `system`/`tools` and adaptive
  `thinking`; OpenAI carries the system prompt as the first `messages` entry.
- **Tool-call encoding** — Anthropic emits `tool_use` content blocks with a
  parsed `input` object; OpenAI emits `tool_calls` whose `arguments` is a
  *stringified* JSON blob that we parse before dispatch.
- **Tool-result encoding** — Anthropic wants `tool_result` blocks in a user
  turn; OpenAI wants one `role:"tool"` message per call.

Both are normalized to a single internal `ToolCall { id, name, input }` so the
tool executors are provider-agnostic. `/model <name>` switches providers
mid-session (it clears history, since the stored turn shapes differ).

## Tools

Three kinds, all dispatched through `runTools`:

1. **Built-in** (`bash`, `read_file`, `edit_file`, `write_file`,
   `subagent`, `workflow`) — run on the `std.Io` thread pool. `workflow` is
   dynamic workflows as data (the pi-dynamic-workflows idea without a JS
   sandbox): sequential phases of parallel subagents, `{{prev}}`
   substitution carrying results between phases, final phase returned. `edit_file` is an exact
   string replace (`std.mem.count` + `std.mem.replace`): the `old_string`
   must match exactly once unless `replace_all` is set, which keeps the
   model honest about what it's changing.
2. **Meta** (`todo_write`, `todo_read`, `attempt_completion`) — act on the
   agent's *own* state or conversation flow, so they're handled inline by the
   orchestrator (`handleMeta`), never on a pool thread. `todo_write`/
   `todo_read` mutate the task list; `attempt_completion` carries the final
   answer out; `ask_user` carries a human reply *in* (see below). The key
   distinction: a meta tool acts on the agent/conversation; an external tool
   touches the outside world.
3. **MCP** — discovered at runtime from `.mcp.json`, namespaced
   `mcp__<server>__<tool>`, dispatched to `mcp.Registry.call`.

Tool definitions for the built-ins are comptime `ToolSpec` records rendered
into both wire formats. For subagents the lists are fully comptime constants;
for the root agent they're built once at startup by `renderRootTools`, which
merges the built-in specs with the discovered MCP tool schemas.

### Permission gate

State-changing tools run behind a gate backed by one shared `Approvals` struct
(an `Io.Mutex`, a list of approved keys, and a `yolo` flag):

- **`gateTool`** (root only, called from `runTools` before dispatch) covers
  `bash`, `write_file`, `edit_file`, and MCP tool calls. An unapproved call
  prompts on stdin — yes once / always / no. The approval key is the bash
  command's first word, or the tool name for writes and MCP. A denial becomes
  the tool result so the model adapts. `read_file`, `subagent`, `workflow`,
  and meta tools are not gated.
- **Approval matching**: `allowed()` does prefix-matching for bash (against the
  seed list + approved words); `allowedExact()` does exact-name matching for
  writes/MCP. Both short-circuit under `yolo`.
- **Subagents** run on pool threads with no stdin, so they're gated
  structurally in `execToolInner`: bash is allowlist-only (unapproved →
  denied), file writes are allowed but path-confined, and MCP isn't exposed.
- **Seed allowlist**: read-only basics (`ls`, `cat`, `rg`, …), `zig build`/
  `zig fmt`, `git status`/`diff`/`log`/`show` never prompt. `find` is
  excluded — `-exec`/`-delete` make it an exec tool, not read-only.
- **Metacharacter rule** (`isSimple`): commands containing `;`, `|`, `&`,
  `>`, `<`, `$`, backticks, **or newline/CR/tab/null** never match a prefix —
  chaining (including `sh -c "ls\nrm"`) can smuggle a second command — so they
  always prompt at root and are denied in subagents.
- **Interpreter heads-up**: approving `python3`/`node`/`bash`/… as a bash word
  (`isInterpreter`) prints a note that it grants arbitrary code execution.
- **Path confinement** (`confinedPath`): `read_file`/`write_file`/`edit_file`
  reject absolute paths and any `..` component, confining them to the cwd
  subtree. Enforced in `execToolInner` for root *and* subagents, and **not**
  bypassed by `/yolo` (it's structural, not a trust setting).
- **bash cwd-lock** (`escapesCwd`): a seed/approved command auto-runs only if
  every whitespace-token path argument stays in the cwd (no leading `/` or
  `~`, no `=/`/`=~`, no `..` component). `cat /etc/passwd` therefore isn't
  auto-allowed — it prompts at root (per-call `y` still works) and is denied
  for subagents. A heuristic, but `isSimple` has already excluded the
  metacharacters that would let args hide.

`/yolo` lifts the prompt gate **and** the bash cwd-lock (`allowed()` returns
true under yolo before `escapesCwd` is consulted). The one thing `/yolo` never
lifts is `confinedPath` on the file tools — that's a structural invariant, not
a trust toggle.

### Parallelism

`runTools` separates meta calls (inline) from external calls, then fans the
external ones out with `io.async` — one `Future` per call — and awaits them
in order. Because subagents are themselves external tool calls, three
subagents requested in one assistant message become three `Agent.runTurn`
loops running concurrently on the pool, each making its own HTTPS calls
through the shared client. The concurrency primitive is Zig 0.17's structured
`std.Io`: no async runtime, no manual thread management — `io.async(fn, args)`
returns a typed `Future` executed on `std.Io.Threaded`.

## Subagents

`execSubagent` builds a fresh `Agent` (own arena, empty history, the parent's
provider and client), seeds it with the task prompt, and runs it to
completion. Its final text is returned verbatim as the tool result. Depth is
capped at one level: subagents get only the base tool set (no `subagent`, no
MCP, no meta tools), and `from_sub` rejects nested spawns. Subagents don't
share the parent's context — the orchestrator must put everything needed into
the prompt, which the tool description states.

## "Every message is a tool" — strict mode and `ask_user`

The loop is symmetric: both directions of the human↔agent conversation can
flow through the tool channel.

**Agent → human.** The final answer comes through the `attempt_completion`
meta tool; its `result` is printed and ends the turn.

**Human → agent.** The `ask_user` meta tool is the inverse. The agent calls
it with a `question` (and optional `options`); the orchestrator prints it,
blocks on stdin, and hands the typed reply back as the tool's *result* — so
the human turn arrives as a tool result, not a fresh top-level user message.
The human is, in effect, just another tool the agent can call. Only the root
agent has stdin (`Agent.in`); a subagent calling `ask_user` gets an error
telling it to make an assumption.

**Strict mode** (`/strict`) closes the loop: `tool_choice` is forced
(`{"type":"any"}` for Anthropic, `"required"` for OpenAI), so the model must
call a tool every turn — free text never ends a turn. Combined with
`ask_user` and `attempt_completion`, *every* message in the conversation is a
tool call or a tool result.

Provider wrinkles, all handled by the same soft-retry idiom in `request()`
(detect the rejection in the error message, flip a flag, retry once):
- On Anthropic, forced `tool_choice` conflicts with adaptive thinking, so
  `buildBody` drops the `thinking` field while forcing.
- The codegraff gateway (deepseek with thinking on) rejects a forced
  `tool_choice` outright. `request` retries once without forcing, falling
  back to "soft strict" — the strict system prompt still drives the
  discipline even where the hard constraint isn't allowed.
- A provider that rejects `stream_options` gets a retry without it (losing
  streamed usage counts, nothing else).
- A provider that rejects `max_tokens` ("use `max_completion_tokens`" — the
  gateway proxying gpt-5.x does this) flips the per-provider `cap_new` flag
  and retries with the post-deprecation name. This mirrors graff's
  `MakeOpenAiCompat` transformer; like graff, the direct `openai` provider
  gets `max_completion_tokens` unconditionally. `/model` and `/resume` reset
  the flag since it's provider-specific.

It's the Cline/Roo pattern (`ask_followup_question` + `attempt_completion`);
codegraff uses a similar discipline with `plan_create` and completion-style
tools.

## MCP client (`mcp.zig`)

The harness is an MCP **client**. `Registry.init` reads `.mcp.json`
(`{"mcpServers": {"name": {"command", "args", "env"}}}`), and for each server:

1. `std.process.spawn` with `stdin = .pipe`, `stdout = .pipe`,
   `stderr = .ignore` (so server logs stay off the JSON channel).
2. Speaks newline-delimited **JSON-RPC 2.0** over the pipes — the MCP stdio
   transport. Pipes aren't seekable, so it uses `writerStreaming` /
   `readerStreaming`.
3. Handshake: `initialize` → `notifications/initialized` → `tools/list`.
4. Registers each discovered tool, namespaced `mcp__<server>__<tool>`, with
   its `inputSchema` preserved for the model — after one sanitization pass:
   `rewriteOneOf` recursively renames the JSON Schema keyword `oneOf` to
   `anyOf` (graff's `rewrite_one_of_to_any_of`), because OpenAI's tool-schema
   validator — including `chatgpt.com/codex/responses` — rejects `oneOf`
   outright, and one bad tool schema fails the *whole* request. `anyOf` is
   accepted everywhere and equivalent for the discriminated unions MCP
   servers emit in practice. Runs once at discovery, so the rendered tools
   JSON stays KV-cache-stable.

`Registry.call` serializes `tools/call` requests behind an `Io.Mutex` (a
server is one bidirectional pipe; concurrent calls would interleave) and
flattens the result's `content` text blocks. The `request` helper skips
interleaved notifications until the response id matches.

This is the same protocol codedb speaks as a *server* — pointing `.mcp.json`
at `codedb mcp .` gives the agent 22 structural code-intelligence tools
(`codedb_outline`, `codedb_search`, `codedb_callers`, …), pure-Zig client to
pure-Zig server, zero dependencies on either side.

## KV-cache (Manus lessons)

The loop is structured for prefix cache hits: a frozen system prompt (no
per-request timestamps), strictly append-only message history, and comptime
tool-list rendering so tool order is byte-stable. `buildBody` adds an
explicit `cache_control: {type: ephemeral}` breakpoint only for `provider.id
== "anthropic"` (the real API; the codegraff gateway and OpenAI-format
providers do prefix caching automatically). `recordUsage` extracts the
cache-read count from whichever field the provider uses
(`cache_read_input_tokens`, `prompt_cache_hit_tokens`, or
`prompt_tokens_details.cached_tokens`) into `Agent.last_cache_read`, which
`request()` writes to the `cache_read_tokens` field of each `api` trace line.

## Session persistence

`/save` serializes `{provider, model, strict, messages}` with
`std.json.Stringify` to `<name>.session.json`; `/resume` parses it back into
the arena, rebuilds the provider via `Keys.providerById`, and swaps in the
restored `messages` array. Because each provider stores its history in its own
native wire shape (and switching providers clears history), a resumed session
always pairs the right wire format with the right provider — including the
codex Responses-item format. `/sessions` iterates the cwd via `Io.Dir`.

## Project instructions

`main()` reads the first of `AGENTS.md`/`HARNESS.md`/`CLAUDE.md` present in the
cwd and builds two arena-owned strings — `sys_normal` (= `main_system_prompt`
+ the file) and `sys_strict` (+ `strict_note`) — stored on the root `Agent`.
`systemPrompt()` returns `sys_strict`/`sys_normal` for the root and the lean
`sub_system_prompt` for subagents. Built once at startup, so there's no
per-request cost and the prompt stays byte-stable for the KV cache.

## ultracode codeword

`main()` scans each user line (case-insensitive) for `ultracode`; on a hit it
prints a banner, emits an `ultracode` trace note, and appends a steering note
to the message telling the model to decompose the turn into a `workflow`
(phases of parallel subagents → synthesis) rather than working solo. It's a
pure prompt-augmentation hook — no new control flow, just a per-turn nudge
toward the existing multi-agent machinery.

## Lifecycle hooks

Codex/Claude-style hooks: user-supplied shell commands that run at three
points in the loop, configured in `.harness/settings.json` (the same file
that persists approvals — `savePersisted` merge-writes so an "always allow"
mid-session never clobbers them):

```json
{
  "hooks": {
    "pre_tool":  [{ "match": "bash",                 "command": "./guard.sh" }],
    "post_tool": [{ "match": "edit_file|write_file", "command": "zig fmt ." }],
    "turn_end":  [{ "command": "osascript -e 'display notification \"turn done\"'" }]
  }
}
```

**Events and contract.** Each hook entry is `{match, command, timeout_ms}`;
`match` is `"*"` (default) or pipe-separated exact tool names, `timeout_ms`
defaults to 10 000. The command runs as `/bin/sh -c` with the event JSON on
**stdin**: `{"event","tool","input"}` for `pre_tool`, plus `"is_error"` and
the first 4 KB of `"output"` (UTF-8-safe cut) for `post_tool`, and
`{"event":"turn_end","ok":true}` for `turn_end`.

- `pre_tool` is the only hook with power: **exit 2 blocks the call**, and
  the hook's stderr is returned to the model as the (is_error) tool result —
  so the model learns *why* and can adapt. Any other exit code allows.
- `post_tool` runs after the tool, sequentially (a formatter must finish
  before the next tool runs); exit codes are ignored.
- `turn_end` fires after each completed root turn (interrupted/errored turns
  never reach it).

**Choke point.** Both tool hooks live in `execTool` — the single function
every external tool call flows through (root, subagents, and MCP tools
alike, on pool threads). That placement is what makes a `pre_tool` guard a
real boundary rather than a root-only courtesy: a subagent's bash call hits
the same gate. Meta tools (`todo_*`, `ask_user`, `attempt_completion`) are
handled inline by the orchestrator and never reach `execTool`, so hooks
don't see them — by design, they're conversation plumbing, not effects.

**Fail-open by construction.** A hook that times out is killed and treated
as *allow*; spawn failures and weird exit codes likewise. The asymmetry is
deliberate: hooks are user automation, not the security model — the
permission gate (approvals/allowlists) stays the enforcement layer, and a
broken guard script degrading to "no guard" is strictly better than a hung
hook bricking every tool call. Anything that must *fail closed* belongs in
the gate, not a hook. `runHookCmd` enforces the deadline with a poll-tick
read loop and `child.kill` (which reaps — the wait is skipped), and caps
captured stderr at 4 KB.

**Loading.** `loadHooks` parses once at startup into arena-owned slices
(`g_hooks`); `/hooks` lists them. No hot reload: the hook list is part of
the session's trust surface, same reasoning as the startup-frozen system
prompt — and it keeps the per-call cost of the disabled case at one
`len == 0` check.

## Tracing

One shared `Tracer` (an `Io.Mutex`, an `Io.Writer` over the run-exclusive
`.graff/traces/<run-id>.jsonl`, and a monotonic `Io.Timestamp` start) is
threaded through every agent and
`ToolCtx`, the same way as `Approvals`. `Agent.request` records each API call
(latency ms, request/response bytes, context tokens, error flag, agent
label); `execTool` wraps every external tool with timing. Events are structs
serialized by `std.json.Stringify` — one line each, flushed immediately, so
the file is always valid JSONL mid-session. Every line carries the run id,
PID, and runtime session id. Consumers must still tolerate a malformed final
tail after a crash or I/O failure. The system prompt points the agent at the
file, which is what makes self-debugging work: the agent reads its own trace
with `read_file` and analyzes it. `/trace` locates and toggles it, best-effort
(a failed open just disables tracing).

`BehaviorTrace` is a second, mutex-protected producer with two independent
sinks: a per-run `.graff/trajectories/<run_id>.jsonl` local stream and an optional
bounded `behavior_upload.Upload` projection. Both use flat
`codegraff.behavior.v1` events and retain one logical source sequence. A healthy
local file is a contiguous prefix; bounded upload admission can preserve sparse
source sequence numbers and reports gaps with `dropped_events`. Main owns both
sinks, joins session workers before terminal closure, emits `run_finished`, and
then makes at most one best-effort three-second POST beside the configured OTLP
endpoint at `/v1/behavior`. An upload claims `complete=true` only when terminal
event admission succeeds; a dropped terminal remains `complete=false` and is
included in `dropped_events`. Timeout cancellation synchronously joins the HTTP
task before its payload is released. The local file itself is never uploaded.

`providers.runTurnWithFallback` is the common root-turn boundary. API/tool rows
in the operational trace carry that active turn until the provider operation
returns; subsequent administrative or resume-preprocessing work is turn `0`.
The upload accumulates content-free per-turn API/tool-category metrics. Local
run-start provider/model/effort/prompt-fingerprint fields are explicitly an
initial snapshot, not per-turn wire facts. The deterministic prompt fingerprint
is omitted from every network projection because low-entropy prompt variants can
be enumerated. With ordinary telemetry enabled,
the upload defaults to a fixed-field allowlisted metadata projection, including
only a controlled client class rather than arbitrary `HARNESS_CLIENT` content;
rich-event metadata is limited to correlation, controlled tool class,
byte/duration/error counters, and truncation flags. Only an explicit content
opt-in can serialize opaque fields supplied through the typed
commitment/misprediction APIs or exact rich tool/text fields. Provider/tool
plumbing does not infer dedicated
prompt-text, generated-output, hidden-reasoning, source, path, argument, result,
or task-state fields. Initial provider and model identifiers are serialized
exactly as configured and are not inspected or value-redacted. The eval-driven
loop is the first production producer of typed commitment/misprediction events:
it stops on red, preserves an incomplete repair state, and requires a fresh
green verifier result before completion. The local tournament recomputes a
bounded behavior score from closed rich traces. General task adapters,
automatic semantic verification, and fleet-wide behavioral consumption remain
deferred.
The pre-existing append-only `Trajectory` DGM ledger and its record shapes remain
unchanged. See
[`docs/behavioral-trajectories.md`](docs/behavioral-trajectories.md).

## Local learning engine

`startup.zig` dispatches `graff learn` before ordinary provider/key/session
initialization. `learn_cli.zig` owns strict command parsing and orchestration;
`learn_eval.zig` owns typed mutation/evaluation protocols, deterministic seeds,
paired aggregation, and evidence re-verification; `learn_store.zig` owns the
private content-addressed store and activation transaction chain. The engine is
separate from the append-only DGM trajectory and behavioral streams: neither is
accepted as promotion evidence.

A run binds the immutable config, harness version, parent genome, parent
generation, parent transaction, random nonce, and a recomputed trial ID.
Candidate and pair seeds derive from that envelope. Adapter requests/responses,
genomes, and the final run record are domain-separated immutable objects. On
promotion the engine reloads every object, reconstructs seeds and aggregates,
checks mutation output bytes against the mutator's declared SHA-256, and requires
the run's complete parent ref to equal the active ref.

Repetitions remain useful measurements but are clustered by unique suite case
for the one-sided sign test and `minimum_pairs`; repeating one case cannot create
independent statistical units. Critical regressions reject immediately,
Bonferroni correction uses the planned candidate count, holdout gates follow the
primary gate, and cost participates only after correctness.

Configured tools, declared inputs, and suites are read and hash-checked through
single open handles. Each invocation executes a private verified program
snapshot; the program must remain directly executable after relocation. Exact
declared-input arguments are rewritten to private snapshots, and the evaluator
sees a private `suite.json`. This closes pathname-reopen TOCTOU for the bytes
Codegraff claims to pin. It is not process isolation: interpreters, libraries,
undeclared dependencies, subprocesses, network data, and all other files visible
to the user's OS account remain in the trusted computing base.

On POSIX, activation publishes and synchronizes an immutable transaction, then
atomically replaces `refs/active.json` and synchronizes its directory. Windows
uses synced file contents and atomic replacement but skips unsupported directory
flushes, so its power-loss guarantee is weaker; learning files there inherit
ambient workspace/temp ACLs. Loads verify the complete ancestry; rollback
appends a new transaction rather than deleting history. `fleet.zig`
marks the verified learned agent as local activation authority so later remote
elite merges cannot replace that name. Full schemas, operational guidance,
privacy implications, and the unimplemented collective-learning design are in
[`docs/local-learning.md`](docs/local-learning.md).

## Compaction

Client-side and provider-agnostic. Every response's `usage` is recorded
(`input+output+cache` for Anthropic, `total_tokens` for OpenAI) and shown in
the prompt. Past the model's compaction threshold (80% of its context window, looked up
in a comptime `model_table` — Anthropic numbers from the model catalog,
gateway numbers from its `/v1/models` endpoint; unknown models fall back to a
conservative 200k context) — or on `/compact` — the
harness sends the history plus a handoff instruction *with no tools offered*,
forcing a text summary, then replaces the whole history with one user message
embedding that summary and resets the counter. If the summary request fails,
history is left untouched.

## Memory model

- Root history lives in the process arena (whole-session lifetime); each
  subagent gets a private arena freed when it returns.
- Parsed responses use `parseFromSliceLeaky` with `.allocate = .alloc_always`
  so Values survive the raw response buffer being freed.
- Per-request bodies and tool outputs use the general-purpose allocator and
  are freed each iteration; tool results are duped into the arena before
  entering history.
- The MCP registry has its own arena for the session.

## Where this could go next

- **Streaming (SSE)** — both providers support it; the request shape barely
  changes, and it's the enabling feature for a web UI.
- **HTTP server mode** — swap the REPL for `std.http.Server`; sessions become
  a map of `Agent` instances. History is already `std.json.Array`, so
  persistence is one stringify away.
- **Next.js / DigitalOcean** — the cleanest path is the HTTP server above with
  Next.js as a pure frontend over SSE; the quick path is a process-wrapper
  bridging stdin/stdout to a WebSocket. Either way, `bash`/`write_file` are
  arbitrary code execution, so each session needs a sandbox (one container or
  microVM per session) before any public exposure.
- **MCP over SSE/HTTP** — currently stdio only; the transport is isolated in
  `mcp.zig`, so an SSE transport slots in beside it.
```
```

## Performance baseline (v0.0.210 · arm64 macOS · stripped ReleaseFast)

Measured budgets — a change that blows past one of these deserves a look
before it merges. Re-measure with `hyperfine -N '<bin> --version'` for
startup and `/usr/bin/time -l <bin> …` for memory.

| metric                                | v0.1.0          | budget        |
| ------------------------------------- | --------------- | ------------- |
| binary size (ReleaseFast, arm64)      | 2.74 MB         | < 3 MB        |
| cold start (`--version` / `--schema`) | ~1.8 ms mean    | < 10 ms       |
| peak RSS, no network (`--schema`)     | 1.8 MB          | < 8 MB        |
| peak RSS, full one-shot turn (`-p`)   | 12.1 MB         | < 64 MB       |
| CPU share of a one-shot turn          | ~4% (0.11 s of 2.7 s) | network-bound |

For scale: the entire feature set added in the post-90c5cce UX pass (esc
overhaul, retry/backoff, version stamping) cost **816 bytes** of binary.

### Multi-agent overhead (same build)

Subagents are threads in the same process — each gets a throwaway arena and
shares the root's gpa, HTTP client, approvals, and tracer. Measured with the
workflow tool fanning out trivial parallel tasks:

| metric                                   | measured        | budget   |
| ---------------------------------------- | --------------- | -------- |
| marginal RSS per parallel subagent       | ~0.4 MB         | < 2 MB   |
| root + 8-way fan-out (max), peak RSS     | 15.0 MB         | < 64 MB  |
| tool output captured per bash call       | ≤ 1 MB + 32 KB stderr (truncated, exit code kept) | hard cap |
| tool output entering model history       | ≤ 4 KB (the #440 handle threshold), whatever the result's size | hard cap |

Child processes a tool spawns (python, make, …) are *outside* the budget by
design: they live in their own process, so their memory never lands in the
harness's RSS — verified with a 500 MB python allocation under an 8-line
harness that stayed at 12 MB. `runCapped` keeps the first 1 MB of a chatty
child's output and discards the rest as it streams, so even a 10 MB print can't
inflate retained memory. History is bounded separately and much harder: past the
handle threshold a result is written to `.graff/tool-results/` and only a
preview, a path, a byte count, and a shape hint reach the model (#440), so what
a tool prints and what a turn pays for are no longer the same number.

### Context: vs the Rust codegraff (justrach/codegraff v0.2.16, same machine)

Different scope — the Rust codegraff ships zsh integration, VS Code commands,
semantic-search workspaces, commit generation, and more — so this is a
"what does the architecture cost" comparison, not a fairness contest. The
turn rows are apples-to-apples: both one-shots ran the *same* model through
the *same* endpoint (deepseek-v4-pro via gateway.codegraff.com), interleaved
3× to spread network variance.

| metric                          | rust graff v0.2.16 | zig harness v0.1.0 | ratio |
| ------------------------------- | ------------------ | ------------------ | ----- |
| binary (arm64 release)          | 39.2 MB            | 1.69 MB            | 23×   |
| cold start (`--version`)        | 4.9 ms             | 1.4 ms             | 3.5×  |
| peak RSS, `--version`           | 13.0 MB            | 1.8 MB             | 7×    |
| one-shot turn, same model, wall | 2.94 s mean        | 2.93 s mean        | tie (network-bound) |
| one-shot turn, same model, RSS  | 48.5 MB            | 11.3 MB            | 4.3×  |
| dependencies                    | 934 crates         | 0 (std only)       | —     |
| agent-loop source               | ~5.8 MB Rust       | ~280 KB Zig (2 files) | ~20× |
