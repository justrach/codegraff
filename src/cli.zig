//! `graff update [--force|--check]`: compare the installed harness_version
//! against the latest GitHub release tag (SemVer parse; refuse to downgrade a
//! dev/newer build) and delegate the download / codesign / atomic swap to
//! install.sh. Split out of main.zig (600-line goal). Back-imports main for
//! harness_version. main aliases updateCommand back.
//!
//! changelog_text/usage_text (the `--version`/`--help` text blocks) also live
//! here (600-line goal, #123) — pure string consts, aliased back in main.zig
//! since they're only ever printed from within main().

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const harness_version = root.harness_version;

/// Shown under `graff --version` — a terse "what's new" for recent releases.
/// Keep it short and current; bump alongside the version each release.
pub const changelog_text =
    \\What's new
    \\──────────
    \\0.0.285
    \\  • native transcript stays put when you scroll up mid-stream; return to the tail to follow again (#724)
    \\  • follow-ups typed while a turn is running queue and send when it ends
    \\  • native tools land in the answer, not as a wall on top; settled batches fold
    \\  • workspace switch stars and reports the process cwd (#721)
    \\  • Codex WS type:error retires the socket immediately; last_api_error stays bounded (#717)
    \\  • TUI steer / /btw queues composer image chips with the text, not text alone
    \\
    \\0.0.284
    \\  • ACP turns stage GUI @[image] attachments as native vision blocks — pasted images reach the model
    \\  • peer inbox wake is advisory ("parked; read when relevant"), never a command that displaces the turn
    \\  • parallel error bash results stay valid JSON on the next Codex request (#711)
    \\  • /resume and /sessions find ~/.graff/sessions, not just cwd (#712)
    \\  • named-source gate is per mention; identical user turns do not replay (#714)
    \\  • fullscreen /goal is retirable; completion no longer resumes stale steering (#716)
    \\
    \\0.0.283
    \\  • deleted composer image chips reuse #N; paste traces omit MIME/bytes until send (#702)
    \\  • peer_message addresses a live session by its visible title or saved-session base (#700)
    \\  • tuiguard fails a wedged PTY probe instead of hanging pre-push (#704)
    \\  • same-boundary compact_cut with no shrink stops after two tries (#706)
    \\  • credential replace fsyncs the POSIX directory after rename (#405)
    \\  • graff acp answers initialize and advertises graff-login before keys (#701)
    \\  • ESC ESC CSI Alt+arrow is one nav event — does not cancel (#524, #707)
    \\
    \\0.0.282
    \\  • pasted-text chips are atomic spans — a typed lookalike stays literal (#674)
    \\  • Codex WS type:error is a terminal API response; last_api_error stays (#693)
    \\  • request-construction TLS failure rotates a leased HTTP client generation (ADR 0048)
    \\  • --resume SOURCE --branch DEST is clone-on-write (ADR 0049)
    \\  • MCP HTTP/WSS reuse warmed TLS; catalogs can arrive gzip (ADR 0050)
    \\  • /teleport + /snapshot gc (ADR 0051); DeepSeek thinking off at low (ADR 0054)
    \\  • lean -p bounces prose-only done (ADR 0052) and backgrounds bash at 15s (ADR 0055)
    \\
    \\0.0.281
    \\  • -p / --json skip learn auto-init — no 132M graff-pinned copy (ADR 0044)
    \\  • SuperGrok SWE 5/6 in 205s / 6.5s CPU (was 4/6 in 456s / 230s)
    \\  • TUI claims alt-screen before boot; live markdown on the cached tail (ADR 0042)
    \\  • companion MCP queues in the background; mid-turn stalls stay off the transcript
    \\  • Codegraff SWE is not GLM-only: Gemini 5/6 in 103s; DeepSeek flash still one-shots (ADR 0047)
    \\
    \\0.0.280
    \\  • leftover 279 work: TUI stall/resize, experiment fan-out, /tell /peek, ACP graff-login
    \\  • local tools (.graff/tools), /schedule due-claim, JSONL channel workers
    \\  • native codedb / read_file stay the default readers; codedb-pro is extra search (ADR 0040)
    \\
    \\0.0.279
    \\  • native Beautiful UI app speaks ACP: thinking and tool chips stream mid-turn (ADR 0032)
    \\  • graff acp emits thought / tool_call / text session/update; /never is an ACP slash command
    \\  • /never on a TTY is a searchable picker with two confirms; rm and ACP list still work (#638)
    \\  • bash_output wait_ms>0 always waits for exit — mid-range values are not a timeout (#640)
    \\  • host recipe: docs/embedding.md; @codegraff/sdk/acp spawns graff acp
    \\  • first-turn tools: no MCP handshake wait, live chips show elapsed from start (ADR 0035)
    \\
    \\0.0.278
    \\  • deleted composer screenshots are not sent: submit keeps [Image #N] / @[path] only (#634)
    \\  • /image and /paste stay sticky; /image clear drops the whole queue
    \\  • TUI backspace / Ctrl+U / overlay backspace detaches chips
    \\  • Smolify is no longer a reserved core MCP; add it via `graff mcp add` if you want it
    \\
    \\0.0.277
    \\  • MCP-inside-rlm + learnt slim: fat MCP results drop to id/title; comments fold to n+latest_author (ADR 0029)
    \\  • L (warm slim, --no-lean) 14.8s/31k/5 vs H 28s/112k/7 on SuperGrok grok-4.6
    \\  • xAI Responses hosts x_search on grok-4.6 tools turns (ADR 0031); GRAFF_XAI_X_SEARCH=0 opts out
    \\  • rlm stays hidden on small turns; showcase at --rlm, a 4-wide native batch, or 50% of compactAt (ADR 0030)
    \\  • licensed codedb-pro is one read/search surface; Smolify is opt-in; turns pulse without a 16-call cap
    \\
    \\0.0.276
    \\  • rlm (RLM + mid-stream spec-ptc) is the default loop; --old / --no-rlm restores structured-only
    \\  • prompt-cache max: stable catalog is the default (loads no longer rewrite tools JSON); children share prefix lanes
    \\  • foreground bash auto-backgrounds after 120s instead of waiting forever (#620)
    \\  • Kimi identity: graff/<version> User-Agent; device headers match kimi-code (#617)
    \\  • Codex session_id header matches prompt_cache_key (openai/codex)
    \\  • Codex thinking silence uses the full stall budget; stall notice is honest
    \\  • REPL/TUI prints a dim line when a newer graff release is available
    \\
    \\0.0.275
    \\  • OpenRouter requests carry app attribution (categories: cli-agent, programming-app)
    \\  • TUI: Esc with a draft in the composer never kills a live turn
    \\  • agent: retry degenerate empty completions and keep-alive-only bodies
    \\
    \\0.0.274
    \\  • rate-limit retries no longer dump the provider's raw error JSON
    \\
    \\0.0.273
    \\  • long tool calls print a dim "still running" heartbeat instead of going quiet
    \\
    \\0.0.272
    \\  • Windows: line REPL prompt and graff-repl also use UTF-8, not only the TUI (#607)
    \\
    \\0.0.271
    \\  • Windows: TUI/REPL box-drawing is UTF-8 (CP 65001), not CP437 mojibake (#607)
    \\
    \\0.0.270
    \\  • OpenRouter (OPENROUTER_API_KEY → anthropic/claude-sonnet-4.6); live /models
    \\  • Windows: edit_file/write_file no longer panic on path chmod (#606)
    \\  • Line REPL transcript is the task, not the event bus
    \\  • TUI markdown: lists, quotes, tasks, rules, italic
    \\
    \\0.0.269
    \\  • Vercel AI Gateway (AI_GATEWAY_API_KEY → alibaba/qwen3.8-27b); coding-agent /v1
    \\  • Z.AI defaults to GLM-5.3 (1M); thinking.enabled + implicit prefix cache
    \\  • GLM Coding Plan: ZAI_CODING=1 / GRAFF_ZAI_URL; not image/video
    \\  • Line REPL tool rows are decisions; live bash is /debug-only
    \\
    \\0.0.268
    \\  • Cerebras Inference (CEREBRAS_API_KEY → gpt-oss-120b); not the WSE CSL SDK
    \\  • Codex-shaped .harness/agents/*.toml (and ~/.codex/agents) pin model/effort
    \\  • imagegen Codex engine: private config so exec no longer rejects JSON (#576)
    \\  • Live bash chunks + idle job notify + raw terminal (do not poll)
    \\  • ask_user pastes reach the model as vision blocks; compact keeps the live prompt's images
    \\
    \\0.0.267
    \\  • bash_output/agent_output wait_ms>0 blocks until exit (10h), not a 30s poll
    \\
    \\0.0.266
    \\  • In-place Cursor/Claude/Grok/Codex plugins (no cache walk; Codex via config.toml)
    \\  • Skill catalog is cache-stable: names + triggers, pinned once, no file: paths
    \\  • Peer inbox is pull; standing goal is one prefix line; workspace tool switches trees
    \\  • install.sh puts graff on PATH; long-horizon evals use external verifiers
    \\
    \\0.0.265
    \\  • TUI clicks work everywhere they look clickable; overlays are framed panels
    \\  • /models shows provider + cost badge; prices refresh from LiteLLM
    \\  • /snapshot attach|list and /rewind for a Docker sandbox seam
    \\
    \\0.0.263
    \\  • grok-4.6 is the xAI default: 500k window, published dual-band prices
    \\  • /effort low|medium|high|xhigh on native Grok (gateway grok-build still ignores it)
    \\  • Per-project prompt cache key survives a new session in the same cwd
    \\  • TUI: crash/suspend restore, in-app drag selection, SIGTSTP/quit livelock gone
    \\
    \\0.0.262
    \\  • Formal conformance corpus (Lean kernels + executable reference)
    \\  • TUI /compact runs the real engine compaction; mid-turn /new|/compact|/rewind refused
    \\
    \\0.0.261
    \\  • Grok-style TUI: syntax-highlighted fences, sticky prompt header, auto light/dark, flicker-free paints
    \\  • ~24 rendering/input fixes: phantom-Escape turn cancels, debris typed into the composer, bold bleed, emoji-bent borders, /theme half-repaints
    \\  • xAI KV-cache affinity headers + WebSocket 25-min limit handling
    \\
    \\0.0.260
    \\  • Fixed the composer wiping itself mid-typing after a Cmd+Tab (stale Super latch made Backspace act as Cmd+Backspace)
    \\
    \\0.0.259
    \\  • Grok defaults to xAI's Responses wire: WebSocket turns, lossless server-side compaction, structured outputs — no env needed (GRAFF_XAI_WIRE=chat opts out)
    \\  • Fixed duplicate MCP tool definitions that made strict Responses endpoints reject every turn
    \\
    \\0.0.258
    \\  • Full Grok on a SuperGrok sub: GRAFF_XAI_WIRE=responses gets server-side compaction (lossless blob), WebSocket turns, and --output-schema structured outputs
    \\  • /compact on the xAI wire uses the first-party endpoint; strict schemas run two-phase so they never suppress tool use
    \\  • Kitty keyboard overhaul: right-side modifiers fixed, no release double-fires, terminal state restored even on SIGTERM
    \\  • graff-evals: in-repo eval suite (12 tasks) with side-by-side harness comparison
    \\
    \\0.0.257
    \\  • Composer box aligns and wraps on words, not mid-letter
    \\
    \\0.0.256
    \\  • TUI swallows leftover Kitty CSI-u, types Shift+9 as (, logs stdin to .graff/tui-traj.jsonl
    \\
    \\0.0.255
    \\  • TUI no longer dumps mouse CSI (39;33;23M) into the thinking line
    \\
    \\0.0.254
    \\  • graff tui is a Grok-style fullscreen pager (composer wrap, tool fold, effort picker, markdown tables); bare graff stays the line REPL
    \\  • /import-claude copies Claude/Cursor MCP servers and skills into ~/.codegraff on first start or on demand
    \\
    \\0.0.253
    \\  • /compact uses first-party OpenAI compaction for direct API-key and Codex sessions, with transactional local fallback
    \\  • Kimi cache affinity plus concurrent catalogs and MCP startup remove avoidable serial latency
    \\  • @codegraff/sdk ships its platform binary and production Harness/Remote controls for npm embedding
    \\  • The REPL gains quiet normal output, /debug and read_file contains=; desktop agents move into focused control with new branding
    \\
    \\0.0.252
    \\  • Grok models come from a live api.x.ai /v1/models fetch every load — new rollouts no longer wait for a release
    \\  • SuperGrok OAuth tokens send X-XAI-Token-Auth like grok-build, so login sessions can actually call the API
    \\
    \\0.0.250
    \\  • First-party OpenAI compaction preserves the complete canonical compact output on both Codex subscription and official Platform Responses routes
    \\  • Invalid remote compaction falls back locally without mutating history; non-OpenAI providers remain local-only
    \\  • REPL tool calls use stable terse start/result rows with readable previews instead of raw JSON
    \\
    \\0.0.249
    \\  • Folded native tools become callable as soon as their schemas load; the active catalog now rebuilds instead of advertising unreachable tools
    \\  • Turn events and generated TypeScript SDKs expose cumulative input, output, cache-read, and cache-write token usage
    \\  • codedb-pro paths resolve from the active session worktree, and piped ask_user sessions end cleanly at EOF
    \\  • The default prompt carries a capped skills catalog, with concurrent interactive WebSocket tool loops covered by the release suite
    \\
    \\0.0.247
    \\  • Interactive startup is quiet by default; `GRAFF_REPL_DEBUG=1` restores launch and runtime diagnostics, and `/debug` still toggles them live
    \\  • Shared-worktree ownership is a structured callout with the active session, goal, and `graff -w` isolation action
    \\  • Immediate multiline pastes into `ask_user` preserve every line instead of submitting only the first
    \\
    \\0.0.244
    \\  • Co-resident graff sessions now see each other: a startup warning names any live session already in your worktree, and the first git mutation, file write, or shell move against a peer's tree pauses once for a deliberate re-issue — two agents can no longer silently tear one tree
    \\  • Sessions can message each other: peer_message posts to this folder's room, or names one session as a DM (not "all" — retired for the model). /tell <session> is a human DM; /tell all is the user's device-wide broadcast. Delivery is at the receiver's next step boundary, with the sender's current goal attached
    \\  • The model is told up front who else is live and what they're working on, so it coordinates — or picks disjoint work — before any collision
    \\  • /peek <session> shows what a live co-resident session is doing right now — its last prompt, last action, last tool
    \\  • Session recaps ride the event stream: settled turns carry a Completed or Needs-input status with a one-line recap for the GUI agent overview
    \\  • Subscriptions are billed and routed as subscriptions: a flat-rate login (Codex, Kimi, SuperGrok) now outranks an API key on the same provider instead of losing to it, costs $0 in /cost, and the key it displaced is parked and takes over — announced — only if the plan runs out of quota
    \\  • Worker tiers land on seats you already pay for: an explicit tier ask crosses to a logged-in plan (mid → k3, small → gpt-5.6-luna) rather than a metered rung — except a DeepSeek session (direct or via codegraff), which stays on flash instead of dropping to luna
    \\  • A tier rung must now be a genuinely cheaper SEAT, so anthropic descends opus-5 → sonnet-5 instead of to an equally-priced older opus, and deepseek-v4-flash replaces pro outright
    \\  • `graff route` with no model lists every provider you can reach, what it bills, and the tiers it offers
    \\  • Anthropic serves its live model list, so new Claude releases arrive without a rebuild
    \\
    \\0.0.243
    \\  • The terminal palette now matches codegraff.com: the identity accent is the site's emerald (#059669) — spinner, prompt, headings, tool-call lines, and attached-file chips — so a routine ⚙ bash line no longer reads as error red
    \\  • The ensō spinner actually turns now: six brush poses stepping at 100ms instead of four doubled poses every 320ms — the ~3fps stutter is gone
    \\
    \\0.0.242
    \\  • MCP tool schemas load on demand: a 13-tool server's catalog drops 64.8%, about 1,700 input tokens off every request; small servers stay eager and unchanged
    \\  • A big tool result returns a handle — preview, path, byte count, shape — instead of its contents, so it never occupies context turn after turn
    \\  • Sessions keep an append-only transcript compaction cannot rewrite, and compaction now states what survives on both sides of the boundary
    \\  • Windows: the transcript wrote 0 bytes on every run; the durable-transcript prompt line now waits for the first compaction instead of being paid for from turn one
    \\  • /btw asks a side question over the live context with tools off, then throws it away — billed, rendered, never added to the session
    \\
    \\0.0.241
    \\  • Goal/loop runs stop paying for verifications the workspace cannot have changed: an unchanged tree skips the eval command and its judge call, and the model is steered to edit first
    \\  • Oversized tool outputs spill to a session artifact the model can read or grep instead of being destroyed at the cap; throttles no longer masquerade as context overflows, and silent overflows recover in one trim
    \\  • The system prompt is capability-gated — embedder sessions drop ~15% of it — and a durable session's prompt names its own transcript
    \\  • Cross-process locks key on process START identity, a 426 WebSocket refusal latches SSE at once, and tool-execution output joined the typed event stream
    \\
    \\0.0.240
    \\  • Engine output now flows through a typed event stream behind a strict sink boundary — the start of the REPL/engine separation, with TUI and --json output proven byte-identical
    \\  • Quitting no longer strands the held Codex socket: loop exit closes the WebSocket and its response anchor, and debug builds finish with a clean allocator report
    \\
    \\0.0.239
    \\  • Codex WebSocket turns can't stall silently: visible output tightens the watchdog, a mute reused socket is retried in ~30s, and send/dial run under deadlines with Esc live
    \\  • A successful /login reaches the live session — codex auth recovery re-reads auth.json, spends the refresh token, and retries once instead of looping on a dead bearer
    \\  • Failed one-shots still print the [usage] footer and note completed tool work; rate-limit waits get a human duration; empty compaction summaries escalate instead of looping
    \\  • /save and /resume copy the typed name out of the readline buffer, and /rewind never deletes a file it failed to snapshot
    \\
    \\0.0.238
    \\  • Tight-budget runs hold back a landing reserve, so they finish, verify, and still deliver the final answer instead of dying mid-narration
    \\  • A completed run releases the terminal instead of suspending on tty input, and worker activity lines wait for the foreground's line boundary
    \\  • Completed todo items parked from a prior goal retire at the next ask instead of piling up across prompts
    \\  • Fleet workers retry transient failures within a bound — one flaky HTTP response can't lose a finished report, and budget refusals never blind-retry
    \\  • Search roles ride the small rung; landed turns feed local learning, and a learned decline names the policy it came from
    \\
    \\0.0.231
    \\  • edit_file verifies every edit actually landed on disk; a silent no-op is a loud tool error instead of a false success, and batched same-file edits can no longer race each other
    \\  • Embedder mode is complete: the hard --no-local-tools gate (MCP-sourced coding tools) plus resumable serve streams with seq ids, ?from=N replay, and durable sessions (schema 0.10)
    \\
;

pub const usage_text =
    \\graff — a minimal agentic coding harness in Zig (zero deps)
    \\
    \\usage:
    \\  graff [flags]                    start the REPL
    \\  graff [-p] "prompt"              one-shot: run the prompt, print the answer, exit
    \\  graff login                      get a codegraff key (device-code OAuth)
    \\  graff login codex [--refresh]    ChatGPT/Codex OAuth login (PKCE)
    \\  graff login kimi                 Kimi Code OAuth login (device-code)
    \\  graff login xai                  Grok/SuperGrok OAuth login (device-code)
    \\  graff key set <provider> <key>   store a key (Keychain; POSIX 0600 file; Windows home ACL)
    \\  graff key list                   show which providers have keys
    \\  graff models [refresh]           list the live catalog; refresh Codex + models.dev metadata
    \\  graff route <model>…             dry-run which provider/billing a model lands on (no API call)
    \\  graff mcp add <name> -- <cmd>     add a stdio MCP server to .mcp.json
    \\  graff mcp add <name> --url <url>  add a Streamable HTTP MCP server
    \\  graff mcp login <name>            OAuth login for a remote MCP server
    \\  graff mcp                         list configured MCP servers
    \\  graff plugins [load <name>]       list Claude/Cursor/Grok/Codex plugin trees (in place)
    \\  graff learn [help]                local mutate/evaluate/promote/rollback engine
    \\  graff worktree list              list -w tabs and experiment-pool trees (tagged)
    \\  graff worktree merge <name>      squash-land worktree-<name> onto the current branch + clean up
    \\  graff worktree remove <name>     discard worktree-<name> (drops its scratch work) + delete the branch
    \\  graff worktree prune             drop git registrations for worktrees whose dirs were deleted
    \\  graff servers                    background servers graff started (this session's or older): pid, port, age
    \\  graff servers stop <pid>         end one (its whole process tree); `prune` drops records of dead ones
    \\  graff sandboxes                  list your gateway sandboxes (what's burning credits)
    \\  graff sandboxes stop <id>        spin a sandbox down (stops it + settles the meter)
    \\  graff cube new                   spin up a cloud graff (sandbox + serve + preview URL)
    \\  graff cube [status|stop]         inspect the running cube or spin it down
    \\  graff --schema                   print the machine-readable interface (SDK codegen)
    \\  graff serve                      HTTP/NDJSON bridge over the --json protocol
    \\                                   (--host/--port/--token; sessions are --json children)
    \\  graff acp                        Agent Client Protocol agent on stdio (Zed and other ACP editors)
    \\  graff update [--force|--check]   update graff to the latest GitHub release
    \\  graff title <prompt>            print the AI tab-title for a prompt (test title styles)
    \\
    \\flags:
    \\  --model <name>   start on this model (same fuzzy resolution as /model)
    \\  --subagent-model <name>         pin children/workflows/judges on the root provider
    \\  --subagent-provider <id>        route pinned workers through this provider
    \\  --allow-cross-provider-subagents confirm prompts/code may go to the worker provider
    \\  --no-subagent-tier              opt out of the default worker tier ladder (inherit the root model)
    \\  --resume <name>  resume/autosave <name>.session.json
    \\  --branch <name>  clone --resume into an independent autosave target
    \\  --new            start a fresh autosaved session (default)
    \\  --no-resume      ignore --resume and start fresh
    \\  --system-prompt <text>          replace the built-in system prompt
    \\  --append-system-prompt <text>   append extra text to the system prompt
    \\  --goal <text>                   seed a standing objective (tracked as a todo checklist) for every turn; persists across completions
    \\  --eval <cmd>                    scoring command for an eval-driven loop (the `eval` tool runs it)
    \\  --until <0-100>                 eval-loop target score; stop when reached (default 90)
    \\  --niche <name>                  fleet niche this eval optimizes (reviewer/researcher/implementer/skeptic or a custom agent); tags submitted scores so the DGM can promote a champion for that role
    \\  -w, --worktree <name>           isolate this session in a git worktree (.graff/worktrees/<name>) so parallel agents don't collide on files
    \\  --experiment N                  pre-mint N child worktrees (1-16) under .graff/worktrees/exp-<id>/; next spawns claim a seat
    \\  --add-dir <path>                extra file-tool root (repeatable, max 16). Not a cwd switch; no skills/sessions from it
    \\  --context-limit name=N          cap a named prefix: skill_catalog_bytes|mcp_schema_bytes|agents_md_bytes
    \\  --no-autocommit                 with -w, don't auto-commit each turn (default on; land work with `graff worktree merge`)
    \\  --yolo           skip all permission prompts for the session
    \\  --rlm            advertise the rlm REPL (default; persistent binds, subagent(), llm_query, mid-stream spec-ptc; GRAFF_RLM=1)
    \\  --old, --no-rlm  restore the pre-rlm structured-only catalog (GRAFF_OLD=1 or GRAFF_RLM=0)
    \\  --lean           slim tool surface (8 core tools) + MCP schemas folded behind load_tool_schemas — the DEFAULT for -p one-shots (GRAFF_LEAN=1). `.mcp.json` still connects.
    \\  --no-lean        opt a one-shot out of the implied --lean: full tool surface + eager MCP schemas, the pre-default -p behavior
    \\  --no-local-tools embedder mode: hard-disable the built-in bash/bash_output/bash_kill/read_file/edit_file/write_file/codedb tools for the whole process (subagents included), so graff can run outside the sandbox and get its coding tools from an MCP server instead; webfetch, orchestration and MCP tools still work (GRAFF_NO_LOCAL_TOOLS=1)
    \\  -p, --print      one-shot print mode (answer on stdout, progress on stderr)
    \\  --timing         show per-tool wall-clock on result lines
    \\  --cost           show running session spend in the prompt
    \\  --json           structured stdio protocol (JSON in, JSONL events out)
    \\  --max-tool-calls N  reject root tool calls after N per turn (JSON-safe budget)
    \\  --max-model-calls N total provider calls allowed across this run (default 0 = unlimited; includes children/title/judges)
    \\  --dedupe-tool-calls reject duplicate root tool name+input calls per turn
    \\  --no-telemetry   disable anonymous usage telemetry for this run
    \\  --learning-privacy <mode>       learning egress ceiling: local|aggregate|templates|examples (default aggregate)
    \\  -h, --help       this help
    \\  -V, --version    print version
    \\
    \\keys: <PROVIDER>_API_KEY env vars, `graff key set`, or `graff login`;
    \\a Codex CLI login is picked up automatically.
    \\inside the REPL: /help lists commands, a bare "/" opens the command menu,
    \\"@" opens a fuzzy file picker (a drag-and-dropped image attaches as a
    \\native vision block on vision models; other files paste as their path),
    \\esc interrupts a streaming response, "always allow" persists to
    \\.harness/settings.json.
    \\telemetry: /debug is a local content-free HUD (session/turn/tool
    \\decisions). Anonymous OTLP usage stats leave the process only when
    \\OTEL_EXPORTER_OTLP_ENDPOINT (or GRAFF_OTEL_ENDPOINT) is set; opt out
    \\with --no-telemetry or GRAFF_NO_TELEMETRY=1. GRAFF_TELEMETRY_KEY sends
    \\an optional x-harness-key token to the configured collector.
    \\learning privacy: local learning trials publish prompt-free aggregate grades
    \\by default, announced once per machine; /privacy local (or
    \\GRAFF_LEARNING_PRIVACY=local, GRAFF_FLEET=off, --no-telemetry) sends nothing.
    \\/privacy changes the session ceiling; template text still needs exact approval.
    \\
;

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    fn eql(self: Version, other: Version) bool {
        return self.major == other.major and self.minor == other.minor and self.patch == other.patch;
    }

    fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }
};

/// Parse a leading `MAJOR.MINOR.PATCH` from `s` (after any leading 'v' is
/// stripped by the caller). Returns null if the numeric triple isn't present.
fn parseVersion(s: []const u8) ?Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const patch_s = it.next() orelse return null;
    // Each component must be all digits up to the next '.' (or end). `patch`
    // may trail a pre-release suffix ("-3-gabc", "-dev"); take only the leading
    // digits so "0.0.14-3-gabc" parses as 0.0.14.
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return null;
    const patch_digits = std.mem.indexOfAny(u8, patch_s, "-+") orelse patch_s.len;
    const patch = std.fmt.parseInt(u32, patch_s[0..patch_digits], 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// True when `s` is a bare release version with no `git describe` suffix — i.e.
/// exactly `MAJOR.MINOR.PATCH` (optionally 'v'-prefixed), no "-N-gHASH",
/// "-dirty", "-dev", or "+build". A dev/dirty/commit-ahead build is not a clean
/// release and shouldn't be silently "updated" (downgraded) to an older tag.
fn isCleanReleaseVersion(s: []const u8) bool {
    if (s.len == 0) return false;
    var dots: u8 = 0;
    for (s) |c| {
        switch (c) {
            '0'...'9' => {},
            '.' => dots += 1,
            else => return false, // any '-','+','g',... means it's not a bare tag
        }
    }
    return dots == 2;
}

fn fetchLatestReleaseTag(io: Io, gpa: Allocator, arena: Allocator, repo_api: []const u8) ?[]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    const extra = [_]std.http.Header{.{ .name = "Accept", .value = "application/vnd.github+json" }};
    const res = client.fetch(.{
        .location = .{ .url = repo_api },
        .method = .GET,
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
        .extra_headers = &extra,
    }) catch return null;
    if (@intFromEnum(res.status) != 200) return null;
    if (aw.writer.buffered().len > 64 * 1024) return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const t = v.object.get("tag_name") orelse return null;
    return if (t == .string) t.string else null;
}

/// Dim REPL/TUI line when GitHub has a newer release. Null if current, newer,
/// offline, or GRAFF_NO_UPDATE_CHECK is set.
pub fn updateAvailableLine(io: Io, gpa: Allocator, arena: Allocator, skip: bool) ?[]const u8 {
    if (skip) return null;
    const repo_api = "https://api.github.com/repos/justrach/codegraff/releases/latest";
    const latest_tag = fetchLatestReleaseTag(io, gpa, arena, repo_api) orelse return null;
    const cur_raw = if (std.mem.startsWith(u8, harness_version, "v")) harness_version[1..] else harness_version;
    const latest_raw = if (std.mem.startsWith(u8, latest_tag, "v")) latest_tag[1..] else latest_tag;
    const cur = parseVersion(cur_raw) orelse return null;
    const latest = parseVersion(latest_raw) orelse return null;
    if (cur.order(latest) != .lt) return null;
    return std.fmt.allocPrint(arena, "graff v{s} is available (you have {s}) — graff update", .{ latest_raw, cur_raw }) catch null;
}

/// `graff update [--force|--check]` — bring the installed binary up to the
/// latest GitHub release. Checks the release tag first and skips when already
/// current (unless --force); --check only reports, never installs. The actual
/// download, codesign, and atomic binary swap are delegated to install.sh
/// (curl | sh) — that platform-specific logic already lives there, so we don't
/// reimplement it. HARNESS_NO_GRAFF=1 keeps the installer from also pulling in
/// the companion suite: an update touches only graff itself.
pub fn updateCommand(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    force: bool,
    check_only: bool,
) !void {
    const repo_api = "https://api.github.com/repos/justrach/codegraff/releases/latest";
    const install_url = environ.get("GRAFF_INSTALL_URL") orelse environ.get("HARNESS_INSTALL_URL") orelse
        "https://github.com/justrach/codegraff/releases/latest/download/install.sh";

    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    // current version, leading 'v' stripped so the comparison ignores tag style.
    const cur_raw = if (std.mem.startsWith(u8, harness_version, "v")) harness_version[1..] else harness_version;

    // A release tag is a bare "MAJOR.MINOR.PATCH". A dev/dirty/commit-ahead
    // build (from `git describe --tags --always --dirty`) carries a suffix
    // ("-3-gabc", "-dirty", "-dev+hash", "0.1.0-dev") and is NOT a clean
    // release version. Comparing such a string against a release tag with exact
    // equality always mismatched, so `graff update` would "update" (downgrade)
    // a newer dev build to an older release, and `--check` always reported an
    // update available. Parse the leading numeric triple instead, and refuse to
    // act on a non-release local build rather than silently downgrading it.
    const cur = parseVersion(cur_raw);
    const cur_is_release = cur != null and isCleanReleaseVersion(cur_raw);

    const latest_tag = fetchLatestReleaseTag(io, gpa, arena, repo_api);

    // `latest` is a release tag from GitHub, so it parses to a clean triple.
    const latest_raw = if (latest_tag) |tag| (if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag) else null;
    const latest = if (latest_raw) |r| parseVersion(r) else null;

    if (latest_tag != null and latest == null) {
        // The release endpoint returned a tag we couldn't parse — treat like a
        // failed check rather than guessing.
        if (check_only) std.process.fatal("update check failed — unparseable release tag '{s}'", .{latest_tag.?});
        try out.print("could not parse latest release tag '{s}'; running installer anyway…\n", .{latest_tag.?});
    } else if (latest != null) {
        const up_to_date = cur != null and cur.?.eql(latest.?);
        const cur_newer = cur != null and cur.?.order(latest.?) == .gt;

        if (check_only) {
            if (cur_is_release and up_to_date) {
                try out.print("graff is up to date (v{s})\n", .{cur_raw});
            } else if (cur_is_release and cur_newer) {
                try out.print("graff v{s} is newer than latest release v{s} — not downgrading\n", .{ cur_raw, latest_raw.? });
            } else if (cur_is_release) {
                // Release build older than latest.
                try out.print("update available: v{s} → v{s}  (run `graff update`)\n", .{ cur_raw, latest_raw.? });
            } else if (cur_newer) {
                // Dev/dirty build whose base version is ahead of the latest release.
                try out.print("local build v{s} is newer than latest release v{s} — not a release build; no update needed\n", .{ cur_raw, latest_raw.? });
            } else {
                // Dev/dirty build at or below the release version: installing the
                // release is reasonable if the user wants it.
                try out.print("update available: v{s} → v{s}  (local build {s} is not a release; run `graff update` to install the release)\n", .{ cur_raw, latest_raw.?, cur_raw });
            }
            try out.flush();
            return;
        }

        // Install path.
        if (up_to_date and cur_is_release and !force) {
            try out.print("graff is already up to date (v{s})\n", .{cur_raw});
            try out.flush();
            return;
        }
        // Refuse to downgrade a build whose version is strictly ahead of the
        // latest release without --force (applies to both release and dev builds
        // — installing would replace a newer version with an older one).
        if (cur_newer and !force) {
            try out.print("graff v{s} is newer than latest release v{s} — not downgrading (use --force to override)\n", .{ cur_raw, latest_raw.? });
            try out.flush();
            return;
        }
        try out.print("updating graff v{s} → v{s}…\n", .{ cur_raw, latest_raw.? });
    } else {
        // Version check failed (offline / rate-limited / bad response). For
        // --check that's a hard error; otherwise fall through to the installer,
        // which fetches the latest release on its own.
        if (check_only) std.process.fatal("update check failed — could not reach GitHub", .{});
        try out.writeAll("could not determine latest version; running installer anyway…\n");
    }
    try out.flush();

    // Delegate download/codesign/atomic swap to install.sh. Inherit our stdio
    // so its progress (and any sudo prompt) reaches the terminal directly.
    // "set -o pipefail" is required: without it, a failed "curl" is masked
    // by the right-hand "sh" exiting 0 on EOF, and the pipeline reports
    // success while installing nothing — silently.
    //
    // `install_url` is user-controllable via GRAFF_INSTALL_URL / HARNESS_INSTALL_URL,
    // so it MUST NOT be interpolated into the sh -c string (shell injection).
    // Pass it as positional $1 instead — the shell never re-parses it and curl
    // receives it verbatim.
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "set -o pipefail; curl -fsSL \"$1\" | HARNESS_NO_GRAFF=1 sh", "sh", install_url },
    }) catch |err|
        std.process.fatal("update: could not launch installer: {t}", .{err});
    const term = child.wait(io) catch std.process.fatal("update: installer did not exit cleanly", .{});
    if (term != .exited or term.exited != 0)
        std.process.fatal("update: installer failed — try again or download manually from https://github.com/justrach/codegraff/releases/latest", .{});
    try out.writeAll("✓ update installed — restart every running graff session to load the new binary\n");
    try out.flush();
}
