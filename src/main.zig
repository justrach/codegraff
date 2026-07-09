//! simple-harness — a minimal agentic loop, no SDK, no dependencies.
//!
//! Providers:
//!   * Anthropic Messages API   (model names starting with "claude")
//!   * OpenAI chat completions  (everything else, via the codegraff gateway)
//!
//! Tools come from three places, all dispatched through one uniform loop:
//!   * built-in:  bash, read_file, edit_file, write_file, subagent, workflow
//!   * meta:      todo_write, todo_read, ask_user, attempt_completion — act
//!                on the agent's own state, handled inline by the orchestrator
//!   * MCP:       any tool from a server listed in .mcp.json (see mcp.zig)
//!
//! The workflow tool is dynamic workflows as data: sequential phases of
//! parallel subagents, with {{prev}} carrying each phase's results forward.
//!
//! Bash runs behind a permission gate: unapproved commands prompt the user
//! (yes / always / no) at the root, subagents are limited to read-only and
//! user-approved commands, and /yolo turns the gate off.
//!
//! Every API round trip and tool execution is timed and appended as one JSON
//! line to harness.trace.jsonl (see Tracer) — the system prompt tells the
//! agent about the file, so it can debug and profile the harness, and
//! itself, from its own trace. /trace toggles it.
//!
//! "Every message is a tool" (strict mode, /strict): force a tool call every
//! turn (tool_choice) and make the final answer the attempt_completion tool,
//! so the loop is perfectly uniform — text never ends a turn.
//!
//! std.http.Client for HTTPS, std.json for both wire formats, the std.Io
//! thread pool (io.async) for parallel tool + subagent execution, and
//! client-side compaction when the conversation grows long.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const repl = @import("repl.zig");

const builtin = @import("builtin");

pub const anthropic_version = "2023-06-01";
const max_tokens = 16000;
pub const mcp_config_path = ".mcp.json";

// The terminal color palette lives in ansi.zig (a std-only leaf) so the
// spinner, streaming markdown renderer, and other UI code share one palette
// (#123). `style` is a pointer alias into ansi.style, so the ~200 `style.field`
// reads across this file auto-deref the live palette; main flips ansi.style to
// Style.ansi at startup once it confirms stdout is a TTY with color enabled.
const ansi = @import("ansi.zig");
const Style = ansi.Style;
const style = &ansi.style;
pub var use_color = false; // stdout is a TTY and NO_COLOR unset → enables color + markdown

// Optional displays toggled by CLI flags (--timing, --cost).
var show_timing = false;
var show_cost = false;
pub var json_mode = false; // --json: structured JSONL events on stdout instead of human text
var max_tool_calls: ?u64 = null; // --max-tool-calls: hard per-turn root tool budget
var dedupe_tool_calls = false; // --dedupe-tool-calls: reject duplicate root calls in a turn
var plan_mode = false; // /plan: read-only — mutating tools are denied, the model proposes
var unattended = false; // -p one-shot: no human to prompt; unapproved tool calls are denied

// Model pricing/catalog + the session cost tally live in pricing.zig (#123).
// Aliased here so the existing call sites read unchanged; later split slices
// can migrate call sites to `pricing.` and drop these.
const pricing = @import("pricing.zig");
const ModelPrice = pricing.ModelPrice;
const price_table = pricing.price_table;
const priceFor = pricing.priceFor;

// Pure shared helpers (JSON ObjectMap getters) live in util.zig (#123). Aliased
// so the ~50 existing strFieldObj/intFieldObj call sites stay unqualified.
const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const intFieldObj = util.intFieldObj;
const Billing = pricing.Billing;
const billingFor = pricing.billingFor;
const usdFor = pricing.usdFor;
const CostTally = pricing.CostTally;
const g_cost = &pricing.g_cost;
const ModelInfo = pricing.ModelInfo;
const codex_context_window = pricing.codex_context_window;
const model_table = pricing.model_table;
const default_context = pricing.default_context;
const contextFor = pricing.contextFor;
const normalizeModelAlias = pricing.normalizeModelAlias;
const modelAliasEquals = pricing.modelAliasEquals;
const resolveModelName = pricing.resolveModelName;
const modelInTable = pricing.modelInTable;
const providerModelInTable = pricing.providerModelInTable;

test {
    // build.zig's unit_tests root is main.zig only — reference split-out
    // modules here so their test blocks keep running (#123 watch-out).
    _ = pricing;
    _ = ansi;
    _ = serve;
    _ = util;
    _ = oauth;
    _ = anim;
    _ = approvals_mod;
    _ = hooks;
    _ = schema;
    _ = fleet;
    _ = messages_mod;
    _ = http;
    _ = terminal;
    _ = scoring;
    _ = telemetry;
    _ = trace;
    _ = cards;
    _ = jobs;
    _ = title_mod;
    _ = serde;
    _ = mcp_cli;
    _ = cli;
    _ = vision;
}

/// Wire format + auth style + endpoint per provider. Base URLs and env-var
/// names from models.dev/api.json (snapshot 2026-06-10); the anthropic and
/// openai bases are the canonical ones (models.dev lists them as null).
/// minimax serves the Anthropic Messages format with bearer auth. Order is
/// the default-provider priority at startup, and the tiebreak when one model
/// name is served by several providers.
const ProviderSpec = struct {
    id: []const u8,
    kind: Provider.Kind, // wire format
    auth: Provider.Auth, // header style
    url: []const u8,
    env_key: []const u8,
    default_model: []const u8,
};

pub const provider_specs = [_]ProviderSpec{
    .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "https://api.anthropic.com/v1/messages", .env_key = "ANTHROPIC_API_KEY", .default_model = "claude-opus-4-8" },
    .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "https://gateway.codegraff.com/v1/chat/completions", .env_key = "CODEGRAFF_API_KEY", .default_model = "deepseek-v4-pro" },
    .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "https://api.deepseek.com/chat/completions", .env_key = "DEEPSEEK_API_KEY", .default_model = "deepseek-v4-pro" },
    .{ .id = "openai", .kind = .openai, .auth = .bearer, .url = "https://api.openai.com/v1/chat/completions", .env_key = "OPENAI_API_KEY", .default_model = "gpt-5.5" },
    .{ .id = "minimax", .kind = .anthropic, .auth = .bearer, .url = "https://api.minimax.io/anthropic/v1/messages", .env_key = "MINIMAX_API_KEY", .default_model = "MiniMax-M3" },
    .{ .id = "xiaomi", .kind = .openai, .auth = .bearer, .url = "https://api.xiaomimimo.com/v1/chat/completions", .env_key = "XIAOMI_API_KEY", .default_model = "mimo-v2.5-pro" },
    // OpenAI-format direct providers (matched to graff's provider.json).
    .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "https://api.kimi.com/coding/v1/chat/completions", .env_key = "KIMI_API_KEY", .default_model = "kimi-k2.7" },
    // moonshot: the regular Kimi Open Platform (pay-as-you-go API key, not the
    // Coding plan). OpenAI-compatible; .cn host for China. kimi-latest tracks
    // the newest Kimi. Same /v1/models discovery applies if wired later.
    .{ .id = "moonshot", .kind = .openai, .auth = .bearer, .url = "https://api.moonshot.ai/v1/chat/completions", .env_key = "MOONSHOT_API_KEY", .default_model = "kimi-latest" },
    .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "https://api.x.ai/v1/chat/completions", .env_key = "XAI_API_KEY", .default_model = "grok-4.3" },
    .{ .id = "zai", .kind = .openai, .auth = .bearer, .url = "https://api.z.ai/api/paas/v4/chat/completions", .env_key = "ZAI_API_KEY", .default_model = "glm-5.2" },
    .{ .id = "fugu", .kind = .openai, .auth = .bearer, .url = "https://api.sakana.ai/v1/chat/completions", .env_key = "FUGU_API_KEY", .default_model = "fugu-ultra" },
    .{ .id = "fireworks", .kind = .openai, .auth = .bearer, .url = "https://api.fireworks.ai/inference/v1/chat/completions", .env_key = "FIREWORKS_API_KEY", .default_model = "accounts/fireworks/models/deepseek-v4-pro" },
    // mlx: a local model served by mlx-lm (`mlx_lm.server`) on Apple Silicon —
    // OpenAI-compatible, no real key (MLX_API_KEY=local just clears graff's boot gate).
    .{ .id = "mlx", .kind = .openai, .auth = .bearer, .url = "http://127.0.0.1:8080/v1/chat/completions", .env_key = "MLX_API_KEY", .default_model = "mlx-community/Qwen3.6-27B-OptiQ-4bit" },
    // lm-studio: the LM Studio app's local OpenAI-compatible server (default :1234).
    // Load a model in LM Studio, then `LMSTUDIO_API_KEY=local graff --model lmstudio`.
    .{ .id = "lmstudio", .kind = .openai, .auth = .bearer, .url = "http://127.0.0.1:1234/v1/chat/completions", .env_key = "LMSTUDIO_API_KEY", .default_model = "lmstudio" },
    // codex: ChatGPT login via the Responses API. Its "key" isn't an env var
    // — it's the OAuth access token read from ~/.codex/auth.json at startup
    // (see loadCodexAuth), the same on-disk-credential trick used for the
    // codegraff gateway key in ~/forge/.credentials.json.
    .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://chatgpt.com/backend-api/codex/responses", .env_key = "CODEX_DISABLED", .default_model = "gpt-5.5" },
};

const main_system_prompt =
    \\You are a coding agent running in a minimal terminal harness on the
    \\user's machine. Use the provided tools to inspect and modify the current
    \\working directory and to run commands. read_file before editing; prefer
    \\edit_file for changes to existing files and write_file only for new
    \\files or full rewrites. To navigate code — finding symbols, callers,
    \\definitions, or where logic lives — prefer the codedb tool (it's indexed
    \\and structural) over bash grep/find/ls. Some bash commands need user approval — if one
    \\is declined, try another approach or ask. For independent,
    \\self-contained chunks of work — exploring several directories, running
    \\unrelated checks, summarizing multiple files — fan out: call the
    \\subagent tool several times in a single response and the subagents run
    \\in parallel. For larger fan-out work that needs a synthesis step, use
    \\the workflow tool: sequential phases of parallel subagents, with
    \\{{prev}} carrying each phase's results into the next. Use todo_write to
    \\track multi-step work. Work directly for small sequential steps.
    \\
    \\The harness writes a JSONL event trace of this session to
    \\harness.trace.jsonl in the working directory: one object per line with
    \\"ev" of "api" (model round trips: ms latency, request/response bytes,
    \\context_tokens) or "tool" (tool executions: name, ms, result bytes,
    \\errors), and "t" = ms since session start. When asked to debug, profile,
    \\or explain the harness's own behavior — including your own — read that
    \\file and analyze it.
    \\
    \\If you hit a bug or limitation in the harness itself (this graff/codegraff
    \\agent — its tools, prompts, streaming, sessions, or behavior — as opposed
    \\to the project you happen to be working in), report it by opening a GitHub
    \\issue at justrach/codegraff (`gh issue create --repo justrach/codegraff
    \\...`), never in the current working repository's issue tracker.
    \\
    \\When making git commits on behalf of the user, always set the author
    \\to Codegraff <blackfloofie@codegraff.com> — pass GIT_AUTHOR_NAME,
    \\GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, and GIT_COMMITTER_EMAIL env vars
    \\on every git command so the bot identity is preserved in the commit log.
    \\
    \\Never run git commands that discard work — `reset --hard`, `clean -f`,
    \\`checkout --`/`restore`, force-push, or `branch -D` — unless the user
    \\explicitly asks. Their existing commits and any -w worktree
    \\auto-checkpoints are the user's safety net; do not blow them away.
    \\
    \\Be direct and concise.
;

const strict_note =
    \\
    \\
    \\STRICT MODE: Respond ONLY by calling exactly one tool per message — never
    \\reply with plain prose. When the task is fully complete, call
    \\attempt_completion with your final answer in the "result" field.
;

const main_system_prompt_strict = main_system_prompt ++ strict_note;

const sub_system_prompt =
    \\You are a subagent spawned by an orchestrator agent inside a terminal
    \\harness. Complete the assigned task using your tools, without asking
    \\questions — make reasonable assumptions. Your final message is returned
    \\verbatim to the orchestrator as the result of the task: make it a
    \\concise, complete report with the concrete facts you found.
;

const compact_instruction =
    \\Summarize this entire conversation for a context handoff. Capture: the
    \\user's goals, all important facts and decisions, file paths and code
    \\that was created or modified, command results that matter, and any
    \\pending or unfinished work. Be thorough but compact. Reply with only
    \\the summary.
;

// -------------------------------------------------------------------------
// Tool-schema + provider-tool JSON emission (the ToolSpec catalog, per-provider
// tool renderers, and emitSchema) lives in schema.zig (#123). Aliased back so
// the existing call sites stay unqualified; emitSchema + schema_version are
// re-exported (pub) for serve.zig's back-import.
const schema = @import("schema.zig");
const renderRootTools = schema.renderRootTools;
const root_specs = schema.root_specs;
const isMetaName = schema.isMetaName;
const tools_anthropic_sub = schema.tools_anthropic_sub;
const tools_openai_sub = schema.tools_openai_sub;
const tools_responses_sub = schema.tools_responses_sub;
const providerTakesEffort = schema.providerTakesEffort;
pub const emitSchema = schema.emitSchema;
pub const schema_version = schema.schema_version;
// -------------------------------------------------------------------------

pub const Provider = struct {
    id: []const u8,
    kind: Kind,
    auth: Auth,
    url: []const u8,
    api_key: []const u8,
    model: []const u8,
    context: u64,
    account: []const u8 = "", // ChatGPT account id, codex/responses only

    // Wire format. `responses` is the OpenAI Responses API as served by the
    // ChatGPT backend (Codex login) — input items, not chat messages.
    pub const Kind = enum { anthropic, openai, responses };
    pub const Auth = enum { x_api_key, bearer };

    /// Auto-compact past 80% of the model's context window.
    fn compactAt(p: Provider) u64 {
        return p.context / 10 * 8;
    }
};

/// One optional API key per provider_specs entry, read from the environment.
const Keys = struct {
    values: [provider_specs.len]?[]const u8,
    codex_account: []const u8 = "", // ChatGPT account id for the codex provider

    pub fn get(keys: Keys, provider_id: []const u8) ?[]const u8 {
        for (provider_specs, keys.values) |spec, value| {
            if (std.mem.eql(u8, spec.id, provider_id)) return value;
        }
        return null;
    }

    fn build(keys: Keys, spec: ProviderSpec, key: []const u8, model: []const u8) Provider {
        return .{
            .id = spec.id,
            .kind = spec.kind,
            .auth = spec.auth,
            .url = spec.url,
            .api_key = key,
            .model = model,
            .context = contextFor(spec.id, model),
            .account = if (std.mem.eql(u8, spec.id, "codex")) keys.codex_account else "",
        };
    }

    /// Route a model to a provider: first model_table row whose provider has
    /// a key wins (spec order breaks ties). Unknown claude* models go to
    /// Anthropic; any other unknown model goes to the codegraff gateway.
    fn providerFor(keys: Keys, model: []const u8) error{MissingKey}!Provider {
        // Prefer a direct provider the user keyed over the codegraff gateway: the
        // gateway proxies almost every model, so a low gateway balance would
        // otherwise block models the user can serve with their own key. Pass 1
        // skips the gateway (direct keys win); pass 2 lets it back in as fallback.
        for ([_]bool{ false, true }) |allow_gateway| {
            for (provider_specs, keys.values) |spec, value| {
                const key = value orelse continue;
                if (std.mem.eql(u8, spec.id, "codegraff") != allow_gateway) continue;
                for (model_table) |m| {
                    if (std.mem.eql(u8, m.provider, spec.id) and std.mem.eql(u8, m.name, model))
                        return keys.build(spec, key, model);
                }
            }
        }
        const fallback_id: []const u8 = if (std.mem.startsWith(u8, model, "claude")) "anthropic" else "codegraff";
        for (provider_specs, keys.values) |spec, value| {
            if (!std.mem.eql(u8, spec.id, fallback_id)) continue;
            const key = value orelse break;
            return keys.build(spec, key, model);
        }
        return error.MissingKey;
    }

    /// The startup default: the first provider (in spec order) with a key,
    /// on its default model.
    fn defaultProvider(keys: Keys) error{MissingKey}!Provider {
        for (provider_specs, keys.values) |spec, value| {
            const key = value orelse continue;
            return keys.build(spec, key, spec.default_model);
        }
        return error.MissingKey;
    }

    /// Rebuild a provider from a saved session's (id, model). Falls back to
    /// model-based routing if the id is unknown.
    fn providerById(keys: Keys, id: []const u8, model: []const u8) error{MissingKey}!Provider {
        for (provider_specs, keys.values) |spec, value| {
            if (!std.mem.eql(u8, spec.id, id)) continue;
            const key = value orelse return error.MissingKey;
            return keys.build(spec, key, model);
        }
        return keys.providerFor(model);
    }
};

// Approvals (command/tool approval gate) + confinedPath/noSymlinkEscape live in
// approvals.zig (#123). Re-exported here so `Approvals.*`, the two path-gate
// helpers, and anim.zig's `root.Approvals` back-import resolve unchanged.
const approvals_mod = @import("approvals.zig");
pub const Approvals = approvals_mod.Approvals;
const confinedPath = approvals_mod.confinedPath;
const noSymlinkEscape = approvals_mod.noSymlinkEscape;

// Session tracing (harness.trace.jsonl Tracer) + the DGM trajectory archive
// (harness.trajectory.jsonl Trajectory) + the per-line JSON writer live in
// trace.zig (600-line goal). Types aliased back; trajectory_path re-exported
// (fleet.zig back-imports it); the session trajectory pointer is trace.-qualified.
const trace = @import("trace.zig");
pub const Tracer = trace.Tracer;
pub const Trajectory = trace.Trajectory;
pub const trajectory_path = trace.trajectory_path;
pub const ToolSink = trace.ToolSink;
const trace_path = trace.trace_path;

// ── Agent types / fleet (MAP-Elites niches) ───────────────────────────
// The AgentType niche registry, the backgrounded elite pull, /agents promote,
// and the niche/override resolvers live in fleet.zig (#123). The functions are
// aliased back so call sites stay unqualified; the session agent-type globals
// (the session agent-type state) moved with it and are
// reached fleet.-qualified.
const fleet = @import("fleet.zig");
const loadAgentTypes = fleet.loadAgentTypes;
const promoteAgents = fleet.promoteAgents;
const agentTypePrompt = fleet.agentTypePrompt;
const pullElites = fleet.pullElites;
const joinElites = fleet.joinElites;
const resolveOverride = fleet.resolveOverride;
const resolveNiche = fleet.resolveNiche;

// Prompt/provider-class fingerprinting + DGM score signing live in scoring.zig
// (600-line goal). Pure fns aliased back; the signing globals are
// scoring.-qualified at their call sites.
const scoring = @import("scoring.zig");
const promptFingerprint = scoring.promptFingerprint;
const providerClass = scoring.providerClass;
const scoreSigMessage = scoring.scoreSigMessage;
const signScore = scoring.signScore;
const loadScoreKey = scoring.loadScoreKey;

// ── Subagent cards (#51) ────────────────────────────────────────
// The parallel-subagent launch/done cards + box helpers + the inspect-report
// writer live in cards.zig (600-line goal). Renderers aliased back; the
// subagent-ordinal counter is reached cards.-qualified.
const cards = @import("cards.zig");
const subagentSprite = cards.subagentSprite;
const subagentId = cards.subagentId;
const subagentLaunchCard = cards.subagentLaunchCard;
const subagentDoneCard = cards.subagentDoneCard;
const writeSubagentDetail = cards.writeSubagentDetail;

// Score-channel signing (DGM fitness integrity) + the session signing globals
// live in scoring.zig (600-line goal); reached scoring.-qualified.

// ToolSink (the per-agent tool-call log) lives in trace.zig (600-line goal).

/// Largest prefix of `s` up to `max` bytes that doesn't split a UTF-8
/// codepoint (std.json would otherwise serialize the slice as an int array).
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var p = s[0..max];
    var strips: usize = 0;
    while (strips < 3 and p.len > 0 and !std.unicode.utf8ValidateSlice(p)) : (strips += 1)
        p = p[0 .. p.len - 1];
    return p;
}

// ── Telemetry (OTEL) ───────────────────────────────────────────
// The Telemetry sink + its session-global pointer live in telemetry.zig
// (600-line goal). Telemetry is re-exported (fleet.zig back-imports it); the
// sink pointer is reached telemetry.-qualified at its call sites.
const telemetry = @import("telemetry.zig");
pub const Telemetry = telemetry.Telemetry;

/// Federated-fleet contribution toggle (docs/hyperagents.md §9). On by default;
/// GRAFF_FLEET=off or /fleet off disables propose/submit/elite_pull. General
/// usage telemetry is separate (GRAFF_NO_TELEMETRY).
pub var g_fleet: bool = true;

/// Wall-clock unix milliseconds (OTLP timestamps need real time; the
/// harness otherwise only uses the monotonic Io clock).
pub fn unixMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
}

/// Load (or create on first run) a 32-hex-char anonymous id at ~/<fname>.
/// All-zero id when HOME is missing or the file can't be created.
fn loadOrCreateId(io: Io, gpa: Allocator, home: []const u8, fname: []const u8) [32]u8 {
    var id: [32]u8 = @splat('0');
    if (home.len == 0) return id;
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ home, fname }) catch return id;
    existing: {
        const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch break :existing;
        defer gpa.free(data);
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len != 32) break :existing;
        for (trimmed) |c| switch (c) { // lowercase hex only, like the writer
            '0'...'9', 'a'...'f' => {},
            else => break :existing,
        };
        @memcpy(&id, trimmed);
        return id;
    }
    var raw: [16]u8 = undefined;
    io.random(&raw);
    id = std.fmt.bytesToHex(raw, .lower);
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return id;
    defer f.close(io);
    var wbuf: [64]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.print("{s}\n", .{&id}) catch return id;
    fw.interface.flush() catch return id;
    return id;
}

/// Reasoning depth for codex/responses (OpenAI Responses `reasoning.effort`).
const ReasoningEffort = enum { low, medium, high };

const repl_commands = [_][]const u8{ "/model", "/models", "/clear", "/new", "/rename", "/goal", "/loop", "/bash", "/plan", "/key", "/keepcontext", "/effort", "/fast", "/ultracode", "/thinking", "/title", "/reasoning", "/strict", "/yolo", "/trace", "/fleet", "/trajectory", "/agents", "/skills", "/hooks", "/compact", "/rewind", "/image", "/paste", "/save", "/resume", "/sessions", "/todo", "/jobs", "/cost", "/animation", "/theme", "/mcp", "/help" };

/// REPL slash commands share the leading `/` with absolute POSIX paths. Only
/// treat the line as command syntax when the first token is command-shaped;
/// `/System/Library/... explain this` should be sent to the model as a prompt,
/// not rejected as an unknown slash command.
fn isSlashCommandLine(line: []const u8) bool {
    if (line.len == 0 or line[0] != '/') return false;
    if (line.len == 1) return true; // bare `/` opens the command picker

    const token_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const token = line[0..token_end];
    // Absolute paths with more than one component are prompts/attachments.
    if (token.len > 1 and std.mem.indexOfScalar(u8, token[1..], '/') != null) return false;

    return true;
}

// Lifecycle hooks (Hook/Hooks config types + settings loader + per-hook
// subprocess runner) live in hooks.zig (#123). g_hooks below, the
// pre/post/turn-end dispatch, and the codedb-guard file-index cache stay here.
const hooks = @import("hooks.zig");

var g_hooks: hooks.Hooks = .{};

/// Built-in codedb guard (issue #626): when a repo is codedb-indexed, agents
/// reflexively grep/sed/cat source files and never touch the structural tools,
/// so codedb degrades to "ripgrep with smaller output." When on, a bash command
/// that scans/reads a concrete source file is blocked with a redirect to the
/// codedb tool. Off when GRAFF_NO_CODEDB_GUARD is set; the tri-state cache
/// records whether `codedb` is actually on PATH (no redirect if it isn't).
var g_codedb_guard = true;
var g_codedb_present: ?bool = null;

/// Per-file cache for the codedb guard: `codedb outline <path>` is run once
/// per source file to check whether codedb actually indexed it (large files
/// are silently skipped — e.g. a 13K-line main.zig). Entries are page-alloc
/// and never freed; the set is small (only files the agent greps). A mutex
/// guards concurrent tool-thread access; a miss is benign (duplicate probe).
const CodedbFileCheck = struct { path: []const u8, indexed: bool };
var g_codedb_file_checks: std.ArrayList(CodedbFileCheck) = .empty;
var g_codedb_file_mu: Io.Mutex = .init;

/// True when `path` is in codedb's symbol index. Runs `codedb outline <path>`
/// (cached): returns "not indexed: <path>" when the file is too large or
/// otherwise skipped, so the guard knows to let bash through instead of
/// trapping the agent between a blocked grep and an empty codedb result.
fn codedbFileIndexed(io: Io, gpa: Allocator, path: []const u8) bool {
    g_codedb_file_mu.lockUncancelable(io);
    for (g_codedb_file_checks.items) |e| {
        if (std.mem.eql(u8, e.path, path)) {
            g_codedb_file_mu.unlock(io);
            return e.indexed;
        }
    }
    g_codedb_file_mu.unlock(io);
    // Cache miss: probe once, then store. On error, assume indexed (safe:
    // the guard still redirects to codedb, which is the status-quo behavior).
    const run = runCapped(gpa, io, &.{ "codedb", "outline", path }, 512, 256, 0) catch return true;
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    const not_indexed = std.mem.indexOf(u8, run.stdout, "not indexed") != null or
        std.mem.indexOf(u8, run.stderr, "not indexed") != null;
    const result: bool = !not_indexed;
    g_codedb_file_mu.lockUncancelable(io);
    defer g_codedb_file_mu.unlock(io);
    const dup = gpa.dupe(u8, path) catch return result;
    g_codedb_file_checks.append(gpa, .{ .path = dup, .indexed = result }) catch gpa.free(dup);
    return result;
}

/// Codex-style optional skills: known companion tools the harness quietly
/// upgrades itself with when they're installed. Progressive disclosure, same
/// shape as codex SKILL.md metadata: the `note` is the only thing that ever
/// enters the model's context (one line, injected at startup when the bins
/// are on PATH); the tool's own --help is the on-demand body. `/skills`
/// lists them with install status; `/skills add <name>` runs the installer.
const SkillDef = struct {
    name: []const u8,
    desc: []const u8,
    bins: []const []const u8, // every one must resolve on PATH to count as installed
    install: []const u8, // shell one-liner run by `/skills add <name>`
    note: []const u8, // system-prompt line when installed ("" = covered elsewhere)
};
const skills_registry = [_]SkillDef{
    .{
        .name = "graff",
        .desc = "code-intelligence suite — codedb-pro edits/search, zigrep, codedb index; edit_file upgrades to atomic zigpatch splices",
        .bins = &.{ "zigpatch", "codedb-pro" },
        .install = "curl -fsSL https://codegraff.com/install-graff.sh | sh",
        .note = "", // the codedb tool description + zigpatch delegation already cover it
    },
    .{
        .name = "kuri",
        .desc = "browser automation, web crawling, iOS/Android device control (github.com/justrach/kuri)",
        .bins = &.{"kuri"},
        .install = "curl -fsSL https://raw.githubusercontent.com/justrach/kuri/main/install.sh | sh",
        .note = "The `kuri` CLI is installed (browser automation, HAR capture, iOS/Android device control) — prefer it via bash for browser and device tasks; run `kuri --help` once to see subcommands before using it. Plain page fetching is already covered: the webfetch tool uses kuri-fetch under the hood.",
    },
};

/// System-prompt notes for known MCP servers (the MCP twin of skill notes):
/// one line injected at startup when the server is actually connected, so the
/// model knows when to reach for its tools. The native tools stay registered
/// regardless — they are the fallback whenever an MCP call fails, is denied,
/// or the server is disconnected/skipped.
/// Licensed-aware variant of the codedbpro note. When `codedb-pro probe`
/// succeeds (paid + usable) we inject THIS instead of the conservative
/// "prefer free codedb" note below — leaning into the tools the user pays for.
/// Edits still stay native: edit_file/write_file are /rewind-snapshotted and
/// already splice via zigpatch, whereas codedb-pro edit/patch/replace bypass /rewind.
const codedbpro_note_licensed = "The codedb-pro MCP server is connected and LICENSED (mcp__codedbpro__* tools) — prefer it, you are paying for it. Use mcp__codedbpro__read (mode=outline first, then symbol/lines) instead of read_file for navigating code, mcp__codedbpro__faster_search / meta_search for content and fuzzy search (the native codedb tool stays a fine fast path for indexed symbol/outline/callers/find lookups), and mcp__codedbpro__batch to run several independent reads/searches in one round-trip. KEEP EDITS on the native edit_file/write_file tools — they are snapshot-tracked for /rewind and already splice via zigpatch; codedb-pro edit/patch/replace bypass /rewind, so do not route edits through it. Whenever an mcp__codedbpro__ call fails, fall back to read_file/codedb/bash.";

const McpNote = struct { server: []const u8, note: []const u8 };
const mcp_notes = [_]McpNote{
    .{
        .server = "codedbpro",
        .note = "The codedb-pro MCP server is connected (mcp__codedbpro__* tools). SEARCH ORDER: the native codedb tool is free and indexed — always try it first for code search (search/symbol/callers/outline/find); reach for mcp__codedbpro__faster_search or meta_search only when codedb can't answer (raw literal/regex content matches, fuzzy queries, non-indexed files) — codedb-pro is metered. Prefer mcp__codedbpro__read (mode=outline first, then symbol) over read_file for navigating large code files, and mcp__codedbpro__batch to run several independent reads/searches/edits in one round-trip. Keep edits on the native edit_file/write_file tools (they are snapshot-tracked for /rewind). These tools are accelerators, not requirements: whenever an mcp__codedbpro__ call fails or is unavailable, fall back to read_file/codedb/bash and continue.",
    },
    .{
        .server = "muonry",
        .note = "The muonry MCP server is connected (mcp__muonry__* tools). SEARCH ORDER: the native codedb tool is free and indexed — always try it first for code search (search/symbol/callers/outline/find); use mcp__muonry__search or faster_search only when codedb can't answer (raw literal/regex content matches, non-code or non-indexed files) — muonry is metered. Prefer mcp__muonry__read (mode=outline first, then symbol) over read_file for navigating large code files, and mcp__muonry__batch to run several independent reads/searches in one round-trip. Keep edits on the native edit_file/write_file tools (they are snapshot-tracked for /rewind). These tools are accelerators, not requirements: whenever an mcp__muonry__ call fails or is unavailable, fall back to read_file/codedb/bash and continue.",
    },
};

/// The metered code-intelligence companion. It first shipped as `muonry` and
/// was renamed to `codedb-pro`; both run as an MCP server (`<bin> --mcp`) and
/// expose the same tool surface. We auto-connect the first one present and
/// trust it like the native tools. Server names match the qualified tool
/// prefix the model sees (mcp__<server>__*); listed in preference order.
const CompanionServer = struct { server: []const u8, bin: []const u8 };
pub const companion_servers = [_]CompanionServer{
    .{ .server = "codedbpro", .bin = "codedb-pro" },
    .{ .server = "muonry", .bin = "muonry" }, // legacy name, same suite
};

/// Read-only tool names on the companion server, mirroring its own
/// readOnlyHint annotations.
const companion_readonly_tools = [_][]const u8{ "read", "search", "faster_search", "meta_search", "diff", "lint" };

fn companionToolReadOnly(t: []const u8) bool {
    for (companion_readonly_tools) |ok| if (std.mem.eql(u8, t, ok)) return true;
    return false;
}

/// Strip the companion's `mcp__<server>__` prefix, returning the bare tool
/// name — or null when the call isn't a companion tool at all.
fn companionToolName(tool: []const u8) ?[]const u8 {
    inline for (companion_servers) |c| {
        const prefix = "mcp__" ++ c.server ++ "__";
        if (std.mem.startsWith(u8, tool, prefix)) return tool[prefix.len..];
    }
    return null;
}

/// Every companion call skips the approval gate — the suite (codedb-pro/muonry,
/// zigpatch, zigrep, codedb) is a user-installed trusted companion, same
/// standing as the native read_file/edit_file tools, which never prompt.
fn companionTrusted(tool: []const u8) bool {
    return companionToolName(tool) != null;
}

/// Is this companion call read-only? Decides what it may do in PLAN MODE
/// (read-only by mode semantics — native edit_file is blocked there too,
/// trust notwithstanding). Mirrors the server's readOnlyHint annotations;
/// batch is read-only iff every op inside it is.
fn companionReadOnly(tool: []const u8, input: Value) bool {
    const t = companionToolName(tool) orelse return false;
    if (companionToolReadOnly(t)) return true;
    if (!std.mem.eql(u8, t, "batch")) return false;
    if (input != .object) return false;
    const ops = input.object.get("ops") orelse return false;
    if (ops != .array or ops.array.items.len == 0) return false;
    for (ops.array.items) |op| {
        if (op != .object) return false;
        const name = op.object.get("tool") orelse return false;
        if (name != .string or !companionToolReadOnly(name.string)) return false;
    }
    return true;
}

/// True when any discovered MCP tool belongs to `server` (qualified names
/// are "mcp__<server>__<tool>").
fn mcpServerConnected(tools: []const mcp.Tool, server: []const u8) bool {
    var buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "mcp__{s}__", .{server}) catch return false;
    for (tools) |t| if (std.mem.startsWith(u8, t.qualified_name, prefix)) return true;
    return false;
}

/// PATH captured at startup for skill detection (PATH won't change mid-run).
var g_path_env: []const u8 = "";
/// Human-facing current workspace folder shown in the REPL prompt.
var g_cwd_display: []const u8 = ".";
pub var g_worktree_branch: ?[]const u8 = null; // -w: the worktree's scratch branch; non-null = auto-commit each turn's edits to it
pub var g_worktree_autocommit: bool = true; // --no-autocommit turns off the per-turn checkpoint commits

/// Short task label for terminal/TUI headers. Mirrors the GUI's first-prompt
/// fallback: use the user's first message as a compact tab/session title.
// Session-title + header rendering + provider-response text parsers live in
// title.zig (600-line goal). All 9 helpers aliased back so call sites (incl.
// the Agent-coupled titleTask below) stay unqualified.
const title_mod = @import("title.zig");
const titleFromPrompt = title_mod.titleFromPrompt;
const folderBasename = title_mod.folderBasename;
const firstUserTitle = title_mod.firstUserTitle;
const setTerminalTitle = title_mod.setTerminalTitle;
const printSessionHeader = title_mod.printSessionHeader;
const reasoningDelta = title_mod.reasoningDelta;
const assistantText = title_mod.assistantText;
const stripWrappingQuotes = title_mod.stripWrappingQuotes;
const cleanTitle = title_mod.cleanTitle;

/// Generate a terse tab-label title for the turn's first prompt — runs on its
/// own arena + a throwaway one-message sub-Agent, so it can be spawned via
/// io.async and overlap the real turn instead of blocking after it. Returns a
/// gpa-owned title (caller frees), or null on any failure.
fn titleTask(gpa: Allocator, io: Io, client: *std.http.Client, provider: Provider, prompt: []const u8) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = client,
        .provider = provider,
        .messages = std.json.Array.init(arena),
        .sub = true, // pool thread: never touches stdout or the main agent's state
        .label = "title",
        .out = null,
        .sys_override = "You summarize what a coding session is about in a short, natural phrase. Reply with only the phrase.",
    };
    defer agent.tools_used.deinit(gpa);
    const instr = std.fmt.allocPrint(arena, "In a short natural phrase (about 3-8 words, sentence case, no quotes, no period), say what the user is working on — e.g. 'defining what a dragon is', 'fixing the login bug', 'planning the release'. Reply with ONLY the phrase.\n\nTask:\n{s}", .{prompt}) catch return null;
    agent.messages.append(textMessage(arena, "user", instr) catch return null) catch return null;
    const root = agent.request(null) catch return null;
    const cleaned = cleanTitle(assistantText(provider.kind, root)) orelse return null;
    return gpa.dupe(u8, cleaned) catch null;
}

/// Opaque context handed to repl.run so the REPL can run a real agent turn —
/// reuses the root agent's tool set, MCP registry, and system prompt (built in
/// main()). No harness internals leak into repl.zig; it only sees a callback.
const ReplCtx = struct {
    io: Io,
    client: *std.http.Client,
    provider: Provider,
    registry: ?*mcp.Registry,
    sys_normal: []const u8,
    tools_anthropic: []const u8,
    tools_openai: []const u8,
    tools_responses: []const u8,
};

/// A thread-safe sink the worker writes the agent's output to and the repl's
/// render loop polls — this is what makes `graff repl` stream live. Custom
/// Io.Writer whose drain appends (under the StreamBuf mutex) to the repl buffer.
const ReplStreamSink = struct {
    target: *repl.StreamBuf,
    buf: [4096]u8 = undefined,
    writer: Io.Writer = undefined,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn init(self: *ReplStreamSink, target: *repl.StreamBuf) void {
        self.target = target;
        self.writer = .{ .vtable = &vtable, .buffer = &self.buf, .end = 0 };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ReplStreamSink = @alignCast(@fieldParentPtr("writer", w));
        self.target.appendBytes(w.buffer[0..w.end]);
        w.end = 0;
        const slices = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var written: usize = 0;
        for (slices) |b| {
            self.target.appendBytes(b);
            written += b.len;
        }
        var i: usize = 0;
        while (i < splat) : (i += 1) self.target.appendBytes(pattern);
        written += pattern.len * splat;
        return written;
    }
};

/// The standing-goal steering note appended to each turn when /goal is set: the
/// objective, an instruction to track it as a todo_write checklist, and the
/// current checklist render when one exists. Returns "" when goal is null so the
/// caller can skip the append. Pass todos_render="" when there are no todos — do
/// NOT pass renderTodos()'s "(no todos)" placeholder, which would leak into the prompt.
fn goalSteeringNote(arena: Allocator, goal: ?[]const u8, todos_render: []const u8) ![]const u8 {
    const g = goal orelse return "";
    const progress: []const u8 = if (todos_render.len > 0)
        try std.fmt.allocPrint(arena, "\n\nChecklist so far:\n{s}", .{todos_render})
    else
        "";
    return std.fmt.allocPrint(arena, "[standing goal: {s} - track this as a todo_write checklist and work through it, marking each item in_progress when you start and completed when done.]{s}", .{ g, progress });
}

/// Extract a 0-100 score from an eval command's output: a `score` key (JSON or
/// key=val) if present, else the last numeric line. Values in [0,1] are read as
/// fractions and scaled to 0-100.
fn parseEvalScore(out: []const u8) ?f64 {
    if (std.mem.indexOf(u8, out, "score")) |i| {
        var j = i + 5;
        while (j < out.len and out[j] != ':' and out[j] != '=' and out[j] != '\n') j += 1;
        if (j < out.len and (out[j] == ':' or out[j] == '=')) {
            j += 1;
            while (j < out.len and (out[j] == ' ' or out[j] == '\t' or out[j] == '"')) j += 1;
            if (parseLeadingNumber(out[j..])) |v| return normalizeScore(v);
        }
    }
    const trimmed = std.mem.trimEnd(u8, out, " \t\r\n");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |k| trimmed[k + 1 ..] else trimmed;
    if (parseLeadingNumber(std.mem.trim(u8, last, " \t\r\n"))) |v| return normalizeScore(v);
    return null;
}

fn parseLeadingNumber(s: []const u8) ?f64 {
    var end: usize = 0;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.' or s[end] == '-' or s[end] == '+')) end += 1;
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, s[0..end]) catch null;
}

fn normalizeScore(v: f64) f64 {
    if (v >= 0.0 and v <= 1.0) return v * 100.0;
    return v;
}

/// Steering injected each turn when --eval is set: the eval-driven loop
/// discipline (score -> one focused change -> re-score -> log -> stop at
/// target). Returns "" when no eval command is configured.
fn evalSteeringNote(arena: Allocator, eval_cmd: ?[]const u8, target: u8, has_judge: bool) ![]const u8 {
    if (eval_cmd == null) return "";
    const gate = if (has_judge)
        " An LLM judge is also configured, so the target is met only when BOTH the deterministic score AND the judge score reach it - read both numbers the `eval` tool reports."
    else
        "";
    return std.fmt.allocPrint(arena, "[eval-driven loop active. A scoring command is configured. Work it as a scored improvement loop: (1) call the `eval` tool to score the current state - the harness runs the command and logs to .graff/eval-log.tsv, so do NOT run it yourself via bash; (2) read the score, best-so-far, and output; (3) find the SINGLE biggest failure (inspect any artifacts or images directly); (4) make ONE focused change targeting it; (5) call `eval` again. Continue until `eval` reports the target ({d}/100) is met.{s} Do not stop at the first passing result, and do not revert unless `eval` shows a clear regression. After each `eval`, briefly note what you changed.]", .{ target, gate });
}

test "goalSteeringNote: goal + checklist assembly, no (no todos) leak" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // No goal -> empty note, caller skips the append.
    try std.testing.expectEqualStrings("", try goalSteeringNote(ar, null, ""));

    // Goal, no todos -> bracket note, no checklist, and never the "(no todos)" placeholder.
    const n1 = try goalSteeringNote(ar, "close all issues", "");
    try std.testing.expect(std.mem.startsWith(u8, n1, "[standing goal: close all issues - track this as a todo_write checklist"));
    try std.testing.expect(std.mem.indexOf(u8, n1, "Checklist so far") == null);
    try std.testing.expect(std.mem.indexOf(u8, n1, "(no todos)") == null);

    // Goal + live todos -> the rendered checklist is appended verbatim.
    const n2 = try goalSteeringNote(ar, "ship 0.0.177", "[x] wire steering\n[ ] add test");
    try std.testing.expect(std.mem.indexOf(u8, n2, "Checklist so far:\n[x] wire steering\n[ ] add test") != null);
}

/// repl.TurnFn — run a full ROOT agent turn (tools + MCP) for `graff repl`, so
/// the model can read files, run bash, search the codebase, etc. — not a bare
/// completion. Auto-approves tools (yolo: the chat repl has no permission UI),
/// in=null (never blocks on a prompt). Output streams into a thread-safe sink
/// the repl polls to render live; the clean final text is runTurn's return
/// value. Returns the final assistant text (raw markdown, owned by gpa) or null.
fn replTurnCb(ctx_ptr: ?*anyopaque, gpa: Allocator, history: []const repl.Turn, params: repl.Params, stream: *repl.StreamBuf) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sink: ReplStreamSink = undefined;
    sink.init(stream); // agent output streams into the repl's live pane (thread-safe)
    var approvals: Approvals = .{ .yolo = true };
    const sys = if (params.goal.len > 0)
        (std.fmt.allocPrint(arena, "{s}\n\n# Standing goal (from the user)\n{s}\n\nTrack this as a todo_write checklist and work through it across turns - mark each item in_progress when you start and completed when done. Keep the list current; don't repeat finished items.", .{ c.sys_normal, params.goal }) catch c.sys_normal)
    else
        c.sys_normal;
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = c.io,
        .client = c.client,
        .provider = c.provider,
        .messages = std.json.Array.init(arena),
        .sub = false, // root: enables the full tool set + agentic loop
        .label = "repl",
        .out = &sink.writer,
        .in = null, // never prompt for tool approval / ask_user
        .stream_quiet = false, // stream tokens live into the repl pane
        .registry = c.registry,
        .approvals = &approvals,
        .sys_normal = sys,
        .tools_anthropic = c.tools_anthropic,
        .tools_openai = c.tools_openai,
        .tools_responses = c.tools_responses,
        .reasoning = switch (params.effort) {
            .low => .low,
            .medium => .medium,
            .high => .high,
        },
        .fast = params.fast,
        .ultracode_mode = params.ultracode,
        .show_thinking = params.thinking,
    };
    defer agent.tools_used.deinit(gpa);
    for (history) |t| {
        const role = switch (t.role) {
            .user => "user",
            .assistant => "assistant",
        };
        agent.messages.append(textMessage(arena, role, t.text) catch return null) catch return null;
    }
    const final = agent.runTurn() catch return null;
    const trimmed = std.mem.trim(u8, final, " \t\r\n");
    if (trimmed.len == 0) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

/// repl.ModelFn adapter — switch the active model by name. Keeps the working
/// provider resolved at startup (its url/key/kind — e.g. the codegraff gateway
/// login) and only swaps the model field; re-resolving via providerFor can pick
/// a different, unauthenticated provider for the same model name. Returns the
/// new model name, or null on failure.
fn replModelCb(ctx_ptr: ?*anyopaque, gpa: Allocator, name: []const u8) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    c.provider.model = gpa.dupe(u8, name) catch return null;
    c.provider.context = contextFor(c.provider.id, c.provider.model);
    return gpa.dupe(u8, name) catch null;
}
/// repl.CancelFn adapter — force-interrupt the running repl turn. Sets the
/// Agent-wide esc_cancel flag the streaming loops + watchdog poll, so the
/// in-flight runTurn unwinds (error.Interrupted) and the repl drains its steer
/// queue. Cross-thread safe (atomic) — the same signal the TTY esc-watch uses.
fn replCancelCb(ctx_ptr: ?*anyopaque) void {
    _ = ctx_ptr;
    Agent.esc_cancel.store(true, .release);
}
fn binOnPath(io: Io, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, g_path_env, ':');
    var buf: [1024]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return true;
    }
    return false;
}

fn skillInstalled(io: Io, sk: SkillDef) bool {
    for (sk.bins) |b| if (!binOnPath(io, b)) return false;
    return true;
}

/// Per-skill user opt-out, persisted as {"skills": {"kuri": false}} in
/// .harness/settings.json. A disabled skill is treated as not installed
/// everywhere — no system-prompt note, /skills shows it disabled, and
/// webfetch never shells out to it — even when its binaries are on PATH.
var g_skill_disabled = [_]bool{false} ** skills_registry.len;

/// Same opt-out, for the metered companion MCP servers (codedb-pro). They live
/// in companion_servers, NOT skills_registry, so they need their own flags —
/// this is the bug fix: {"skills": {"codedbpro": false}} now actually disables
/// the auto-connect (skillDisabled() never matched a companion server name).
var g_companion_disabled = [_]bool{false} ** companion_servers.len;

fn skillIndex(name: []const u8) ?usize {
    for (skills_registry, 0..) |sk, i| if (std.mem.eql(u8, sk.name, name)) return i;
    return null;
}

fn skillDisabled(name: []const u8) bool {
    const i = skillIndex(name) orelse return false;
    return g_skill_disabled[i];
}

/// Companion-server opt-out (e.g. codedb-pro): {"skills": {"codedbpro": false}}.
/// Server names aren't in skills_registry, so skillDisabled() can't see them —
/// the companion auto-connect gate uses this instead.
fn companionDisabled(server: []const u8) bool {
    for (companion_servers, 0..) |c, i| if (std.mem.eql(u8, c.server, server)) return g_companion_disabled[i];
    return false;
}

/// True when `codedb-pro probe` exits 0 (paid + usable). Set once at startup
/// after the companion connects; selects the licensed vs conservative note.
var g_codedbpro_licensed: bool = false;

/// Run the companion's `probe` — its own harness-gating capability check, the
/// same gate the codedb-pro CLI hooks use. Exit 0 == licensed and usable.
fn probeCodedbproLicensed(gpa: Allocator, io: Io) bool {
    const run = runCapped(gpa, io, &.{ "codedb-pro", "probe" }, 256, 256, 0) catch return false;
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    return switch (run.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Pick the codedbpro system-prompt note: the lean-in note when licensed, else
/// the conservative free-codedb fallback (`conservative`, from mcp_notes).
fn codedbproNote(server: []const u8, licensed: bool, conservative: []const u8) []const u8 {
    if (licensed and std.mem.eql(u8, server, "codedbpro")) return codedbpro_note_licensed;
    return conservative;
}

/// Installed AND not user-disabled — the only check callers should use.
fn skillActive(io: Io, sk: SkillDef) bool {
    return !skillDisabled(sk.name) and skillInstalled(io, sk);
}

/// Parse the "skills" section of .harness/settings.json into the disabled
/// flags (call once at startup): {"skills": {"<name>": false}} disables;
/// anything else leaves it enabled. Covers skills_registry AND companion
/// servers (codedb-pro).
fn loadSkillSettings(io: Io, arena: Allocator) void {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const skills = v.object.get("skills") orelse return;
    applySkillSettings(skills);
}

/// Pure half of loadSkillSettings (no disk I/O), so the opt-out wiring is
/// unit-testable: maps {"skills": {"<name>": false}} onto the disabled flags.
fn applySkillSettings(skills: Value) void {
    if (skills != .object) return;
    for (skills_registry, 0..) |sk, i| {
        const entry = skills.object.get(sk.name) orelse continue;
        if (entry == .bool and !entry.bool) g_skill_disabled[i] = true;
    }
    for (companion_servers, 0..) |c, i| {
        const entry = skills.object.get(c.server) orelse continue;
        if (entry == .bool and !entry.bool) g_companion_disabled[i] = true;
    }
}

// ── thinking animations ──────────────────────────────────────────────────
// Spinner animations + color themes (and their settings persistence) live in
// anim.zig (#123); it imports ansi and back-imports main for Approvals paths.
// The spinner consumers (Agent.spinnerTask, /animation, /theme) stay here.
const anim = @import("anim.zig");
var g_shine_phase: usize = 0; // ultracode input-wave animation frame

// Steering (Codex-style): bytes typed while a turn streams are captured
// instead of discarded, echoed live in dim cyan, and on Enter queued to
// run as the next turn — so you can line up follow-ups one after the
// other without waiting for the current turn to finish. TTY-only (the
// raw-stdin esc-watch path is gated off in --json/GUI mode), so the queue
// stays empty there. Watchdog/select arms may drain and echo stdin while the
// stream reader is blocked; g_steer_visible pauses spinner redraws so the live
// steering row is not cleared out from under the user.
var g_steer_buf: std.ArrayList(u8) = .empty; // in-progress line (page-alloc)
const SteerEntry = struct { text: []const u8, force: bool };
var g_steer_queue: std.ArrayList(SteerEntry) = .empty; // completed lines
var g_steer_echoed = false; // "↳ steer ›" prefix shown for the current line
var g_steer_visible: std.atomic.Value(bool) = .init(false); // visible live steering row; pauses spinner redraws
var g_out: ?*Io.Writer = null; // stdout writer for steer echo (set in main)
var g_gui_mu: Io.Mutex = .init; // serializes --json stdout across pool-thread subagent emits (guiEmit + Agent.emit)
var g_force_interrupt = false; // Force-prompt path caused the last interrupt (Ctrl-F/double-enter).
var g_thinking_fold_request: bool = false; // Ctrl-T in escPressed → fold/unfold the live Thinking block (#92)
var g_thinking_open: bool = false; // a live Thinking block is on screen (gates the mouse-click fold, #92)
pub var g_5xx_body_buf: [600]u8 = undefined; // snippet of the last 5xx/429 error body
pub var g_5xx_body_len: usize = 0; // 0 = no body captured

/// Pops the next queued steering prompt (FIFO), or null if none.
fn popSteer() ?SteerEntry {
    if (g_steer_queue.items.len == 0) return null;
    return g_steer_queue.orderedRemove(0);
}

/// Drops any half-typed steering line (no Enter yet) — called at the top
/// of each REPL iteration so a partial mid-turn draft never leaks into the
/// next prompt.
fn resetSteerPartial() void {
    g_steer_buf.clearRetainingCapacity();
    g_steer_echoed = false;
    g_steer_visible.store(false, .release);
}

/// Writes steering echo to the stdout writer (the same buffered writer the
/// streaming text uses, already flushed before escPressed runs, so ordering
/// stays correct) and flushes so the user sees queued keystrokes live.
fn steerEcho(bytes: []const u8) void {
    if (g_out) |w| {
        w.writeAll(bytes) catch {};
        w.flush() catch {};
    }
}


/// Persist one skill's enabled/disabled state to .harness/settings.json,
/// preserving every other key (allow-list and hooks live there too).
/// Enabling removes the key; disabling writes `false`. Best-effort.
fn saveSkillSetting(io: Io, gpa: Allocator, name: []const u8, enabled: bool) bool {
    Io.Dir.cwd().createDir(io, Approvals.settings_dir, .default_dir) catch {}; // already-exists is fine
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    var skills_obj: std.json.ObjectMap = if (root_obj.get("skills")) |s|
        (if (s == .object) s.object else .empty)
    else
        .empty;
    if (enabled) {
        _ = skills_obj.orderedRemove(name);
    } else {
        skills_obj.put(a, name, .{ .bool = false }) catch return false;
    }
    if (skills_obj.count() == 0) {
        _ = root_obj.orderedRemove("skills");
    } else {
        root_obj.put(a, "skills", .{ .object = skills_obj }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, Approvals.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Persist the thinking controls (/effort, /fast) to .harness/settings.json,
/// preserving every other key. Default values (medium effort, fast off) are
/// removed rather than written so the file stays clean. Best-effort.
fn saveThinkingSettings(io: Io, gpa: Allocator, effort: ReasoningEffort, fast: bool, ultracode: bool, show_thinking: bool, ai_title: bool) bool {
    Io.Dir.cwd().createDir(io, Approvals.settings_dir, .default_dir) catch {}; // already-exists is fine
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (effort == .medium) {
        _ = root_obj.orderedRemove("effort");
    } else {
        root_obj.put(a, "effort", .{ .string = @tagName(effort) }) catch return false;
    }
    if (!fast) {
        _ = root_obj.orderedRemove("fast");
    } else {
        root_obj.put(a, "fast", .{ .bool = true }) catch return false;
    }
    if (!ultracode) {
        _ = root_obj.orderedRemove("ultracode");
    } else {
        root_obj.put(a, "ultracode", .{ .bool = true }) catch return false;
    }
    if (show_thinking) {
        _ = root_obj.orderedRemove("show_thinking");
    } else {
        root_obj.put(a, "show_thinking", .{ .bool = false }) catch return false;
    }
    if (ai_title) {
        _ = root_obj.orderedRemove("ai_title");
    } else {
        root_obj.put(a, "ai_title", .{ .bool = false }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, Approvals.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Load persisted thinking controls into the root agent at startup:
/// {"effort": "low|medium|high"} and {"fast": true}. Best-effort — a missing
/// or garbled file just leaves the defaults (medium, off).
fn loadThinkingSettings(io: Io, arena: Allocator, root: *Agent) void {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    if (v.object.get("effort")) |e| if (e == .string) {
        if (std.mem.eql(u8, e.string, "low")) {
            root.reasoning = .low;
        } else if (std.mem.eql(u8, e.string, "medium")) {
            root.reasoning = .medium;
        } else if (std.mem.eql(u8, e.string, "high")) {
            root.reasoning = .high;
        }
    };
    if (v.object.get("fast")) |fv| if (fv == .bool) {
        root.fast = fv.bool;
    };
    if (v.object.get("ultracode")) |uv| if (uv == .bool) {
        root.ultracode_mode = uv.bool;
    };
    if (v.object.get("show_thinking")) |sv| if (sv == .bool) {
        root.show_thinking = sv.bool;
    };
    if (v.object.get("ai_title")) |tv| if (tv == .bool) {
        root.ai_title = tv.bool;
    };
}

/// Tab-completion candidates for the current input. After `/model ` →
/// model names (deduped) + provider ids matching the partial; a bare `/word`
/// → slash commands. Returns the byte offset of the word being completed
/// (so the caller can splice in a candidate). Candidates are static slices.
fn fillCompletions(gpa: Allocator, line: []const u8, out: *std.ArrayList([]const u8)) usize {
    const mp = "/model ";
    if (std.mem.startsWith(u8, line, mp)) {
        const partial = line[mp.len..];
        for (model_table) |m| {
            if (!std.mem.startsWith(u8, m.name, partial)) continue;
            var dup = false;
            for (out.items) |x| if (std.mem.eql(u8, x, m.name)) {
                dup = true;
            };
            if (!dup) out.append(gpa, m.name) catch {};
        }
        for (provider_specs) |s| if (std.mem.startsWith(u8, s.id, partial)) out.append(gpa, s.id) catch {};
        return mp.len;
    }
    if (line.len > 0 and line[0] == '/' and std.mem.indexOfScalar(u8, line, ' ') == null) {
        for (repl_commands) |cmd| if (std.mem.startsWith(u8, cmd, line)) out.append(gpa, cmd) catch {};
        return 0;
    }
    return line.len;
}

/// True when at least one byte is already waiting on `fd` (≤50ms): tells a
/// bare Esc keypress apart from the first byte of an escape sequence
/// (terminals send the whole sequence in one burst).
/// Screen position of a byte in a wrapped input line: given the prompt width
/// `plen` (columns the prompt occupies on the first row), terminal width
/// `cols`, and byte index `pos` into the buffer, the cursor's 0-based row
/// (counted from the prompt row) and 0-based column. The buffer wraps every
/// `cols` columns, so a byte sitting just past a row edge is col 0 of the next
/// row. Pure (unit-tested below); redraw uses it to place the cursor.
fn wrapAt(plen: usize, cols: usize, pos: usize) struct { row: usize, col: usize } {
    const c = if (cols == 0) 1 else cols;
    const flat = plen + pos;
    return .{ .row = flat / c, .col = flat % c };
}

/// Persisted across `readLine`'s redraws: how many rows the wrapped input
/// occupied last time (a count ≥1) and which 0-based row the cursor sat on.
/// The redraw clears exactly these rows relative to where the cursor is now —
/// no absolute cursor save (DECSC), which a wrap-induced scroll would strand.
/// Input taller than the screen is unsupported (same caveat as bash/zsh).
const LineRender = struct { rows: usize = 1, crow: usize = 0 };

/// Column from a DSR cursor-position reply — `seq` is the CSI body with the
/// ESC stripped, e.g. "[12;34R". Null (caller falls back to column 1) on
/// anything malformed, including the meaningless column 0.
fn parseDsrCol(seq: []const u8) ?usize {
    if (seq.len < 5 or seq[0] != '[' or seq[seq.len - 1] != 'R') return null;
    const semi = std.mem.indexOfScalar(u8, seq, ';') orelse return null;
    const col = std.fmt.parseInt(usize, seq[semi + 1 .. seq.len - 1], 10) catch return null;
    return if (col == 0) null else col;
}

// Terminal primitives (Windows console shim + cross-platform raw-mode tty layer
// + size/poll/row-count helpers) live in term.zig (600-line goal). win is
// re-exported (hooks.zig back-imports it); the rest are aliased back so call
// sites stay unqualified.
const terminal = @import("term.zig");
pub const win = terminal.win;
const tty = terminal.tty;
const termCols = terminal.termCols;
const termRows = terminal.termRows;
const advanceThinkingRows = terminal.advanceThinkingRows;
const inputPending = terminal.inputPending;
const inputPendingTimed = terminal.inputPendingTimed;

/// Raw RGB stops for the ultracode wave (mirrors ultracode_rainbow's hues).
const ultracode_rgb = [_]struct { r: u8, g: u8, b: u8 }{
    .{ .r = 255, .g = 87, .b = 51 },
    .{ .r = 255, .g = 159, .b = 28 },
    .{ .r = 255, .g = 222, .b = 51 },
    .{ .r = 120, .g = 255, .b = 51 },
    .{ .r = 51, .g = 255, .b = 170 },
    .{ .r = 51, .g = 170, .b = 255 },
    .{ .r = 120, .g = 51, .b = 255 },
    .{ .r = 210, .g = 51, .b = 255 },
    .{ .r = 255, .g = 51, .b = 159 },
};

/// Smoothly interpolated rainbow hue for the ultracode wave. `pos_q8` is a
/// 0..2048 fraction across the 9-stop palette (8 bits index + 8 bits blend),
/// so the wave glides between colors instead of snapping. A sine brightness
/// breath (period ~2.2s at 110ms/tick) gives a rhythmic pulse rather than a
/// mechanical scroll. Writes the SGR escape straight to the writer.
fn ultracodeWaveHue(w: *Io.Writer, pos_q8: u16, phase: usize) void {
    const pal = &ultracode_rgb;
    const len: u16 = pal.len;
    const p: u16 = pos_q8 + @as(u16, @intCast(phase * 32));
    const idx: u16 = (p >> 8) % len;
    const frac: u16 = p & 0xff;
    const a = pal[idx];
    const b = pal[(idx + 1) % len];
    // Interpolate in signed space (b-a may be negative) then clamp to 0..255.
    const r: i32 = @as(i32, a.r) + @divTrunc((@as(i32, b.r) - @as(i32, a.r)) * @as(i32, frac), 256);
    const g: i32 = @as(i32, a.g) + @divTrunc((@as(i32, b.g) - @as(i32, a.g)) * @as(i32, frac), 256);
    const bl: i32 = @as(i32, a.b) + @divTrunc((@as(i32, b.b) - @as(i32, a.b)) * @as(i32, frac), 256);
    // Breath: a gentle sine over phase, period 20 ticks (~2.2s @ 110ms),
    // modulating brightness between ~81% and ~94% — a soft, subtle pulse.
    const breath: u16 = switch (phase % 20) {
        0 => 120,
        1 => 120,
        2 => 118,
        3 => 117,
        4 => 114,
        5 => 112,
        6 => 110,
        7 => 107,
        8 => 106,
        9 => 104,
        10 => 104,
        11 => 104,
        12 => 106,
        13 => 107,
        14 => 110,
        15 => 112,
        16 => 114,
        17 => 117,
        18 => 118,
        else => 120,
    };
    const sc: i32 = @as(i32, breath);
    const cr: u8 = @intCast(@max(0, @min(255, @divTrunc(r * sc, 128))));
    const cg: u8 = @intCast(@max(0, @min(255, @divTrunc(g * sc, 128))));
    const cb: u8 = @intCast(@max(0, @min(255, @divTrunc(bl * sc, 128))));
    w.print("\x1b[38;2;{d};{d};{d}m", .{ cr, cg, cb }) catch {};
}

/// Directories the `@` file picker never descends into (every dot-dir is
/// also skipped): package/build output and caches — never @-mention targets.
const atpick_skip_dirs = [_][]const u8{ "node_modules", "zig-out", "zig-cache", "__pycache__", "venv", "target", "dist", "build" };
const atpick_max_files = 5000;

fn atpickSkipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (atpick_skip_dirs) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Extensions treated as binary: hidden from the `@` picker and refused by
/// read_file (which points the model at bash converters like pdftotext).
const binary_exts = [_][]const u8{ "pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "icns", "tiff", "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "exe", "dll", "so", "dylib", "a", "o", "wasm", "class", "jar", "pyc", "woff", "woff2", "ttf", "otf", "eot", "mp3", "mp4", "m4a", "mov", "avi", "mkv", "wav", "flac", "ogg", "sqlite", "db", "bin" };

fn binaryFileExt(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (binary_exts) |b| if (std.ascii.eqlIgnoreCase(ext, b)) return true;
    return false;
}

/// Image types stageImagePath understands (a dropped one becomes a vision
/// attachment instead of an inlined path).
pub fn isImagePath(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Pull the `@` picker's file list from codedb's index (`codedb glob '**/*'`):
/// gitignore-aware and instant once the repo is indexed, unlike the blind
/// walk below. Returns false when codedb is missing, errors, or knows no
/// files — the caller falls back to the walk. Entries are gpa-owned.
fn collectCodedbFiles(io: Io, gpa: Allocator, files: *std.ArrayList([]const u8)) bool {
    const run = runCapped(gpa, io, &.{ "codedb", "glob", "**/*" }, bash_stdout_cap, 4096, 0) catch return false;
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    const code: ?u8 = switch (run.term) {
        .exited => |c| c,
        else => null,
    };
    if (code == null or code.? != 0) return false;
    // A truncated capture may end mid-path: only parse up to the last newline.
    const safe_end = if (run.stdout_truncated)
        (std.mem.lastIndexOfScalar(u8, run.stdout, '\n') orelse 0)
    else
        run.stdout.len;
    var it = std.mem.splitScalar(u8, run.stdout[0..safe_end], '\n');
    while (it.next()) |ln| {
        if (files.items.len >= atpick_max_files) break;
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        if (binaryFileExt(line)) continue; // PDFs/images/archives: not @-mention targets
        const dup = gpa.dupe(u8, line) catch continue;
        files.append(gpa, dup) catch gpa.free(dup);
    }
    return files.items.len > 0;
}

/// Collect file paths (relative to cwd) for the `@` picker: codedb's index
/// when available, else an iterative breadth-first walk skipping
/// atpickSkipDir directories, capped at atpick_max_files. Entries are
/// gpa-owned; the caller frees them.
fn collectRepoFiles(io: Io, gpa: Allocator, files: *std.ArrayList([]const u8)) void {
    if (collectCodedbFiles(io, gpa, files)) return;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    dirs.append(gpa, gpa.dupe(u8, ".") catch return) catch return;
    var head: usize = 0;
    while (head < dirs.items.len) : (head += 1) {
        const dpath = dirs.items[head];
        const top = std.mem.eql(u8, dpath, ".");
        var dir = Io.Dir.cwd().openDir(io, dpath, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (files.items.len >= atpick_max_files) return;
            switch (entry.kind) {
                .directory => {
                    if (atpickSkipDir(entry.name)) continue;
                    const rel = if (top) gpa.dupe(u8, entry.name) catch continue else std.fmt.allocPrint(gpa, "{s}/{s}", .{ dpath, entry.name }) catch continue;
                    dirs.append(gpa, rel) catch gpa.free(rel);
                },
                .file, .sym_link => {
                    if (binaryFileExt(entry.name)) continue; // PDFs/images/archives: not @-mention targets
                    const rel = if (top) gpa.dupe(u8, entry.name) catch continue else std.fmt.allocPrint(gpa, "{s}/{s}", .{ dpath, entry.name }) catch continue;
                    files.append(gpa, rel) catch gpa.free(rel);
                },
                else => {},
            }
        }
    }
}

/// Recognize a bracketed paste that is a drag-and-dropped file path: one
/// line, possibly quoted or backslash-escaped (terminals escape spaces and
/// append a trailing space), naming an absolute path after ~ expansion.
/// Returns the cleaned path (gpa-owned), else null. The caller is
/// responsible for checking that the path actually exists.
fn cleanDroppedPath(gpa: Allocator, home: []const u8, pasted: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, pasted, " \t\r\n");
    if (s.len < 2 or std.mem.indexOfScalar(u8, s, '\n') != null) return null;
    if ((s[0] == '\'' and s[s.len - 1] == '\'') or (s[0] == '"' and s[s.len - 1] == '"'))
        s = s[1 .. s.len - 1];
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa);
    if (std.mem.startsWith(u8, s, "~/") and home.len > 0) {
        clean.appendSlice(gpa, home) catch return null;
        s = s[1..];
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = if (s[i] == '\\' and i + 1 < s.len) blk: {
            i += 1;
            break :blk s[i];
        } else s[i];
        clean.append(gpa, ch) catch return null;
    }
    if (clean.items.len == 0 or clean.items[0] != '/') return null;
    return clean.toOwnedSlice(gpa) catch null;
}

/// History + unsent-draft navigation for the line editor (#101). Mirrors the
/// GUI's promptHistoryNavigation.ts: stepping UP out of the fresh slot snapshots
/// the half-typed draft; stepping DOWN past the newest entry restores it instead
/// of clearing the line. `idx == history.len` is the fresh (editing) slot.
const HistoryNav = struct {
    idx: usize,
    draft: ?[]const u8 = null, // owned snapshot of the unsent line; freed by the caller

    fn init(history_len: usize) HistoryNav {
        return .{ .idx = history_len };
    }

    /// UP / older. `current` is the live buffer. Returns the text the buffer
    /// should show next, or null to leave it unchanged (already at the oldest).
    /// Leaving the fresh slot snapshots `current` as the draft to restore later.
    fn up(self: *HistoryNav, gpa: Allocator, history: []const []const u8, current: []const u8) ?[]const u8 {
        if (self.idx == 0) return null;
        if (self.idx == history.len) { // leaving the fresh slot: keep the draft
            if (self.draft) |d| gpa.free(d);
            self.draft = gpa.dupe(u8, current) catch null;
        }
        self.idx -= 1;
        return history[self.idx];
    }

    /// DOWN / newer. Returns the text to show next, or null to leave it
    /// unchanged (already at the fresh slot). Past the newest entry, restores the
    /// snapshotted draft (or "" when there was none) instead of clearing it.
    fn down(self: *HistoryNav, history: []const []const u8) ?[]const u8 {
        if (self.idx >= history.len) return null;
        self.idx += 1;
        if (self.idx == history.len) return self.draft orelse "";
        return history[self.idx];
    }
};

test "HistoryNav: up snapshots the draft, down past newest restores it (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{ "first", "second" };
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);

    // up from the fresh slot → newest entry, draft snapshotted
    try std.testing.expectEqualStrings("second", nav.up(gpa, &history, "draft in progress").?);
    // up again → older entry
    try std.testing.expectEqualStrings("first", nav.up(gpa, &history, "second").?);
    // up at the oldest → no change
    try std.testing.expect(nav.up(gpa, &history, "first") == null);
    // down → back to newest
    try std.testing.expectEqualStrings("second", nav.down(&history).?);
    // down past newest → the draft is restored, NOT cleared (the bug)
    try std.testing.expectEqualStrings("draft in progress", nav.down(&history).?);
    // down at the fresh slot → no change
    try std.testing.expect(nav.down(&history) == null);
}

test "HistoryNav: no draft → fresh slot returns empty, no leak (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{"only"};
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);
    try std.testing.expectEqualStrings("only", nav.up(gpa, &history, "").?);
    try std.testing.expectEqualStrings("", nav.down(&history).?); // empty draft → empty line, as today
}

/// Read one input line with a tiny raw-mode editor: ↑/↓ walk history,
/// Tab completes/cycles (models, providers, slash commands), backspace edits,
/// Ctrl-C cancels the line, Ctrl-D on an empty line is EOF. `buf` is reused
/// across calls and holds the result (valid until the next call). Returns the
/// line, or null on EOF. Falls back to a plain buffered line read when stdin
/// isn't a TTY (pipes, tests). DECSC/DECRC saves/restores the cursor to redraw.
fn readLine(
    root: *Agent,
    in: *Io.Reader,
    out: *Io.Writer,
    gpa: Allocator,
    history: *std.ArrayList([]const u8),
    buf: *std.ArrayList(u8),
) !?[]const u8 {
    const raw_state = tty.enterRaw(true) orelse return in.takeDelimiter('\n');
    defer tty.restore(raw_state);

    buf.clearRetainingCapacity();
    var cur: usize = 0; // cursor index within buf
    var nav: HistoryNav = .init(history.items.len); // history + unsent-draft nav (#101)
    defer if (nav.draft) |d| gpa.free(d);
    out.writeAll("\x1b[?2004h") catch {}; // enable bracketed paste (terminal wraps pastes in ESC[200~ … ESC[201~)
    defer out.writeAll("\x1b[?2004l") catch {};
    out.flush() catch {};

    // Where does input start? Ask the terminal (DSR 6) for the column right
    // after the prompt; the renderer treats those columns as a fixed prefix
    // and wraps the input across rows below it. Cursor moves in redraw are all
    // relative (never an absolute DECSC anchor), so a wrap-induced scroll
    // shifts the whole block together and never strands the prompt. Typed-
    // ahead text bytes that race the reply are replayed into the edit loop
    // below; a typed-ahead escape sequence inside that ~ms window is dropped.
    var prompt_col: usize = 1; // 1-based column where the buffer renders
    var rstate: LineRender = .{}; // rows used + cursor row of the last redraw
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var pend_i: usize = 0;
    out.writeAll("\x1b[6n") catch {};
    out.flush() catch {};
    dsr: {
        var polls: usize = 0;
        var esc: [16]u8 = undefined;
        var n: usize = 0;
        var in_esc = false;
        while (true) {
            if (in.buffered().len == 0 and !inputPending()) { // 50ms poll
                polls += 1;
                if (polls >= 10) break :dsr; // no reply in ~500ms: fall back
                // to column 1 — a later reply is still adopted (CSI 'R').
                continue;
            }
            const b = in.takeByte() catch break :dsr;
            if (!in_esc) {
                if (b == 0x1b) {
                    in_esc = true;
                    n = 0;
                    continue;
                }
                pending.append(gpa, b) catch {};
                if (pending.items.len > 64) break :dsr;
                continue;
            }
            if (n == 0 and b != '[') { // Alt-chord typed ahead: drop it
                in_esc = false;
                continue;
            }
            if (n < esc.len) {
                esc[n] = b;
                n += 1;
            }
            if (n >= 2 and b >= 0x40 and b <= 0x7e) { // CSI final byte
                if (b == 'R') { // the reply: ESC [ row ; col R
                    prompt_col = parseDsrCol(esc[0..n]) orelse 1;
                    break :dsr;
                }
                in_esc = false; // some other CSI typed ahead — drop it
                n = 0;
            }
        }
    }
    // Narrow terminal: when the prompt leaves too little room (the token-
    // stats prompt nearly fills a small window), give the input its own
    // row — what shells do — rather than wrapping in a sliver beside the
    // prompt.
    if (termCols() < prompt_col + 16) {
        out.writeAll("\r\n") catch {};
        out.flush() catch {};
        prompt_col = 1;
    }

    const redraw = struct {
        // Redraw the whole input below a fixed prompt prefix, wrapping it
        // across rows. Spans listed in `marks` (paths from the @ picker or a
        // file drop, plus "[Image]") render as a cyan chip (reverse video +
        // cyan) so they keep reading as attached files, not typed words; a
        // chip crossing a row break keeps its colour. `st` carries the row
        // count + cursor row of the previous draw so this one can clear it
        // with relative moves only — no DECSC anchor for a scroll to strand.
        fn f(o: *Io.Writer, items: []const u8, c: usize, marks: []const []const u8, st: *LineRender, pcol: usize) void {
            const cols = termCols();
            const plen = if (pcol > 0) pcol - 1 else 0; // columns the prompt holds on row 0

            // Clear the previous block: drop to its bottom row, then clear
            // bottom-up. Row 0 is cleared only past the prompt so the prompt
            // survives. Every move is relative, so a prior scroll is harmless.
            if (st.rows - 1 > st.crow) o.print("\x1b[{d}B", .{st.rows - 1 - st.crow}) catch {};
            var k = st.rows - 1;
            while (k > 0) : (k -= 1) o.writeAll("\r\x1b[K\x1b[A") catch {};
            o.writeAll("\r") catch {};
            if (plen > 0) o.print("\x1b[{d}C", .{plen}) catch {};
            o.writeAll("\x1b[K") catch {};

            // Re-emit the buffer, wrapping by hand at the right edge (a literal
            // "\r\n" every `cols` columns) rather than trusting terminal
            // autowrap, whose last-column "pending wrap" state is ambiguous.
            var i: usize = 0;
            var row: usize = 0;
            var vcol: usize = plen;
            var mark_end: usize = 0;
            var mark_open = false;
            // `ultracode` shines the input itself: each letter of every
            // (case-insensitive) occurrence renders in a rotating rainbow hue.
            var shine_starts: [8]usize = undefined;
            var shine_ends: [8]usize = undefined;
            var nshine: usize = 0;
            {
                var si: usize = 0;
                while (si + 9 <= items.len) : (si += 1) {
                    if (std.ascii.eqlIgnoreCase(items[si .. si + 9], "ultracode")) {
                        if (nshine < shine_starts.len) {
                            shine_starts[nshine] = si;
                            shine_ends[nshine] = si + 9;
                            nshine += 1;
                        }
                    }
                }
            }
            var shine_active = false;
            while (i < items.len) {
                if (vcol >= cols) { // row full → wrap to the next
                    o.writeAll("\r\n") catch {};
                    row += 1;
                    vcol = 0;
                }
                if (!mark_open) { // open a chip that starts here (longest wins)
                    var best: usize = 0;
                    for (marks) |m| {
                        if (m.len == 0 or i + m.len > items.len) continue;
                        if (std.mem.eql(u8, items[i .. i + m.len], m) and m.len > best) best = m.len;
                    }
                    if (best > 0) {
                        if (shine_active) {
                            o.writeAll("\x1b[0m") catch {};
                            shine_active = false;
                        }
                        o.writeAll("\x1b[7;36m") catch {};
                        mark_end = i + best;
                        mark_open = true;
                    }
                }
                // Rainbow shine for an `ultracode` span (skipped inside a chip).
                if (!mark_open) {
                    var in_shine = false;
                    for (shine_starts[0..nshine], shine_ends[0..nshine]) |sstart, send| {
                        if (i >= sstart and i < send) {
                            // Smooth interpolated hue + rhythmic brightness
                            // breath; pos_q8 spreads the 9 letters across a
                            // full palette pass so the wave glides.
                            ultracodeWaveHue(o, @intCast((i - sstart) * 256), g_shine_phase);
                            in_shine = true;
                            break;
                        }
                    }
                    if (in_shine) {
                        shine_active = true;
                    } else if (shine_active) {
                        o.writeAll("\x1b[0m") catch {};
                        shine_active = false;
                    }
                }
                o.writeByte(items[i]) catch {};
                vcol += 1;
                i += 1;
                if (mark_open and i == mark_end) {
                    o.writeAll("\x1b[0m") catch {};
                    mark_open = false;
                    shine_active = false;
                }
            }
            if (mark_open or shine_active) o.writeAll("\x1b[0m") catch {};

            // Place the cursor. wrapAt gives its target row/col; when it sits
            // at the very end of a just-filled row that's a fresh row below the
            // text (the classic last-column case), realise it with a newline so
            // the next keystroke stays visible.
            const tgt = wrapAt(plen, cols, c);
            while (tgt.row > row) {
                o.writeAll("\r\n") catch {};
                row += 1;
            }
            if (row > tgt.row) o.print("\x1b[{d}A", .{row - tgt.row}) catch {};
            o.writeAll("\r") catch {};
            if (tgt.col > 0) o.print("\x1b[{d}C", .{tgt.col}) catch {};
            o.flush() catch {};

            st.rows = row + 1;
            st.crow = tgt.row;
        }
    }.f;
    const setLine = struct {
        fn f(g: Allocator, b: *std.ArrayList(u8), s: []const u8) void {
            b.clearRetainingCapacity();
            b.appendSlice(g, s) catch {};
        }
    }.f;
    const delRange = struct { // remove [a, e) from buf (a <= e <= len)
        fn f(b: *std.ArrayList(u8), a: usize, e: usize) void {
            std.mem.copyForwards(u8, b.items[a..], b.items[e..]);
            b.shrinkRetainingCapacity(b.items.len - (e - a));
        }
    }.f;
    const prevWord = struct { // start of the word at/just before c
        fn f(items: []const u8, c: usize) usize {
            var i = c;
            while (i > 0 and items[i - 1] == ' ') i -= 1;
            while (i > 0 and items[i - 1] != ' ') i -= 1;
            return i;
        }
    }.f;
    const nextWord = struct { // end of the word at/after c
        fn f(items: []const u8, c: usize) usize {
            var i = c;
            while (i < items.len and items[i] == ' ') i += 1;
            while (i < items.len and items[i] != ' ') i += 1;
            return i;
        }
    }.f;

    // Tab-completion cycle state.
    var comp_items: std.ArrayList([]const u8) = .empty;
    defer comp_items.deinit(gpa);
    var comp_base: usize = 0;
    var comp_idx: usize = 0;
    var comp_active = false;

    // Bracketed-paste collapse: a multi-line paste becomes a "[Pasted text #N
    // +L lines]" placeholder in the buffer; on submit each placeholder is
    // expanded back to its full text.
    const Paste = struct { ph: []const u8, body: []const u8 };
    var pastes: std.ArrayList(Paste) = .empty;
    defer {
        for (pastes.items) |p| {
            gpa.free(p.ph);
            gpa.free(p.body);
        }
        pastes.deinit(gpa);
    }

    // File paths inserted by the @ picker or a drag-and-drop (plus the
    // "[Image]" attachment marker): redraw renders these spans highlighted.
    // Editing inside a span just drops its highlight — the text stays.
    var marks: std.ArrayList([]const u8) = .empty;
    defer {
        for (marks.items) |m| gpa.free(m);
        marks.deinit(gpa);
    }
    const addMark = struct { // dupe + dedupe; drops the mark on OOM (cosmetic only)
        fn f(g: Allocator, ms: *std.ArrayList([]const u8), s: []const u8) void {
            for (ms.items) |m| if (std.mem.eql(u8, m, s)) return;
            const dup = g.dupe(u8, s) catch return;
            ms.append(g, dup) catch g.free(dup);
        }
    }.f;

    while (true) {
        // Replay any text bytes that raced the DSR reply, then read live.
        const c = if (pend_i < pending.items.len) blk: {
            const b = pending.items[pend_i];
            pend_i += 1;
            break :blk b;
        } else blk: {
            // While the input contains `ultracode`, wave the rainbow shine
            // across the letters: poll for input with a slower 110ms timeout,
            // and on each idle tick advance the phase + redraw so the hue
            // glides and breathes (~9fps, calm + rhythmic rather than a fast
            // flicker).
            while (std.ascii.indexOfIgnoreCase(buf.items, "ultracode") != null) {
                if (inputPendingTimed(110)) break; // keystroke ready — read it below
                g_shine_phase +%= 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            }
            break :blk in.takeByte() catch return null;
        };
        if (c != 0x09) comp_active = false; // any non-Tab key ends the cycle
        switch (c) {
            0x09 => { // Tab: complete, or cycle through matches on repeat
                if (!comp_active) {
                    comp_items.clearRetainingCapacity();
                    comp_base = fillCompletions(gpa, buf.items, &comp_items);
                    if (comp_items.items.len == 0) continue;
                    comp_idx = 0;
                    comp_active = true;
                } else if (comp_items.items.len > 0) {
                    comp_idx = (comp_idx + 1) % comp_items.items.len;
                } else continue;
                buf.shrinkRetainingCapacity(comp_base);
                buf.appendSlice(gpa, comp_items.items[comp_idx]) catch {};
                cur = buf.items.len;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            '\r', '\n' => {
                // The cursor may be mid-block; step past the last input row so
                // the submitted line and whatever prints next start cleanly.
                if (rstate.rows - 1 > rstate.crow) out.print("\x1b[{d}B", .{rstate.rows - 1 - rstate.crow}) catch {};
                out.writeAll("\r\n") catch {};
                out.flush() catch {};
                // Expand any pasted placeholders back to their full text.
                for (pastes.items) |p| {
                    if (std.mem.indexOf(u8, buf.items, p.ph) == null) continue;
                    const sz = std.mem.replacementSize(u8, buf.items, p.ph, p.body);
                    const tmp = gpa.alloc(u8, sz) catch break;
                    _ = std.mem.replace(u8, buf.items, p.ph, p.body, tmp);
                    buf.clearRetainingCapacity();
                    buf.appendSlice(gpa, tmp) catch {};
                    gpa.free(tmp);
                }
                break;
            },
            0x01 => { // Ctrl-A → start of line
                cur = 0;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x05 => { // Ctrl-E → end of line
                cur = buf.items.len;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x02 => if (cur > 0) { // Ctrl-B → left
                cur -= 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x06 => if (cur < buf.items.len) { // Ctrl-F → right
                cur += 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x17, 0x1f => { // Ctrl-W / Ctrl-_ → delete previous word
                const s = prevWord(buf.items, cur);
                if (s < cur) {
                    delRange(buf, s, cur);
                    cur = s;
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                }
            },
            0x15 => if (cur > 0) { // Ctrl-U → delete to start of line
                delRange(buf, 0, cur);
                cur = 0;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x0b => if (cur < buf.items.len) { // Ctrl-K → delete to end of line
                buf.shrinkRetainingCapacity(cur);
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x16 => { // Ctrl-V: attach a clipboard image (macOS) at the cursor
                var msg: ?[]const u8 = null;
                if (grabClipboardImage(root.io)) |p| switch (stageImagePath(root, p)) {
                    .ok => {
                        const marker = "[Image] ";
                        buf.insertSlice(gpa, cur, marker) catch {};
                        cur += marker.len;
                        addMark(gpa, &marks, "[Image]");
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    .no_vision => msg = "this model can't see images — /model to a vision one (claude-*, gpt-5*)",
                    .read_fail => msg = "couldn't read the clipboard image",
                } else msg = if (builtin.os.tag == .macos) "no image on the clipboard — copy an image first (this is Ctrl-V; ⌘V can't be captured)" else "clipboard image paste is macOS-only — use /image <path>";
                if (msg) |m| { // feedback below the input, then redraw the prompt+buffer fresh
                    if (rstate.rows - 1 > rstate.crow) out.print("\x1b[{d}B", .{rstate.rows - 1 - rstate.crow}) catch {};
                    out.print("\r\n{s}· {s}{s}", .{ style.dim, m, style.reset }) catch {};
                    root.prompt() catch {};
                    rstate = .{};
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                }
            },
            0x7f, 0x08 => if (cur > 0) { // backspace → delete char before cursor
                delRange(buf, cur - 1, cur);
                cur -= 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x03 => { // Ctrl-C: clear a non-empty line; on an empty line, quit
                if (buf.items.len == 0) {
                    out.writeAll("^C\n") catch {};
                    out.flush() catch {};
                    return null;
                }
                buf.clearRetainingCapacity();
                cur = 0;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x1a => { // Ctrl-Z: save the session and quit (like a safe Ctrl-D)
                out.writeAll("^Z — saving & quit\n") catch {};
                out.flush() catch {};
                saveSession(root, root.arena, root.session_name) catch {};
                return null;
            },
            0x04 => { // Ctrl-D: EOF on empty line, else forward-delete
                if (buf.items.len == 0) {
                    out.writeAll("\n") catch {};
                    return null;
                }
                if (cur < buf.items.len) {
                    delRange(buf, cur, cur + 1);
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                }
            },
            0x1b => { // escape sequence: arrows, Alt/Option chords, CSI
                // A bare Esc (no byte follows) clears the line — without
                // this the chord read below would block and silently eat
                // the next keypress.
                if (in.buffered().len == 0 and !inputPending()) {
                    buf.clearRetainingCapacity();
                    cur = 0;
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    continue;
                }
                const b1 = in.takeByte() catch break;
                if (b1 == 0x7f or b1 == 0x08) { // Option/Alt+Delete → delete previous word
                    const s = prevWord(buf.items, cur);
                    if (s < cur) {
                        delRange(buf, s, cur);
                        cur = s;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    }
                    continue;
                }
                if (b1 == 'b') { // Alt-b → word left
                    cur = prevWord(buf.items, cur);
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    continue;
                }
                if (b1 == 'f') { // Alt-f → word right
                    cur = nextWord(buf.items, cur);
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    continue;
                }
                if (b1 == 'd') { // Alt-d → delete next word
                    const e = nextWord(buf.items, cur);
                    if (e > cur) {
                        delRange(buf, cur, e);
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    }
                    continue;
                }
                if (b1 != '[') continue;
                // CSI: collect params until a final byte (0x40..0x7e).
                var params: [16]u8 = undefined;
                var pn: usize = 0;
                var final: u8 = 0;
                while (true) {
                    const x = in.takeByte() catch break;
                    if (x >= 0x40 and x <= 0x7e) {
                        final = x;
                        break;
                    }
                    if (pn < params.len) {
                        params[pn] = x;
                        pn += 1;
                    }
                }
                const ps = params[0..pn];
                const word_mod = std.mem.indexOfScalar(u8, ps, ';') != null; // 1;3 (alt) / 1;5 (ctrl)
                switch (final) {
                    'A' => if (nav.up(gpa, history.items, buf.items)) |text| { // up → history back; snapshots draft (#101)
                        setLine(gpa, buf, text);
                        cur = buf.items.len;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'B' => if (nav.down(history.items)) |text| { // down → history forward; restores draft past newest (#101)
                        setLine(gpa, buf, text);
                        cur = buf.items.len;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'C' => { // right (word-right with a modifier)
                        cur = if (word_mod) nextWord(buf.items, cur) else @min(cur + 1, buf.items.len);
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'D' => { // left (word-left with a modifier)
                        cur = if (word_mod) prevWord(buf.items, cur) else (if (cur > 0) cur - 1 else 0);
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'H' => {
                        cur = 0;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'F' => {
                        cur = buf.items.len;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'R' => { // late DSR cursor-position reply (slow or
                        // multiplexed terminal missed the 500ms startup
                        // window): adopt the real input column so the
                        // horizontal window stays exact instead of the
                        // column-1 fallback. Same narrow-terminal policy as
                        // startup: too little room after the prompt → the
                        // input moves to its own row.
                        if (std.mem.indexOfScalar(u8, ps, ';')) |semi| {
                            const col = std.fmt.parseInt(usize, ps[semi + 1 ..], 10) catch 0;
                            if (col > 0) {
                                if (termCols() < col + 16) {
                                    out.writeAll("\r\n") catch {};
                                    prompt_col = 1;
                                } else prompt_col = col;
                            }
                        }
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    '~' => {
                        if (std.mem.eql(u8, ps, "200")) { // bracketed paste start
                            var blob: std.ArrayList(u8) = .empty;
                            defer blob.deinit(gpa);
                            while (true) { // read until the ESC[201~ end marker
                                const x = in.takeByte() catch break;
                                blob.append(gpa, x) catch break;
                                if (std.mem.endsWith(u8, blob.items, "\x1b[201~")) {
                                    blob.shrinkRetainingCapacity(blob.items.len - 6);
                                    break;
                                }
                            }
                            var pasted = blob.items;
                            if (pasted.len > 0 and pasted[pasted.len - 1] == '\n') pasted = pasted[0 .. pasted.len - 1];
                            const lines = std.mem.count(u8, pasted, "\n") + 1;
                            const dropped = cleanDroppedPath(gpa, root.home, pasted);
                            defer if (dropped) |dp| gpa.free(dp);
                            const drop_exists = if (dropped) |dp| blk: {
                                Io.Dir.cwd().access(root.io, dp, .{}) catch break :blk false;
                                break :blk true;
                            } else false;
                            if (drop_exists) {
                                // Drag-and-dropped file: terminals paste the path
                                // escaped/quoted with a trailing space. An image on a
                                // vision model is staged as an attachment (like /image
                                // and Ctrl-V); anything else inlines the cleaned full
                                // path however long it is.
                                var staged = false;
                                var dmsg: ?[]const u8 = null;
                                if (isImagePath(dropped.?)) switch (stageImagePath(root, dropped.?)) {
                                    .ok => staged = true,
                                    .no_vision => dmsg = "this model can't see images — ✓ in /models' vision column shows ones that can; path inlined instead",
                                    .read_fail => dmsg = "couldn't read that image (missing or >5MB) — path inlined instead",
                                };
                                if (staged) {
                                    const marker = "[Image] ";
                                    buf.insertSlice(gpa, cur, marker) catch {};
                                    cur += marker.len;
                                    addMark(gpa, &marks, "[Image]");
                                } else {
                                    buf.insertSlice(gpa, cur, dropped.?) catch {};
                                    cur += dropped.?.len;
                                    addMark(gpa, &marks, dropped.?);
                                }
                                if (dmsg) |m| { // feedback below the input, then redraw fresh (below)
                                    if (rstate.rows - 1 > rstate.crow) out.print("\x1b[{d}B", .{rstate.rows - 1 - rstate.crow}) catch {};
                                    out.print("\r\n{s}· {s}{s}", .{ style.dim, m, style.reset }) catch {};
                                    root.prompt() catch {};
                                    rstate = .{};
                                }
                            } else if (lines == 1 and pasted.len <= 80) {
                                buf.insertSlice(gpa, cur, pasted) catch {}; // short single-line paste: inline
                                cur += pasted.len;
                            } else { // multi-line/long: collapse to a placeholder, expand on submit
                                const ph = std.fmt.allocPrint(gpa, "[Pasted text #{d} +{d} lines]", .{ pastes.items.len + 1, lines }) catch "";
                                const body = gpa.dupe(u8, pasted) catch "";
                                if (ph.len > 0 and body.len > 0) {
                                    pastes.append(gpa, .{ .ph = ph, .body = body }) catch {};
                                    buf.insertSlice(gpa, cur, ph) catch {};
                                    cur += ph.len;
                                }
                            }
                            redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        } else if (std.mem.eql(u8, ps, "3")) { // forward delete
                            if (cur < buf.items.len) {
                                delRange(buf, cur, cur + 1);
                                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                            }
                        } else if (std.mem.eql(u8, ps, "1") or std.mem.eql(u8, ps, "7")) {
                            cur = 0;
                            redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        } else if (std.mem.eql(u8, ps, "4") or std.mem.eql(u8, ps, "8")) {
                            cur = buf.items.len;
                            redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        }
                    },
                    else => {},
                }
            },
            else => if (c >= 0x20) { // printable: insert at cursor
                // '@' at a word boundary opens a fuzzy file picker over the
                // repo (cwd walk, dot/build dirs skipped); the picked path is
                // inserted at the cursor. A literal '@' still types fine —
                // cancel the picker (esc/ctrl-c), or type it mid-word.
                if (c == '@' and (cur == 0 or buf.items[cur - 1] == ' ')) {
                    var files: std.ArrayList([]const u8) = .empty;
                    defer {
                        for (files.items) |f| gpa.free(f);
                        files.deinit(gpa);
                    }
                    collectRepoFiles(root.io, gpa, &files);
                    if (files.items.len > 0) {
                        var items: std.ArrayList(PickItem) = .empty;
                        defer items.deinit(gpa);
                        for (files.items) |f| items.append(gpa, .{ .name = f }) catch {};
                        const picked = listPicker(root, root.arena, out, "File ›", items.items);
                        // The alt-screen picker (DECSET 1049) restores the main
                        // screen and cursor on exit, so the input block and
                        // rstate still match — just redraw over them below.
                        if (picked) |idx| {
                            buf.insertSlice(gpa, cur, files.items[idx]) catch {};
                            cur += files.items[idx].len;
                            addMark(gpa, &marks, files.items[idx]);
                        }
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        continue;
                    }
                }
                buf.insert(gpa, cur, c) catch {};
                cur += 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
        }
    }

    const trimmed = std.mem.trim(u8, buf.items, " \t\r");
    if (trimmed.len > 0 and (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], buf.items))) {
        const dup = gpa.dupe(u8, buf.items) catch return buf.items;
        history.append(gpa, dup) catch {};
    }
    return buf.items;
}

// Session persistence (last model, input history) + the wire-format message
// serializers live in serde.zig (600-line goal, std-only leaf). Aliased back.
const serde = @import("serde.zig");
const saveModel = serde.saveModel;
const loadModel = serde.loadModel;
const loadHistory = serde.loadHistory;
const saveHistory = serde.saveHistory;
const writeAnthropicMessages = serde.writeAnthropicMessages;
const writeOpenAIMessageNormalized = serde.writeOpenAIMessageNormalized;

pub const harness_version: []const u8 = @import("build_options").version;

/// Shown under `graff --version` — a terse "what's new" for recent releases.
/// Keep it short and current; bump alongside the version each release.
const changelog_text =
    \\What's new
    \\──────────
    \\0.0.166
    \\  • Trace/trajectory JSONL never corrupts on a failed write (#86)
    \\  • Auto-compaction recovers instead of wedging on huge context (#88)
    \\  • New providers: Sakana AI (fugu) + Fireworks AI (deepseek, kimi, glm…)
    \\0.0.165
    \\  • TUI: live /thinking reasoning stream, AI /title, session headers
    \\  • GUI: /ultracode toggle, prompt-history image fix, segmented borders
    \\
;

/// OTLP endpoint baked into release builds (-Dtelemetry-endpoint); "" in dev
/// builds → telemetry stays off unless an env var configures it. Used as the
/// lowest-precedence telemetry endpoint, below env overrides and opt-out.
const default_telemetry_endpoint: []const u8 = @import("build_options").telemetry_endpoint;

const usage_text =
    \\graff — a minimal agentic coding harness in Zig (zero deps)
    \\
    \\usage:
    \\  graff [flags]                    start the REPL
    \\  graff [-p] "prompt"              one-shot: run the prompt, print the answer, exit
    \\  graff login                      get a codegraff key (device-code OAuth)
    \\  graff login codex [--refresh]    ChatGPT/Codex OAuth login (PKCE)
    \\  graff login kimi                 Kimi Code OAuth login (device-code)
    \\  graff key set <provider> <key>   store a key (macOS Keychain, else 0600 file)
    \\  graff key list                   show which providers have keys
    \\  graff mcp add <name> -- <cmd>     add an MCP server to .mcp.json
    \\  graff mcp                         list configured MCP servers
    \\  graff worktree list              list the per-tab worktrees created by -w
    \\  graff worktree merge <name>      squash-land worktree-<name> onto the current branch + clean up
    \\  graff sandboxes                  list your gateway sandboxes (what's burning credits)
    \\  graff sandboxes stop <id>        spin a sandbox down (stops it + settles the meter)
    \\  graff cube new                   spin up a cloud graff (sandbox + serve + preview URL)
    \\  graff cube [status|stop]         inspect the running cube or spin it down
    \\  graff --schema                   print the machine-readable interface (SDK codegen)
    \\  graff serve                      HTTP/NDJSON bridge over the --json protocol
    \\                                   (--host/--port/--token; sessions are --json children)
    \\  graff update [--force|--check]   update graff to the latest GitHub release
    \\  graff title <prompt>            print the AI tab-title for a prompt (test title styles)
    \\
    \\flags:
    \\  --model <name>   start on this model (same fuzzy resolution as /model)
    \\  --resume <name>  resume/autosave <name>.session.json
    \\  --new            start a fresh autosaved session (default)
    \\  --no-resume      ignore --resume and start fresh
    \\  --system-prompt <text>          replace the built-in system prompt
    \\  --append-system-prompt <text>   append extra text to the system prompt
    \\  --goal <text>                   seed a standing objective (tracked as a todo checklist) for every turn
    \\  --eval <cmd>                    scoring command for an eval-driven loop (the `eval` tool runs it)
    \\  --until <0-100>                 eval-loop target score; stop when reached (default 90)
    \\  --niche <name>                  fleet niche this eval optimizes (reviewer/researcher/implementer/skeptic or a custom agent); tags submitted scores so the DGM can promote a champion for that role
    \\  -w, --worktree <name>           isolate this session in a git worktree (.graff/worktrees/<name>) so parallel agents don't collide on files
    \\  --no-autocommit                 with -w, don't auto-commit each turn (default on; land work with `graff worktree merge`)
    \\  --yolo           skip all permission prompts for the session
    \\  -p, --print      one-shot print mode (answer on stdout, progress on stderr)
    \\  --timing         show per-tool wall-clock on result lines
    \\  --cost           show running session spend in the prompt
    \\  --json           structured stdio protocol (JSON in, JSONL events out)
    \\  --max-tool-calls N  reject root tool calls after N per turn (JSON-safe budget)
    \\  --dedupe-tool-calls reject duplicate root tool name+input calls per turn
    \\  --no-telemetry   disable anonymous usage telemetry for this run
    \\  -h, --help       this help
    \\  -V, --version    print version
    \\
    \\keys: <PROVIDER>_API_KEY env vars, `graff key set`, or `graff login`;
    \\a Codex CLI login is picked up automatically.
    \\inside the REPL: /help lists commands, a bare "/" opens the command menu,
    \\"@" opens a fuzzy file picker (drag-and-dropped files paste as their path),
    \\esc interrupts a streaming response, "always allow" persists to
    \\.harness/settings.json.
    \\telemetry: anonymous OTLP usage stats are sent only when
    \\OTEL_EXPORTER_OTLP_ENDPOINT (or GRAFF_OTEL_ENDPOINT) is set; opt out
    \\with --no-telemetry or GRAFF_NO_TELEMETRY=1.
    \\
;

/// A parsed `MAJOR.MINOR.PATCH` (no pre-release/build suffix). Used to compare
/// the running version against a GitHub release tag without the exact-string
/// mismatch that `git describe` suffixes ("-3-gabc", "-dirty", "-dev") cause.
// `graff update` (latest-release check + SemVer compare + install.sh delegation)
// lives in cli.zig (600-line goal). updateCommand aliased back.
const cli = @import("cli.zig");
const updateCommand = cli.updateCommand;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // Windows: let the console interpret ANSI/VT escapes so the harness's
    // color and cursor sequences render instead of printing as literal text.
    if (builtin.os.tag == .windows) tty.enableVtOutput();

    // CLI flags. --yolo starts with the permission gate fully open (same as
    // typing /yolo once you're in) — skips every bash/tool/MCP approval prompt.
    var yolo_flag = false;
    var no_telemetry_flag = false;
    var schema_flag = false;
    var login_flag = false;
    var refresh_flag = false;
    var codex_login = false;
    var kimi_login = false;
    var help_flag = false;
    var version_flag = false;
    var print_flag = false;
    var update_force = false; // graff update --force
    var selftest_spinner_flag = false; // --selftest-spinner: headless spinner render for the PTY anti-stealth test
    var update_check = false; // graff update --check
    var model_flag: ?[]const u8 = null;
    var system_prompt_flag: ?[]const u8 = null;
    var append_system_flag: ?[]const u8 = null;
    var host_flag: []const u8 = "127.0.0.1"; // harness serve
    var port_flag: u16 = 8787; // harness serve
    var token_flag: ?[]const u8 = null; // harness serve
    var resume_flag: ?[]const u8 = null; // restore/save this named session
    var goal_flag: ?[]const u8 = null; // --goal: standing objective (todos) every turn gets, incl. --json/-p
    var eval_cmd_flag: ?[]const u8 = null; // --eval: scoring command for the eval-driven loop
    var worktree_flag: ?[]const u8 = null; // --worktree/-w: isolate this session in a git worktree (parallel agents, no file collisions)
    var eval_target_flag: ?u8 = null; // --until: target score 0-100 for the eval loop
    var eval_niche_flag: ?[]const u8 = null; // --niche: fleet niche this eval-driven session optimizes (tags submitted scores)
    var no_resume_flag = false; // start without auto-loading last.session.json
    var new_session_flag = false; // start a fresh autosaved session
    var positionals: std.ArrayList([]const u8) = .empty;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
        defer it.deinit();
        _ = it.next(); // argv[0]
        while (it.next()) |arg| {
            if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "mcp")) {
                try positionals.append(arena, try arena.dupe(u8, arg));
            } else if (std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "--yolo")) {
                    yolo_flag = true;
                } else if (std.mem.eql(u8, arg, "--worktree") or std.mem.eql(u8, arg, "-w")) {
                    worktree_flag = it.next() orelse std.process.fatal("--worktree needs a name (e.g. --worktree agent1)", .{});
                } else if (std.mem.eql(u8, arg, "--goal")) {
                    goal_flag = it.next() orelse std.process.fatal("--goal needs an objective", .{});
                } else if (std.mem.eql(u8, arg, "--eval")) {
                    eval_cmd_flag = it.next() orelse std.process.fatal("--eval needs a scoring command", .{});
                } else if (std.mem.eql(u8, arg, "--until")) {
                    const uv = it.next() orelse std.process.fatal("--until needs a score 0-100", .{});
                    eval_target_flag = std.fmt.parseInt(u8, uv, 10) catch std.process.fatal("--until must be a number 0-100", .{});
                } else if (std.mem.eql(u8, arg, "--niche")) {
                    eval_niche_flag = it.next() orelse std.process.fatal("--niche needs a name (e.g. --niche reviewer)", .{});
                } else if (std.mem.eql(u8, arg, "--no-telemetry")) {
                    no_telemetry_flag = true;
                } else if (std.mem.eql(u8, arg, "--timing")) {
                    show_timing = true;
                } else if (std.mem.eql(u8, arg, "--cost")) {
                    show_cost = true;
                } else if (std.mem.eql(u8, arg, "--json")) {
                    json_mode = true;
                } else if (std.mem.eql(u8, arg, "--max-tool-calls")) {
                    const mv = it.next() orelse std.process.fatal("--max-tool-calls needs a non-negative integer — harness --help", .{});
                    max_tool_calls = std.fmt.parseInt(u64, mv, 10) catch std.process.fatal("--max-tool-calls needs a non-negative integer, got '{s}'", .{mv});
                } else if (std.mem.eql(u8, arg, "--dedupe-tool-calls")) {
                    dedupe_tool_calls = true;
                } else if (std.mem.eql(u8, arg, "--no-autocommit")) {
                    g_worktree_autocommit = false;
                } else if (std.mem.eql(u8, arg, "--schema")) {
                    schema_flag = true;
                } else if (std.mem.eql(u8, arg, "--refresh")) {
                    refresh_flag = true;
                } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    help_flag = true;
                } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                    version_flag = true;
                } else if (std.mem.eql(u8, arg, "--selftest-spinner")) {
                    selftest_spinner_flag = true;
                } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
                    print_flag = true;
                } else if (std.mem.eql(u8, arg, "--force")) {
                    update_force = true;
                } else if (std.mem.eql(u8, arg, "--check")) {
                    update_check = true;
                } else if (std.mem.eql(u8, arg, "--resume")) {
                    const rv = it.next() orelse std.process.fatal("--resume needs a session name — harness --help", .{});
                    resume_flag = try arena.dupe(u8, rv);
                } else if (std.mem.eql(u8, arg, "--no-resume")) {
                    no_resume_flag = true;
                } else if (std.mem.eql(u8, arg, "--new")) {
                    new_session_flag = true;
                } else if (std.mem.eql(u8, arg, "--model")) {
                    const mv = it.next() orelse std.process.fatal("--model needs a value — harness --help", .{});
                    model_flag = try arena.dupe(u8, mv);
                } else if (std.mem.eql(u8, arg, "--system-prompt")) {
                    const sv = it.next() orelse std.process.fatal("--system-prompt needs a value — harness --help", .{});
                    system_prompt_flag = try arena.dupe(u8, sv);
                } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
                    const av = it.next() orelse std.process.fatal("--append-system-prompt needs a value — harness --help", .{});
                    append_system_flag = try arena.dupe(u8, av);
                } else if (std.mem.eql(u8, arg, "--host")) {
                    const hv = it.next() orelse std.process.fatal("--host needs a value — harness --help", .{});
                    host_flag = try arena.dupe(u8, hv);
                } else if (std.mem.eql(u8, arg, "--port")) {
                    const pv = it.next() orelse std.process.fatal("--port needs a value — harness --help", .{});
                    port_flag = std.fmt.parseInt(u16, pv, 10) catch std.process.fatal("--port needs a number 1-65535, got '{s}'", .{pv});
                } else if (std.mem.eql(u8, arg, "--token")) {
                    const tv = it.next() orelse std.process.fatal("--token needs a value — harness --help", .{});
                    token_flag = try arena.dupe(u8, tv);
                } else {
                    std.process.fatal("unknown flag '{s}' — harness --help lists them", .{arg});
                }
            } else {
                try positionals.append(arena, try arena.dupe(u8, arg));
            }
        }
        if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "login")) login_flag = true;
        if (positionals.items.len > 1 and std.mem.eql(u8, positionals.items[1], "codex")) codex_login = true;
        if (positionals.items.len > 1 and std.mem.eql(u8, positionals.items[1], "kimi")) kimi_login = true;
    }

    // One-shot print mode: `harness -p "prompt"` or a bare positional prompt
    // (`harness "say hi"`). Subcommands (login/key) are not prompts.
    const is_subcommand = positionals.items.len > 0 and
        (std.mem.eql(u8, positionals.items[0], "login") or std.mem.eql(u8, positionals.items[0], "key") or std.mem.eql(u8, positionals.items[0], "mcp") or
            std.mem.eql(u8, positionals.items[0], "serve") or std.mem.eql(u8, positionals.items[0], "update") or std.mem.eql(u8, positionals.items[0], "title") or std.mem.eql(u8, positionals.items[0], "repl") or
            std.mem.eql(u8, positionals.items[0], "worktree") or std.mem.eql(u8, positionals.items[0], "sandboxes") or std.mem.eql(u8, positionals.items[0], "cube"));
    var oneshot_prompt: ?[]const u8 = null;
    if (!is_subcommand and positionals.items.len > 0) {
        oneshot_prompt = try std.mem.join(arena, " ", positionals.items);
    }
    if (print_flag and oneshot_prompt == null) std.process.fatal("-p needs a prompt: harness -p \"do something\"", .{});

    // `--help` / `--version`: handled before any subcommand dispatch, so
    // `harness login --help` prints usage instead of starting an OAuth flow.
    if (help_flag or version_flag) {
        var hbuf: [4096]u8 = undefined;
        var hw = Io.File.stdout().writer(io, &hbuf);
        if (help_flag) try hw.interface.writeAll(usage_text) else try hw.interface.print("graff {s}\n\n{s}", .{ harness_version, changelog_text });
        try hw.interface.flush();
        return;
    }

    // `harness key set <provider> <key>` / `harness key list`: safe key store
    // (macOS Keychain, else a 0600 file). Exits after.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "key")) {
        const home = homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        try keyCommand(io, gpa, arena, home, positionals.items[1..]);
        return;
    }

    // `harness mcp add <name> -- <command> [args...]`: write workspace MCP config.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "mcp")) {
        try mcpCommand(io, arena, positionals.items[1..]);
        return;
    }

    // `harness login [codex] [--refresh]`: OAuth login. Default target is
    // codegraff (device-code flow, writes ~/.simple-harness-codegraff.json);
    // `codex` (or --refresh) runs the ChatGPT PKCE/refresh flow → ~/.codex/auth.json.
    if (login_flag) {
        const home = homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        if (kimi_login) try oauth.kimiLogin(io, gpa, arena, home) else if (codex_login or refresh_flag) try oauth.codexLogin(io, gpa, arena, home, refresh_flag) else try oauth.codegraffLogin(io, gpa, arena, home);
        return;
    }

    // `harness serve`: HTTP/NDJSON bridge over the --json protocol — each
    // session is a `harness --json` child of this same binary. Keys are
    // loaded by the children, not here.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "serve")) {
        const token = token_flag orelse init.environ_map.get("HARNESS_SERVE_TOKEN") orelse init.environ_map.get("GRAFF_SERVE_TOKEN");
        const exe = std.process.executablePathAlloc(io, arena) catch
            std.process.fatal("serve: cannot resolve own executable path", .{});
        try serve.serveMain(gpa, io, .{
            .host = host_flag,
            .port = port_flag,
            .token = token,
            .yolo = yolo_flag,
            .model = model_flag,
            .system_prompt = system_prompt_flag,
            .append_system_prompt = append_system_flag,
        }, exe);
        return;
    }

    // `harness update [--force|--check]`: self-update to the latest GitHub
    // release. Version-checked (skips if already current), reuses install.sh
    // for the actual download/codesign/atomic swap. Exits after.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "update")) {
        // --check never installs, so --force has no effect on it — reject the
        // contradictory combination up front rather than silently ignoring one.
        if (update_force and update_check)
            std.process.fatal("--force and --check are mutually exclusive — use `graff update` (without --check) to install", .{});
        try updateCommand(io, gpa, arena, init.environ_map, update_force, update_check);
        return;
    }

    // `graff worktree list` / `graff worktree merge <name>`: manage the per-tab
    // scratch worktrees that -w creates. merge squash-lands a tab's work as one
    // clean commit on the current branch, then removes the worktree + branch.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "worktree")) {
        try worktreeCommand(gpa, io, arena, positionals.items[1..]);
        return;
    }

    // `graff sandboxes [stop <id>]`: list the account's gateway sandboxes or
    // spin one down. Key resolution mirrors a normal run: CODEGRAFF_API_KEY
    // env first, else the `graff login` file via loadCodegraffKey.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "sandboxes")) {
        const cg_key = init.environ_map.get("CODEGRAFF_API_KEY") orelse
            (if (homeEnv(init.environ_map)) |home| oauth.loadCodegraffKey(io, arena, home) else null) orelse
            std.process.fatal("sandboxes: no codegraff key — run `graff login` first", .{});
        try cube.sandboxesCommand(io, gpa, arena, cg_key, positionals.items[1..]);
        return;
    }

    // `graff cube [new|status|stop]`: a personal cloud graff — a gateway
    // sandbox running `graff serve` behind a Daytona preview URL. This is the
    // broker the iOS app mirrors; any serve client can attach with the
    // printed base + token.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "cube")) {
        const cg_key = init.environ_map.get("CODEGRAFF_API_KEY") orelse
            (if (homeEnv(init.environ_map)) |home| oauth.loadCodegraffKey(io, arena, home) else null) orelse
            std.process.fatal("cube: no codegraff key — run `graff login` first", .{});
        try cube.cubeCommand(io, gpa, arena, cg_key, positionals.items[1..]);
        return;
    }

    // `--schema`: print the machine-readable interface and exit. No keys,
    // network, or MCP — so it works anywhere (CI codegen calls this).
    if (schema_flag) {
        var sbuf: [8 * 1024]u8 = undefined;
        var sw = Io.File.stdout().writer(io, &sbuf);
        try emitSchema(&sw.interface);
        return;
    }
    var keys: Keys = .{ .values = undefined };
    for (provider_specs, &keys.values) |spec, *value| {
        value.* = init.environ_map.get(spec.env_key);
    }
    // Codegraff "login": if CODEGRAFF_API_KEY isn't set, pick up a key from
    // `harness login codegraff` (~/.simple-harness-codegraff.json) or graff's
    // own store (~/forge/.credentials.json) — read-only, env always wins.
    if (homeEnv(init.environ_map)) |home| {
        for (provider_specs, &keys.values) |spec, *value| {
            if (std.mem.eql(u8, spec.id, "codegraff") and value.* == null)
                value.* = oauth.loadCodegraffKey(io, arena, home);
        }
    }
    // Codex "login": read the ChatGPT OAuth token from ~/.codex/auth.json
    // (written by the Codex CLI) instead of an env var — same on-disk
    // credential pattern as the codegraff key in ~/forge/.credentials.json.
    var codex_account: ?[]const u8 = null;
    if (homeEnv(init.environ_map)) |home| {
        if (oauth.loadCodexAuth(io, arena, home)) |auth| {
            for (provider_specs, &keys.values) |spec, *value| {
                if (std.mem.eql(u8, spec.id, "codex")) value.* = auth.token;
            }
            keys.codex_account = auth.account;
            codex_account = auth.account;
        }
    }
    // Kimi "login": OAuth device-flow token from `graff login kimi`
    // (~/.kimi/credentials/graff-oauth.json), refreshed in place when near
    // expiry. Same on-disk-credential pattern as codex/codegraff; env wins.
    if (homeEnv(init.environ_map)) |home| {
        for (provider_specs, &keys.values) |spec, *value| {
            if (std.mem.eql(u8, spec.id, "kimi") and value.* == null)
                value.* = oauth.loadKimiOAuth(io, gpa, arena, home);
        }
    }
    // Stored keys (macOS Keychain / 0600 file via `harness key set`): fill any
    // provider slot still empty after env + the login loaders. env always wins.
    if (homeEnv(init.environ_map)) |home| {
        for (provider_specs, &keys.values) |spec, *value| {
            if (value.* == null) value.* = loadStoredKey(io, arena, home, spec.id);
        }
    }
    var default_provider = keys.defaultProvider() catch {
        std.process.fatal(
            \\no API key found. quickest fixes:
            \\  graff login                         free codegraff key (device-code OAuth)
            \\  graff key set <provider> <key>      store a key (macOS Keychain, else 0600 file)
            \\  export ANTHROPIC_API_KEY=sk-ant-…   or CODEGRAFF/DEEPSEEK/OPENAI/MINIMAX/XIAOMI/KIMI/MOONSHOT/XAI/ZAI _API_KEY
            \\a Codex CLI login (~/.codex/auth.json) is also picked up automatically.
        , .{});
    };
    var stale_saved_model: ?[]const u8 = null;
    // `--model <name|provider>` pins the startup model (same resolution as /model).
    if (model_flag) |mname| pick: {
        for (provider_specs) |spec| if (std.mem.eql(u8, spec.id, mname)) {
            if (keys.providerById(spec.id, spec.default_model)) |p| {
                default_provider = p;
                break :pick;
            } else |_| std.process.fatal("no key/login for provider '{s}' (--model)", .{mname});
        };
        const nm = resolveModelName(keys, mname) orelse mname;
        default_provider = keys.providerFor(nm) catch std.process.fatal("no key/login for --model '{s}' — see /models", .{mname});
    } else if (loadModel(io, arena, homeEnv(init.environ_map) orelse "")) |saved| {
        // No --model flag: resume the model chosen last session only if that
        // exact provider/model pair is still in the catalog; model names can be
        // shared by providers with different support.
        if (providerModelInTable(saved.pid, saved.model)) {
            if (keys.providerById(saved.pid, saved.model)) |p| default_provider = p else |_| {}
        } else stale_saved_model = saved.model;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const in = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;
    g_out = out;

    // `graff title <prompt>` — print the tab-title the model would generate for
    // that prompt (one title call, no session). For A/B-ing title prompts/styles.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "title")) {
        if (positionals.items.len < 2) std.process.fatal("usage: graff title <prompt>", .{});
        const tprompt = try std.mem.join(arena, " ", positionals.items[1..]);
        if (titleTask(gpa, io, &client, default_provider, tprompt)) |t| {
            defer gpa.free(t);
            try out.print("{s}\n", .{t});
        } else try out.writeAll("(title generation failed — check your model/key)\n");
        try out.flush();
        return;
    }

    // Color only on an interactive terminal, and honor NO_COLOR.
    if (init.environ_map.get("NO_COLOR") == null and (Io.File.stdout().isTty(io) catch false)) {
        ansi.style = Style.ansi;
        use_color = true;
    }
    // --worktree/-w: run this session in an isolated git worktree so parallel
    // agents don't collide on files. Creates .graff/worktrees/<name> on branch
    // worktree-<name> (from HEAD) and enters it; reuses it if it already exists.
    if (worktree_flag) |wt| {
        // POSIX-only: the chdir below goes through libc's `chdir`, which Windows
        // builds don't link. -w is a parallel-agent dev workflow (mac/linux); on
        // Windows we bail with a clear message rather than break the cross-build.
        // The comptime `if` elides the chdir branch entirely on Windows.
        if (builtin.os.tag == .windows) {
            std.process.fatal("--worktree is not yet supported on Windows (POSIX-only chdir) — run without -w", .{});
        } else {
            const wt_path = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{wt});
            const wt_branch = try std.fmt.allocPrint(arena, "worktree-{s}", .{wt});
            if (runCapped(gpa, io, &.{ "git", "worktree", "add", wt_path, "-b", wt_branch }, 8192, 8192, 60_000)) |r| {
                gpa.free(r.stdout);
                gpa.free(r.stderr);
            } else |_| {}
            const wt_z = arena.dupeZ(u8, wt_path) catch std.process.fatal("--worktree: out of memory", .{});
            if (std.posix.system.chdir(wt_z.ptr) != 0)
                std.process.fatal("--worktree '{s}': could not enter {s} (is this a git repository?)", .{ wt, wt_path });
            g_worktree_branch = wt_branch; // non-null = auto-commit each turn to this scratch branch
            if (!json_mode) {
                const ac: []const u8 = if (g_worktree_autocommit) " · auto-committing each turn (`graff worktree merge` to land it)" else "";
                out.print("{s}worktree:{s} {s}{s}{s} (branch {s}) — edits isolated from the main checkout{s}\n", .{ style.dim, style.reset, style.cyan, wt_path, style.reset, wt_branch, ac }) catch {};
                out.flush() catch {};
            }
        }
    }
    var cwd_buf: [4096]u8 = undefined;
    g_cwd_display = if (worktree_flag) |wt|
        // After chdir into the worktree, realPath(AT_FDCWD) is unreliable; derive from the launch dir.
        std.fmt.allocPrint(arena, "{s}/.graff/worktrees/{s}", .{ init.environ_map.get("PWD") orelse ".", wt }) catch try arena.dupe(u8, init.environ_map.get("PWD") orelse ".")
    else if (Io.Dir.cwd().realPath(io, &cwd_buf)) |n|
        try arena.dupe(u8, cwd_buf[0..n])
    else |_|
        try arena.dupe(u8, init.environ_map.get("PWD") orelse ".");

    if (!json_mode and oneshot_prompt == null) {
        try out.print("{s}codegraff{s} · folder: {s}{s}{s} · / for commands · @ picks a file · esc interrupts · ↑/↓ history · tab completes · ctrl-d quits · trace → {s}\n", .{ style.bold, style.reset, style.cyan, g_cwd_display, style.reset, trace_path });
        try out.flush();
        if (codex_account) |acct| {
            try out.print("logged into Codex (ChatGPT account {s}…) — /model gpt-5.5\n", .{acct[0..@min(acct.len, 8)]});
            try out.flush();
        }
        if (yolo_flag) {
            try out.print("⚠ yolo mode (--yolo): all bash/tool/MCP permission prompts are skipped\n", .{});
            try out.flush();
        }
        if (stale_saved_model) |nm| {
            try out.print("{s}note: remembered model '{s}' isn't in the model table — starting on {s} instead{s}\n", .{ style.dim, nm, default_provider.model, style.reset });
            try out.flush();
        }
        if (show_timing or show_cost) {
            try out.print("{s}displays on:{s}{s}{s}\n", .{
                style.dim,
                if (show_timing) " per-tool timing" else "",
                if (show_cost) " session cost" else "",
                style.reset,
            });
            try out.flush();
        }
    }

    // Session trace (best-effort: a failed open just disables tracing).
    const trace_file: ?Io.File = Io.Dir.cwd().createFile(io, trace_path, .{}) catch null;
    defer if (trace_file) |f| f.close(io);
    var trace_buf: [8 * 1024]u8 = undefined;
    var trace_writer = if (trace_file) |f| f.writer(io, &trace_buf) else undefined;
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = if (trace_file != null) &trace_writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
    };

    // Trajectory archive (DGM-style tree; best-effort like the trace).
    // Unlike the trace it is APPEND-ONLY: the file accumulates across
    // sessions — it IS the archive a DGM-style driver selects parents from.
    // Each session starts with a `kind:"session"` header (node ids restart
    // per session; cross-session lineage threads through prompt_sha).
    const traj_file: ?Io.File = Io.Dir.cwd().createFile(io, trajectory_path, .{ .truncate = false }) catch null;
    defer if (traj_file) |f| f.close(io);
    var traj_buf: [8 * 1024]u8 = undefined;
    var traj_writer = if (traj_file) |f| f.writer(io, &traj_buf) else undefined;
    if (traj_file != null) {
        if (Io.Dir.cwd().statFile(io, trajectory_path, .{})) |st| {
            traj_writer.pos = st.size; // append after prior sessions
        } else |_| {}
    }
    var traj: Trajectory = .{
        .io = io,
        .gpa = gpa,
        .out = if (traj_file != null) &traj_writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
    };
    trace.g_traj = &traj;
    defer {
        trace.g_traj = null;
        traj.deinit();
    }
    traj.node(.{ .kind = "session", .version = harness_version, .unix_ms = unixMs(io) });

    // Score-channel signing (Step 0): a per-session run_id and, if
    // GRAFF_SCORE_KEY_FILE is set, the HMAC key — so score records written
    // this session are signed and forged trajectory rows are detectable.
    {
        var raw: [8]u8 = undefined;
        io.random(&raw);
        scoring.g_run_id = std.fmt.bytesToHex(raw, .lower);
    }
    scoring.g_score_key = loadScoreKey(io, arena, init.environ_map);

    // Telemetry endpoint precedence: opt-out always wins → else an
    // env-configured endpoint (dev / override) → else the release build's
    // baked-in default (build_options.telemetry_endpoint, empty in dev). The
    // install id file is only created when an endpoint is live.
    const telem_endpoint: []const u8 = if (no_telemetry_flag or init.environ_map.get("GRAFF_NO_TELEMETRY") != null)
        ""
    else
        init.environ_map.get("OTEL_EXPORTER_OTLP_ENDPOINT") orelse
            init.environ_map.get("GRAFF_OTEL_ENDPOINT") orelse
            default_telemetry_endpoint;
    const telem_home = homeEnv(init.environ_map) orelse "";
    var telem: Telemetry = .{
        .io = io,
        .gpa = gpa,
        .client = &client,
        .endpoint = telem_endpoint,
        .install_id = if (telem_endpoint.len > 0) loadOrCreateId(io, gpa, telem_home, ".simple-harness-install-id") else @splat('0'),
        .client_name = init.environ_map.get("HARNESS_CLIENT") orelse "harness",
        .sdk_install_id = init.environ_map.get("HARNESS_SDK_INSTALL_ID") orelse "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = unixMs(io),
    };
    telemetry.g_telem = &telem;
    // Fleet contribution opt-out, independent of telemetry: GRAFF_FLEET=off|0|false|no.
    if (init.environ_map.get("GRAFF_FLEET")) |fv| {
        g_fleet = !(std.ascii.eqlIgnoreCase(fv, "off") or std.mem.eql(u8, fv, "0") or std.ascii.eqlIgnoreCase(fv, "false") or std.ascii.eqlIgnoreCase(fv, "no"));
    }
    defer {
        telemetry.g_telem = null;
        telem.flush();
        telem.deinit();
    }

    // MCP servers from .mcp.json. SECURITY: a workspace .mcp.json launches
    // arbitrary local commands, so opening an untrusted repo could run them.
    // Auto-connect only with --yolo (trusted) or explicit per-session consent;
    // otherwise start with an empty (but live) registry so `/mcp add` still works.
    const mcp_count = countMcpServers(io, arena);
    var connect_mcp = yolo_flag or mcp_count == 0;
    if (mcp_count > 0 and !yolo_flag and !json_mode and use_color) {
        try out.print("{s}⚠ this workspace's .mcp.json defines {d} MCP server(s) that run local commands. Connect them this session? [y/N] {s}", .{ style.bold, mcp_count, style.reset });
        try out.flush();
        const ans = in.takeDelimiter('\n') catch null;
        connect_mcp = ans != null and ans.?.len > 0 and (ans.?[0] == 'y' or ans.?[0] == 'Y');
    }
    var registry_storage: mcp.Registry = if (connect_mcp) ((mcp.Registry.init(gpa, io, mcp_config_path) catch |err| inner: {
        try out.print("[mcp] init failed: {t} — continuing without MCP\n", .{err});
        if (telemetry.g_telem) |t| t.errorEvent("mcp", @errorName(err));
        break :inner null;
    }) orelse mcp.Registry.empty(gpa, io)) else outer: {
        if (mcp_count > 0) try out.print("{s}skipped {d} workspace MCP server(s) — /mcp trust to connect them now (or re-run with --yolo){s}\n", .{ style.dim, mcp_count, style.reset });
        break :outer mcp.Registry.empty(gpa, io);
    };
    defer registry_storage.deinit();
    const registry: ?*mcp.Registry = &registry_storage;
    // Companion auto-activation: if the metered code-intelligence companion
    // (codedb-pro, formerly muonry) is installed but nothing connected it (no
    // workspace .mcp.json entry, or consent declined), spawn it directly — a
    // user-installed companion at the same trust level as the skills
    // auto-detection above it, NOT arbitrary workspace config. Failure just
    // means native tools; the mcp_notes usage line below only enters context
    // when the connect actually succeeded. Opt out like a skill:
    // {"skills": {"codedbpro": false}}.
    g_path_env = try arena.dupe(u8, init.environ_map.get("PATH") orelse "");
    g_codedb_guard = init.environ_map.get("GRAFF_NO_CODEDB_GUARD") == null; // issue #626 guard, opt-out via env
    loadSkillSettings(io, arena); // per-skill opt-outs, also gates the auto-connect
    anim.loadAnimationSetting(io, arena); // {"animation": "..."} → thinking spinner choice
    anim.loadThemeSetting(io, arena); // {"theme": "<name>"} → opt-in terminal color theme
    const theme_on = anim.g_theme != null and use_color and !json_mode;
    if (theme_on) {
        out.writeAll(anim.themes[anim.g_theme.?].seq) catch {};
        out.flush() catch {};
    }
    defer if (theme_on) {
        out.writeAll(anim.theme_reset) catch {};
        out.flush() catch {};
    };
    // 🎂 yxlyx's birthday glam — when graff runs from her home dir, dress her
    // Ghostty in the pastel-pink theme (limyuxi_theme: light pink bg, dark plum
    // text, pink-leaning palette) and switch the spinner to glittery sparkles.
    // Cosmetic, flagged, gated to her cwd; resets everything on exit.
    const limyuxi_glam = anim.limyuxi_birthday_white and use_color and !json_mode and
        (std.mem.eql(u8, g_cwd_display, "/Users/limyuxi") or std.mem.startsWith(u8, g_cwd_display, "/Users/limyuxi/"));
    if (limyuxi_glam) {
        out.writeAll(anim.limyuxi_theme) catch {};
        out.flush() catch {};
        if (anim.animIndex("dragon")) |gi| {
            anim.g_anim_index = gi;
            anim.g_anim_off = false;
            anim.g_anim_random = false;
        }
    }
    defer if (limyuxi_glam) {
        out.writeAll(anim.limyuxi_reset) catch {};
        out.flush() catch {};
    };
    if (selftest_spinner_flag) {
        // Headless render of the real thinking-spinner pool for the PTY anti-stealth
        // test (scripts/test-pty-spinner.py): runs the real selection (so a cwd-gated
        // pick surfaces) and prints every frame fn's output to stdout, where the test
        // scans for the U+1F4A9 / supplementary-plane glyph class the poop hid in.
        anim.selectSpinner(io);
        out.print("selected: {s}\n", .{anim.anims[anim.g_anim_current].name}) catch {};
        for (anim.anims) |a| {
            var i: usize = 0;
            while (i < 48) : (i += 1) {
                a.frame(out, i) catch {};
                out.writeByte('\n') catch {};
            }
        }
        out.flush() catch {};
        return;
    }
    anim.loadDevSpinnerOptOut(io, arena, init.environ_map);
    connect: {
        for (companion_servers) |c| if (mcpServerConnected(registry_storage.tools, c.server)) break :connect;
        for (companion_servers) |c| {
            if (companionDisabled(c.server) or !binOnPath(io, c.bin)) continue;
            if (registry_storage.addServer(c.server, c.bin, &.{"--mcp"})) |_| {
                break;
            } else |err| {
                if (!json_mode and oneshot_prompt == null) {
                    try out.print("{s}[mcp:{s}] auto-connect failed ({t}) — native tools only{s}\n", .{ style.dim, c.server, err, style.reset });
                    try out.flush();
                }
            }
        }
    }
    const mcp_tools: []const mcp.Tool = registry_storage.tools;
    // If the metered companion connected, probe its license once so the note
    // below can lean into the paid tools (vs the conservative free-codedb note).
    if (mcpServerConnected(mcp_tools, "codedbpro")) g_codedbpro_licensed = probeCodedbproLicensed(gpa, io);

    var approvals: Approvals = .{ .yolo = yolo_flag };
    defer {
        for (approvals.prefixes.items) |p| gpa.free(p);
        approvals.prefixes.deinit(gpa);
    }
    const persisted_approvals = approvals.loadPersisted(io, gpa, arena);

    // Agent types: builtins + .harness/agents/*.md (the MAP-Elites niches).
    fleet.g_home = homeEnv(init.environ_map); // for /agents promote's personal tier
    fleet.g_agent_types = loadAgentTypes(io, arena, fleet.g_home); // builtin < ~/.harness/agents (personal) < ./.harness/agents (private)
    if (persisted_approvals > 0 and !json_mode and oneshot_prompt == null) {
        try out.print("{s}loaded {d} saved approval(s) from {s}{s}\n", .{ style.dim, persisted_approvals, Approvals.settings_path, style.reset });
        try out.flush();
    }
    // Lifecycle hooks (pre_tool/post_tool/turn_end) from the same file.
    // (Per-skill opt-outs were loaded earlier, before the muonry auto-connect.)
    g_hooks = hooks.loadHooks(io, arena);
    if (g_hooks.total() > 0 and !json_mode and oneshot_prompt == null) {
        try out.print("{s}loaded {d} lifecycle hook(s) from {s} — /hooks lists them{s}\n", .{ style.dim, g_hooks.total(), Approvals.settings_path, style.reset });
        try out.flush();
    }

    // Root system prompt layering, frozen at startup so it stays
    // KV-cache-friendly: built-in base (or its --system-prompt replacement),
    // then project instructions from the first of AGENTS.md/HARNESS.md/
    // CLAUDE.md found in the cwd, then --append-system-prompt text.
    const base_prompt: []const u8 = system_prompt_flag orelse main_system_prompt;
    var sys_normal: []const u8 = base_prompt;
    for ([_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" }) |fname| {
        const body = Io.Dir.cwd().readFileAlloc(io, fname, arena, .limited(64 * 1024)) catch continue;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) continue;
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n# Project instructions (from {s})\n{s}", .{ base_prompt, fname, trimmed });
        if (!json_mode and oneshot_prompt == null) {
            try out.print("loaded project instructions from {s} ({d} bytes)\n", .{ fname, trimmed.len });
            try out.flush();
        }
        break;
    }
    if (append_system_flag) |extra| {
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, extra });
    }
    // Codex-style skills: one capability line per installed optional
    // companion (skills_registry) — metadata in context, --help on demand.
    // (g_path_env was captured earlier, before the muonry auto-connect.)
    for (skills_registry) |sk| {
        if (sk.note.len == 0 or !skillActive(io, sk)) continue;
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, sk.note });
    }
    // Same idea for known MCP servers: a usage note enters the context only
    // when the server actually connected this session (consent given, spawn
    // succeeded). Native tools remain the fallback either way.
    for (mcp_notes) |mn| {
        if (!mcpServerConnected(mcp_tools, mn.server)) continue;
        const note = codedbproNote(mn.server, g_codedbpro_licensed, mn.note);
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, note });
    }
    const sys_strict: []const u8 = try std.fmt.allocPrint(arena, "{s}{s}", .{ sys_normal, strict_note });

    var snaps: Snapshots = .{ .gpa = gpa, .io = io };
    defer snaps.deinit();
    // Background bash jobs die with the session: kill, await pumps, free.
    defer jobsReap(gpa, io);
    var root: Agent = .{
        .snapshots = &snaps,
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = default_provider,
        .home = homeEnv(init.environ_map) orelse "",
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "main",
        .out = out,
        .in = in,
        .registry = registry,
        .approvals = &approvals,
        .tracer = &tracer,
        .sys_normal = sys_normal,
        .sys_strict = sys_strict,
        .tools_anthropic = try renderRootTools(arena, .anthropic, &root_specs, mcp_tools),
        .tools_openai = try renderRootTools(arena, .openai, &root_specs, mcp_tools),
        .tools_responses = try renderRootTools(arena, .responses, &root_specs, mcp_tools),
    };
    const fresh_session_name = try std.fmt.allocPrint(arena, "session-{d}", .{unixMs(io)});
    root.session_name = if (resume_flag) |name| (if (!new_session_flag and !no_resume_flag) name else fresh_session_name) else fresh_session_name;
    loadThinkingSettings(io, arena, &root); // {"effort":...,"fast":...} persisted by /effort and /fast
    if (goal_flag) |g| root.goal = try arena.dupe(u8, g); // --goal applies to every turn (incl. --json/-p/SDK)
    if (eval_cmd_flag) |c| root.eval_cmd = try arena.dupe(u8, c);
    if (eval_target_flag) |t| root.eval_target = t;
    if (eval_niche_flag) |n| root.eval_niche = try arena.dupe(u8, n);
    tracer.note("session", root.provider.model);
    // Distribute (docs §9.E): pull this tier's live fleet champions and prefer
    // them over the baked builtins. Best-effort + bounded; emits fleet:elite_pull.
    var esh_pull: [16]u8 = undefined;
    const pull_esh: []const u8 = if (root.eval_cmd) |c| pblk: {
        esh_pull = promptFingerprint(c);
        break :pblk &esh_pull;
    } else ""; // pull the champion for our eval suite (if any)
    // Background the fleet-champion pull: a ~0.3s TLS round-trip that used to block
    // the first prompt. Spawn it now; joinElites() reaps it on the main thread at the
    // first turn, so the user's typing hides the fetch (prompt paints ~0.3s sooner).
    fleet.g_elites_future = io.async(pullElites, .{ io, arena, &client, telemetry.g_telem, telem_endpoint, providerClass(root.provider.model), arena.dupe(u8, pull_esh) catch pull_esh, fleet.g_agent_types });
    defer joinElites(io); // reap if the session quits before any turn joins it

    // Save from the start: if the harness is killed (Ctrl+C / SIGINT) before
    // any turn completes, the session file is already on disk with the initial
    // state (provider, model, settings) so nothing is lost. EXCEPT when
    // resuming: the resume target already holds the real conversation and
    // loadSession below restores it — writing the empty initial state here
    // would clobber the very session we're about to read back (data loss).
    const will_resume = resume_flag != null and !new_session_flag and !no_resume_flag;
    if (!will_resume) saveSession(&root, arena, root.session_name) catch {};

    if (oneshot_prompt != null and resume_flag != null and !new_session_flag and !no_resume_flag) {
        loadSession(&root, keys, arena, root.session_name) catch {};
    }

    // `graff repl`: interactive chat REPL on the zigzag TUI, backed by the REAL
    // agent loop — each prompt runs a full root turn (tools + MCP) via
    // replTurnCb, reusing the root agent's tool set + registry + system prompt.
    // Self-contained — exits after.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "repl")) {
        var repl_ctx = ReplCtx{
            .io = io,
            .client = &client,
            .provider = root.provider,
            .registry = root.registry,
            .sys_normal = root.sys_normal,
            .tools_anthropic = root.tools_anthropic,
            .tools_openai = root.tools_openai,
            .tools_responses = root.tools_responses,
        };
        var models_buf = std.array_list.Managed(u8).init(arena);
        for (model_table) |mi| {
            if (mi.name.len == 0) continue;
            if (models_buf.items.len != 0) models_buf.appendSlice(", ") catch {};
            models_buf.appendSlice(mi.name) catch {};
        }
        if (Io.File.stdin().isTty(io) catch true)
            try repl.run(gpa, io, init.environ_map, &repl_ctx, replTurnCb, replModelCb, replCancelCb, root.provider.model, models_buf.items)
        else
            try repl.runScripted(gpa, io, init.environ_map, in, out, &repl_ctx, replTurnCb, replModelCb, replCancelCb, root.provider.model, models_buf.items);
        return;
    }
    // One-shot print mode: run the single prompt to completion, print the
    // final text to stdout, exit. Tool progress goes to stderr (say() with no
    // out writer), streaming stays quiet, and the gate denies anything not
    // pre-approved instead of prompting (there's no one to ask).
    if (oneshot_prompt) |prompt_text| {
        unattended = true;
        root.in = null; // gate: deny instead of prompt; ask_user: self-decide
        root.out = null; // tool progress → stderr; stdout carries only the answer
        root.stream_quiet = true;
        const ultracode_msg = try applyUltracodeSteering(arena, prompt_text, root.ultracode_mode);
        if (ultracode_msg.explicit) {
            tracer.note("ultracode", prompt_text[0..@min(prompt_text.len, 120)]);
            if (telemetry.g_telem) |t| t.ultracode();
        }
        const goal_note = try goalSteeringNote(arena, root.goal, if (root.todos.items.len > 0) root.renderTodos() else "");
        const eval_note = try evalSteeringNote(arena, root.eval_cmd, root.eval_target, root.eval_judge != null);
        var oneshot_user = if (goal_note.len > 0) try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ ultracode_msg.text, goal_note }) else ultracode_msg.text;
        if (eval_note.len > 0) oneshot_user = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ oneshot_user, eval_note });
        try root.messages.append(try textMessage(arena, "user", oneshot_user));
        if (telemetry.g_telem) |t| t.countTurn();
        const final_text = root.runTurn() catch |err| switch (err) {
            error.ApiError => std.process.fatal("{s}", .{root.last_api_error orelse "api error"}),
            else => |e| std.process.fatal("turn failed: {t}", .{e}),
        };
        try out.print("{s}\n", .{final_text});
        try out.flush();
        // Usage summary → stderr, so stdout stays exactly the answer.
        var ubuf: [256]u8 = undefined;
        var uw: Io.Writer = .fixed(&ubuf);
        if (CostTally.render(g_cost.snap(io), &uw)) {
            std.debug.print("[usage] {s}\n", .{uw.buffered()});
        } else |_| {}
        saveSession(&root, arena, root.session_name) catch |err| {
            std.debug.print("⚠ session save failed: {s}\n", .{@errorName(err)});
        };

        // --worktree: checkpoint the one-shot's edits to the scratch branch too.
        // Headless swarm agents (graff -w name -p "task") are the main -w use
        // case — they must not exit with their work left uncommitted.
        worktreeAutoCommit(gpa, io, std.fmt.allocPrint(arena, "wip: {s}", .{titleFromPrompt(prompt_text)}) catch "wip: graff oneshot");
        // One-shot returns here, before the REPL cleanup defer below is even
        // registered, so free the root's gpa-backed buffers explicitly (else a
        // tool-using one-shot leaks its tool log / render buffers on exit).
        root.md_buf.deinit(gpa);
        root.md_word.deinit(gpa);
        for (root.md_table.items) |r| gpa.free(r);
        root.md_table.deinit(gpa);
        root.tools_used.deinit(gpa);
        return;
    }

    // Input-line history (persisted to ~/.simple-harness-history) + editor buffer.
    var history: std.ArrayList([]const u8) = .empty;
    var linebuf: std.ArrayList(u8) = .empty;
    if (homeEnv(init.environ_map)) |home| loadHistory(io, gpa, home, &history);
    defer {
        if (homeEnv(init.environ_map)) |home| saveHistory(io, arena, home, history.items);
        for (history.items) |h| gpa.free(h);
        history.deinit(gpa);
        linebuf.deinit(gpa);
        root.md_buf.deinit(gpa); // streamed-markdown line buffer
        root.md_word.deinit(gpa); // streamed-markdown wrap word buffer
        for (root.md_table.items) |r| gpa.free(r);
        root.md_table.deinit(gpa);
        root.tools_used.deinit(gpa);
    }
    const interactive = use_color and !json_mode; // stdout is a TTY → enable line editing

    // Trajectory spine state: each turn's parent is the previous turn, and a
    // changed prompt fingerprint marks a set_system_prompt mutation edge.
    var prev_turn_id: u64 = 0;
    var prev_prompt_fp: [16]u8 = promptFingerprint(root.systemPrompt());

    // Explicit resume only: bare `graff` starts fresh, while `--resume <name>`
    // restores that autosave target. Best-effort: a missing/keyless/corrupt
    // file silently starts fresh.
    if (oneshot_prompt == null and resume_flag != null and !new_session_flag and !no_resume_flag) {
        if (loadSession(&root, keys, arena, root.session_name)) |_| {
            if (root.messages.items.len > 0) {
                // Estimate the restored context from the file size (~4 bytes/token).
                const est_path = try sessionPath(arena, root.session_name);
                const est: u64 = if (Io.Dir.cwd().statFile(io, est_path, .{})) |st| @as(u64, @intCast(st.size)) / 4 else |_| 0;
                if (!json_mode) {
                    // Prefer the saved AI summary; fall back to the first user
                    // message only for older sessions that have no saved title.
                    const restored_title = root.session_title orelse firstUserTitle(arena, root.messages);
                    setTerminalTitle(out, restored_title, g_cwd_display);
                    try printSessionHeader(out, restored_title, g_cwd_display);
                    root.tui_header_shown = true;
                    try out.print("↩ resumed {s}{s} — {d} message(s) on {s} · /new or /clear for a fresh start\n", .{ root.session_name, session_ext, root.messages.items.len, root.provider.model });
                    try out.flush();
                }
                // Cold cache: if the restored context is as large as what would
                // trigger live compaction, the first turn would re-bill the whole
                // thing — summarize up front instead.
                if (est >= root.provider.compactAt()) {
                    root.last_context_tokens = est;
                    root.compactOrRecover(true);
                }
            }
        } else |_| {}
    }

    while (true) {
        // Steering drain: prompts typed while the previous turn streamed
        // were captured into g_steer_queue. Run them now, one after
        // another, in place of reading a fresh line — Codex-style
        // follow-up queueing. (Empty in --json/GUI mode: no capture.)
        resetSteerPartial();
        const steer_entry: ?SteerEntry = popSteer();
        defer if (steer_entry) |e| std.heap.page_allocator.free(e.text);
        const raw_line: []const u8 = if (steer_entry) |e| blk: {
            if (e.force) {
                try out.print("{s}↳ force ›{s} {s}\n", .{ style.yellow, style.reset, e.text });
            } else {
                try out.print("{s}↳ steer ›{s} {s}\n", .{ style.cyan, style.reset, e.text });
            }
            try out.flush();
            break :blk e.text;
        } else if (interactive) blk: {
            try root.prompt();
            break :blk (try readLine(&root, in, out, gpa, &history, &linebuf)) orelse break;
        } else (try in.takeDelimiter('\n')) orelse break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const loop_prompt: ?[]const u8 = if (!json_mode and std.mem.startsWith(u8, line, "/loop "))
            std.mem.trim(u8, line["/loop".len..], " \t")
        else
            null;
        if (!json_mode) {
            const l = if (line.len > 0 and line[0] == '/') line[1..] else line;
            if (std.mem.eql(u8, l, "exit") or std.mem.eql(u8, l, "quit") or std.mem.eql(u8, l, "q")) break;
        }

        if (!json_mode and isSlashCommandLine(line) and loop_prompt == null) {
            // Bare "/" on a TTY: open the filterable command menu.
            if (interactive and line.len == 1) {
                if (listPicker(&root, arena, out, "Command ›", &command_menu)) |idx| {
                    try handleCommand(&root, &keys, arena, command_menu[idx].name, out);
                }
                continue;
            }
            try handleCommand(&root, &keys, arena, line, out);
            continue;
        }

        // The user message for this turn. In --json mode each input line is a
        // {"type":"user","text":"..."} request; {"type":"set_system_prompt",
        // "text":"...","append":bool} mutates the root system prompt between
        // turns (append=true tacks onto the current prompt instead of
        // replacing it) and acks with a system_prompt event — no turn runs;
        // {"type":"score","prompt_sha":"...","score":0.7,"notes":"..."}
        // appends an evaluation record for an agent variant to the
        // trajectory archive (the DGM evaluation phase writing back).
        const base_msg: []const u8 = if (loop_prompt) |lp| lp else if (json_mode) blk: {
            const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{ .allocate = .alloc_always }) catch {
                root.emit(.{ .type = "error", .message = "invalid JSON (expect {\"type\":\"user\",\"text\":\"...\"})" });
                continue;
            };
            const rtype = if (parsed == .object)
                (if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "")
            else
                "";
            if (std.mem.eql(u8, rtype, "set_model")) {
                const provider_field = if (parsed.object.get("provider")) |v| (if (v == .string) v.string else "") else "";
                const model_field = if (parsed.object.get("model")) |v| (if (v == .string) v.string else "") else "";
                const legacy_name = if (parsed.object.get("name")) |v| (if (v == .string) v.string else "") else "";
                const provider = resolveProviderControlRequest(&keys, arena, provider_field, model_field, legacy_name) catch |err| {
                    const label = setModelRequestLabel(arena, provider_field, model_field, legacy_name) catch "<requested model>";
                    const message = switch (err) {
                        error.MissingKey => try std.fmt.allocPrint(arena, "no key/login for requested model '{s}'", .{label}),
                        error.InvalidModelRequest => "set_model needs a non-empty provider/model or legacy name",
                        else => try std.fmt.allocPrint(arena, "failed to switch model '{s}': {s}", .{ label, @errorName(err) }),
                    };
                    root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                const note = applyProvider(&root, arena, provider);
                root.emit(.{ .type = "model", .ok = true, .provider = provider.id, .model = provider.model, .context = provider.context, .note = note });
                continue;
            }
            if (std.mem.eql(u8, rtype, "compact")) {
                const chars = root.compact() catch |err| {
                    const message = switch (err) {
                        error.EmptySummary => "compaction failed: empty summary, history unchanged",
                        else => try std.fmt.allocPrint(arena, "compaction failed: {s}", .{@errorName(err)}),
                    };
                    root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                root.emit(.{ .type = "compact", .ok = true, .chars = chars });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_mode")) {
                const mode = if (parsed.object.get("mode")) |v| (if (v == .string) v.string else "") else "";
                if (std.mem.eql(u8, mode, "plan")) {
                    plan_mode = true;
                } else if (std.mem.eql(u8, mode, "normal")) {
                    plan_mode = false;
                } else {
                    root.emit(.{ .type = "error", .message = "set_mode needs mode 'plan' or 'normal'" });
                    continue;
                }
                root.emit(.{ .type = "mode", .ok = true, .mode = mode });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_agent")) {
                const id = if (parsed.object.get("id")) |v| (if (v == .string) v.string else "") else "";
                if (id.len == 0) {
                    root.sys_normal = sys_normal;
                    root.sys_strict = sys_strict;
                    root.emit(.{ .type = "agent", .ok = true, .id = id, .chars = root.sys_normal.len });
                    continue;
                }
                const prompt = agentTypePrompt(id) orelse {
                    const message = try std.fmt.allocPrint(arena, "unknown agent '{s}' (see /agents)", .{id});
                    root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                root.sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, prompt });
                root.sys_strict = try std.fmt.allocPrint(arena, "{s}{s}", .{ root.sys_normal, strict_note });
                root.emit(.{ .type = "agent", .ok = true, .id = id, .chars = root.sys_normal.len });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_effort")) {
                const level = if (parsed.object.get("level")) |v| (if (v == .string) v.string else "") else "";
                if (std.mem.eql(u8, level, "low")) {
                    root.reasoning = .low;
                } else if (std.mem.eql(u8, level, "medium")) {
                    root.reasoning = .medium;
                } else if (std.mem.eql(u8, level, "high")) {
                    root.reasoning = .high;
                } else {
                    root.emit(.{ .type = "error", .message = "set_effort needs level 'low', 'medium', or 'high'" });
                    continue;
                }
                _ = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
                root.emit(.{ .type = "effort", .ok = true, .level = level, .applies = root.effortApplies() });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_fast")) {
                const on = if (parsed.object.get("on")) |v| (if (v == .bool) v.bool else false) else false;
                root.fast = on;
                _ = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
                root.emit(.{ .type = "fast", .ok = true, .on = on, .applies = root.provider.kind == .responses });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_ultracode")) {
                const on = if (parsed.object.get("on")) |v| (if (v == .bool) v.bool else false) else false;
                root.ultracode_mode = on;
                _ = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
                root.emit(.{ .type = "ultracode", .ok = true, .on = on });
                continue;
            }
            if (std.mem.eql(u8, rtype, "score")) {
                const sha = if (parsed.object.get("prompt_sha")) |v| (if (v == .string) v.string else "") else "";
                const sc: f64 = if (parsed.object.get("score")) |v| switch (v) {
                    .float => |x| x,
                    .integer => |x| @floatFromInt(x),
                    else => std.math.nan(f64),
                } else std.math.nan(f64);
                if (sha.len != 16 or std.math.isNan(sc)) {
                    root.emit(.{ .type = "error", .message = "score needs prompt_sha (16 hex chars) and a numeric score" });
                    continue;
                }
                const notes = if (parsed.object.get("notes")) |v| (if (v == .string) v.string else "") else "";
                // Optional genome lineage: which prompt this variant was
                // mutated from — the children-count input for DGM parent
                // selection.
                const parent = if (parsed.object.get("parent_sha")) |v| (if (v == .string and v.string.len == 16) v.string else "") else "";
                // Provenance (Step 0): the driver names which judge produced
                // the score, the artifact it judged, and the eval-set hash;
                // run_id defaults to this session's. All are HMAC-signed so a
                // forged trajectory row is detectable.
                const reqStr = struct {
                    fn s(o: std.json.ObjectMap, k: []const u8) []const u8 {
                        return if (o.get(k)) |v| (if (v == .string) v.string else "") else "";
                    }
                };
                const judge_id = utf8Prefix(reqStr.s(parsed.object, "judge_id"), 64);
                const artifact_sha = utf8Prefix(reqStr.s(parsed.object, "artifact_sha"), 64);
                // DGM lever: when the score omits eval_set_hash but an --eval suite is
                // configured, stamp the suite's stable fingerprint so scores group into a
                // promotable (niche × tier × suite) cell. Same --eval cmd → same hash
                // across installs → the fleet can rank + promote a champion.
                var esh_buf: [16]u8 = undefined;
                const eval_set_hash = eshblk: {
                    const provided = utf8Prefix(reqStr.s(parsed.object, "eval_set_hash"), 64);
                    if (provided.len > 0) break :eshblk provided;
                    if (root.eval_cmd) |c| {
                        esh_buf = promptFingerprint(c);
                        break :eshblk @as([]const u8, &esh_buf);
                    }
                    break :eshblk "";
                };
                const req_run = reqStr.s(parsed.object, "run_id");
                const run_id: []const u8 = if (req_run.len > 0) utf8Prefix(req_run, 64) else &scoring.g_run_id;
                const sig = signScore(sha, parent, sc, run_id, judge_id, artifact_sha, eval_set_hash);
                const signed = scoring.g_score_key != null;
                if (trace.g_traj) |tj| tj.node(.{
                    .kind = "score",
                    .prompt_sha = sha,
                    .parent_sha = parent,
                    .score = sc,
                    .notes = utf8Prefix(notes, 200),
                    .run_id = run_id,
                    .judge_id = judge_id,
                    .artifact_sha = artifact_sha,
                    .eval_set_hash = eval_set_hash,
                    .sig = if (signed) @as([]const u8, &sig) else "",
                    .t = tj.elapsedMs(),
                });
                var provbuf: [512]u8 = undefined;
                // prov = judge_id, artifact_sha, eval_set_hash (the signed Step-0 fields)
                // + provider_class, niche (unsigned transport) so harness_scores can form
                // (niche x provider_class x eval_set_hash) cells the fleet ranks over.
                const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ judge_id, artifact_sha, eval_set_hash, providerClass(root.provider.model), reqStr.s(parsed.object, "niche") }) catch "";
                if (telemetry.g_telem) |t| t.scoreEvent(sha, parent, sc, run_id, if (signed) @as([]const u8, &sig) else "", prov);
                // fleet:submit (docs §9.B) — a scored, pinned-eval variant entered the fleet grid.
                if (eval_set_hash.len > 0) if (telemetry.g_telem) |t| t.fleetEvent("submit", reqStr.s(parsed.object, "niche"), sha, "", providerClass(root.provider.model), eval_set_hash, 0, "");
                root.emit(.{ .type = "score", .ok = true, .prompt_sha = sha, .signed = signed });
                continue;
            }
            if (std.mem.eql(u8, rtype, "answer")) {
                root.emit(.{ .type = "error", .message = "answer received with no active ask_user prompt" });
                continue;
            }
            const t = if (parsed == .object) parsed.object.get("text") else null;
            const text = if (t) |v| (if (v == .string) v.string else "") else "";
            if (text.len == 0) {
                root.emit(.{ .type = "error", .message = "request needs a non-empty \"text\" field" });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_system_prompt")) {
                const append = if (parsed.object.get("append")) |v| v == .bool and v.bool else false;
                root.sys_normal = if (append)
                    try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ root.sys_normal, text })
                else
                    try arena.dupe(u8, text);
                root.sys_strict = try std.fmt.allocPrint(arena, "{s}{s}", .{ root.sys_normal, strict_note });
                root.emit(.{ .type = "system_prompt", .ok = true, .append = append, .chars = root.sys_normal.len });
                continue;
            }
            if (parsed.object.get("maxToolCalls") orelse parsed.object.get("max_tool_calls")) |v| switch (v) {
                .integer => |n| max_tool_calls = if (n >= 0) @intCast(n) else null,
                .null => max_tool_calls = null,
                else => {},
            };
            if (parsed.object.get("dedupeToolCalls") orelse parsed.object.get("dedupe_tool_calls")) |v| {
                if (v == .bool) dedupe_tool_calls = v.bool;
            }
            break :blk text;
        } else line;

        // Persistent goal steering: the objective plus a nudge to track it as a
        // live todo_write checklist, with the current list appended so the model
        // resumes the plan instead of re-deriving it (assembled by goalSteeringNote).
        const todos_render: []const u8 = if (root.todos.items.len > 0) root.renderTodos() else "";
        const goal_note = try goalSteeringNote(arena, root.goal, todos_render);
        const eval_note = try evalSteeringNote(arena, root.eval_cmd, root.eval_target, root.eval_judge != null);
        var goal_msg: []const u8 = base_msg;
        if (goal_note.len > 0) goal_msg = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ goal_msg, goal_note });
        if (eval_note.len > 0) goal_msg = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ goal_msg, eval_note });

        // /loop asks the model to work autonomously through plan→act→verify.
        const loop_msg: []const u8 = if (loop_prompt != null) try std.fmt.allocPrint(arena,
            \\{s}
            \\
            \\[harness note: /loop was used. Work autonomously until the prompt is satisfied: make a brief plan, execute it with tools, verify the result, and only stop when you can report completion or you need a required human decision. Keep iterations tight and avoid asking for confirmation between routine steps.]
        , .{goal_msg}) else goal_msg;

        // Plan mode: steer the model to explore read-only and present a plan
        // (the gate enforces the read-only part regardless).
        const msg: []const u8 = if (!plan_mode) loop_msg else try std.fmt.allocPrint(arena,
            \\{s}
            \\
            \\[harness note: plan mode is ON — read-only. Explore with read-only
            \\tools as needed, then present a concrete plan (files to change,
            \\the changes themselves, sequence, risks) and ask the user to
            \\approve it. Do not write files or run mutating commands — the
            \\gate will deny them. The user toggles execution back on with /plan.]
        , .{loop_msg});

        // Promote a GUI `@[image]` attachment to a native vision block when the
        // model can see (otherwise it only gets the path and resorts to OCR).
        stageGuiImageAttachment(&root, msg);

        // Generate the AI tab-title concurrently (io.async), spawned BEFORE the
        // header so the first-turn header can wait for the summary title; reaped
        // after the turn (below) or by this defer on an early bail-out.
        var title_fut: ?Io.Future(?[]const u8) = null;
        if (!json_mode and root.ai_title and !root.ai_title_done) {
            root.ai_title_done = true;
            title_fut = io.async(titleTask, .{ gpa, io, root.client, root.provider, base_msg });
        }
        defer if (title_fut) |*f| {
            _ = f.await(io);
        };

        // TUI/session header: once the first real prompt materializes the chat,
        // show what this terminal tab is working on and the exact folder, and
        // keep the window title in sync each turn.
        if (!json_mode) {
            if (!root.tui_header_shown) {
                // Print the header IMMEDIATELY with the fast prompt-derived title so
                // the AI summary call (titleTask, spawned just above with io.async)
                // never blocks the response. The printed header scrolls into
                // scrollback and can't be redrawn, so it keeps the prompt title; the
                // AI summary runs in the background overlapping the turn and lands on
                // the redrawable window title + the session filename in the post-turn
                // handler below. (#91 made the reverse trade — blocking the turn so the
                // *printed* card read as a summary — but an extra round-trip in front
                // of every first response isn't worth it.)
                const turn_title = titleFromPrompt(base_msg);
                setTerminalTitle(out, turn_title, g_cwd_display);
                try printSessionHeader(out, turn_title, g_cwd_display);
                root.tui_header_shown = true;
            } else {
                // Later turns: keep the OSC tab/window title synced; header shown.
                const turn_title = root.session_title orelse titleFromPrompt(base_msg);
                setTerminalTitle(out, turn_title, g_cwd_display);
            }
        }

        // "ultracode" codeword or persistent /ultracode mode: opt turns into multi-agent workflow mode.
        const ultracode_msg = try applyUltracodeSteering(arena, msg, root.ultracode_mode);
        if (ultracode_msg.explicit) {
            if (!json_mode) {
                if (interactive) {
                    anim.ultracodeShine(out, io);
                    try out.writeAll("⚡ multi-agent workflow mode engaged\n");
                } else {
                    try out.writeAll("⚡ ultracode — multi-agent workflow mode engaged\n");
                }
                try out.flush();
            }
            tracer.note("ultracode", msg[0..@min(msg.len, 120)]);
            if (telemetry.g_telem) |t| t.ultracode();
        }
        if (root.pending_image) |img| {
            try root.messages.append(try imageMessage(arena, root.provider.kind, ultracode_msg.text, img));
            root.pending_image = null;
        } else try root.messages.append(try textMessage(arena, "user", ultracode_msg.text));
        snaps.turn += 1; // tag file edits in this turn (matches /rewind numbering)
        if (telemetry.g_telem) |t| t.countTurn();
        // Trajectory: claim this turn's node id up front so subagents spawned
        // during the turn can attach to it as their parent.
        const turn_id: u64 = if (trace.g_traj) |tj| blk: {
            const id = tj.nextId();
            tj.setTurn(id);
            break :blk id;
        } else 0;
        root.tools_used.clear(io); // per-turn tool log for the turn's node
        root.tool_calls_this_turn = 0;
        root.seen_tool_keys.clearRetainingCapacity();
        if (json_mode) root.emit(.{ .type = "started", .provider = root.provider.id, .model = root.provider.model });
        const turn_started = Io.Timestamp.now(io, .awake);
        // A failed turn must never kill the session: ApiError is already
        // reported inside request(); anything else is surfaced here. Either
        // way we drop back to the prompt (or emit a JSON error/turn event).
        const turn_result = root.runTurn();
        if (trace.g_traj) |tj| {
            const fp = promptFingerprint(root.systemPrompt());
            const turn_ms: i64 = @intCast(@max(0, turn_started.untilNow(io, .awake).toMilliseconds()));
            const turn_ok = if (turn_result) |_| true else |_| false;
            const turn_tools = root.tools_used.render(arena);
            tj.capturePrompt(fp, root.systemPrompt());
            tj.node(.{
                .id = turn_id,
                .parent = prev_turn_id,
                .kind = "turn",
                .label = root.provider.model,
                .t = tj.elapsedMs(),
                .ms = turn_ms,
                .prompt_sha = &fp,
                .prompt_mutated = !std.mem.eql(u8, &fp, &prev_prompt_fp),
                .task = utf8Prefix(base_msg, 160),
                .tools = turn_tools,
                .ok = turn_ok,
                .context_tokens = root.last_context_tokens,
            });
            // Preserve the failure reason in the archive: the turn node only
            // records ok:false, so an adjacent error record keeps the
            // user-visible detail (network give-up, api error) joinable to it (#86).
            if (!turn_ok) {
                const fail_detail: []const u8 = if (turn_result) |_| "" else |e| switch (e) {
                    error.ApiError => root.last_api_error orelse "api error",
                    else => @errorName(e),
                };
                tj.node(.{ .kind = "turn_error", .parent = turn_id, .t = tj.elapsedMs(), .detail = fail_detail });
            }
            if (telemetry.g_telem) |t| t.runEvent(&fp, !std.mem.eql(u8, &fp, &prev_prompt_fp), turn_ok, turn_ms, turn_tools);
            prev_turn_id = turn_id;
            prev_prompt_fp = fp;
        }
        const final_text = turn_result catch |err| switch (err) {
            error.Interrupted => {
                // Esc: keep what streamed so far in history (as an assistant
                // turn with an explicit marker) so the conversation stays
                // coherent, then drop back to the prompt.
                const partial = std.mem.trim(u8, root.partial_text.items, " \t\r\n");
                const marker: []const u8 = if (partial.len > 0)
                    try std.fmt.allocPrint(arena, "{s}\n\n[response interrupted by user]", .{partial})
                else
                    "[response interrupted by user]";
                try root.messages.append(try textMessage(arena, "assistant", marker));
                const int_msg: []const u8 = if (g_force_interrupt) "✗ interrupted (force)" else "✗ interrupted (esc)";
                g_force_interrupt = false;
                try out.print("{s}{s}{s}\n", .{ style.yellow, int_msg, style.reset });
                try out.flush();
                saveSession(&root, arena, root.session_name) catch {};
                continue;
            },
            error.ApiError => {
                if (telemetry.g_telem) |t| t.errorEvent("api", root.last_api_error orelse "api error");
                if (json_mode) {
                    root.emit(.{ .type = "error", .message = root.last_api_error orelse "api error" });
                    const partial = std.mem.trim(u8, root.partial_text.items, " \t\r\n");
                    if (partial.len > 0) {
                        root.emit(.{ .type = "finalizing" });
                        root.emit(.{ .type = "turn", .text = partial, .context_tokens = root.last_context_tokens, .cost_usd = g_cost.snap(io).usd, .complete = false, .metadata_complete = root.last_context_tokens > 0 });
                    }
                }
                // A turn can fail because the context window overflowed; if we're
                // over the compaction threshold, compact (or emergency-trim) now
                // so the next turn isn't doomed to fail at the same size (#88).
                if (root.last_context_tokens >= root.provider.compactAt()) root.compactOrRecover(true);
                saveSession(&root, arena, root.session_name) catch {};
                continue;
            },
            else => |e| {
                if (telemetry.g_telem) |t| t.errorEvent("turn", @errorName(e));
                if (json_mode) {
                    root.emit(.{ .type = "error", .message = @errorName(e) });
                } else {
                    root.say("[turn aborted: {t}]\n", .{e}) catch {};
                }
                saveSession(&root, arena, root.session_name) catch {};
                continue;
            },
        };
        if (json_mode) {
            const emitted_text = if (final_text.len == 0 and root.partial_text.items.len > 0)
                std.mem.trim(u8, root.partial_text.items, " \t\r\n")
            else
                final_text;
            root.emit(.{ .type = "finalizing" });
            root.emit(.{ .type = "turn", .text = emitted_text, .context_tokens = root.last_context_tokens, .cost_usd = g_cost.snap(io).usd, .complete = true, .metadata_complete = root.last_context_tokens > 0 });
        }

        // Apply the AI summary title + fleet champions that ran in the background
        // overlapping the turn — both off the critical path. The printed header kept
        // the fast prompt title; the summary now lands on the redrawable window title
        // and the saved session filename. Usually already resolved by here.
        if (title_fut) |*f| {
            if (f.await(io)) |t| {
                root.session_title = arena.dupe(u8, t) catch null;
                gpa.free(t);
                if (root.session_title) |st| {
                    setTerminalTitle(out, st, g_cwd_display);
                    renameSession(&root, arena, slugifyTitle(arena, st));
                }
            }
            title_fut = null;
        }
        joinElites(io); // publish backgrounded fleet champions for the next turn (no-op once joined)

        // turn_end lifecycle hooks (best-effort; interrupted/errored turns
        // `continue` above and never reach here, so ok is always true).
        if (g_hooks.turn_end.len > 0) {
            for (g_hooks.turn_end) |h| {
                const res = hooks.runHookCmd(gpa, io, h.command, "{\"event\":\"turn_end\",\"ok\":true}", h.timeout_ms);
                if (res.stderr.len > 0) gpa.free(res.stderr);
            }
        }

        if (root.last_context_tokens >= root.provider.compactAt()) {
            // Trim on failure only when we're genuinely against the window — at
            // 80–95% a transient compaction failure can recover next turn.
            const near_cap = root.provider.context > 0 and root.last_context_tokens * 100 >= root.provider.context * 95;
            root.compactOrRecover(near_cap);
        }
        // opencode-style continuous autosave: persist after every turn so a
        // crash or quit never loses the thread — last.session.json, the same
        // file /resume reads. Best-effort; a write failure never breaks the loop.
        saveSession(&root, arena, root.session_name) catch {};

        // --worktree checkpoint: commit this turn's edits to the scratch branch
        // so the work is durable + rewindable across restarts. No-op when not in
        // a worktree or when --no-autocommit is set.
        worktreeAutoCommit(gpa, io, std.fmt.allocPrint(arena, "wip: {s}", .{titleFromPrompt(base_msg)}) catch "wip: graff checkpoint");
    }
    // Final save on exit also captures command-driven edits since the last turn
    // (/clear, /rewind) so the next start resumes the true end state.
    if (!json_mode and root.messages.items.len > 0) {
        saveSession(&root, arena, root.session_name) catch |err| {
            out.print("{s}⚠ session save failed: {t}{s}\n", .{ style.yellow, err, style.reset }) catch {};
            out.flush() catch {};
        };
        out.print("{s}↩ session saved → {s}{s}{s}\n", .{ style.dim, root.session_name, style.reset, session_ext }) catch {};
        out.flush() catch {};
    } else {
        saveSession(&root, arena, root.session_name) catch {};
    }

    // Capture edits from an interrupted/aborted final turn (those `continue`
    // before the per-turn checkpoint) so a worktree never quits with work left
    // uncommitted on its scratch branch.
    worktreeAutoCommit(gpa, io, "wip: session end");
    try out.writeAll("\n");
    try out.flush();
}

/// Is this .mcp.json entry one the harness would auto-connect anyway? A
/// companion entry running its own binary (codedb-pro/muonry) with no args
/// (or just `--mcp`) carries the same trust as the PATH auto-activation — but
/// ONLY exactly that shape: a repo putting `{"codedbpro": {"command": "evil"}}`
/// (or extra args) in its config still hits the consent gate.
// The `graff mcp` CLI (list/add servers in .mcp.json) + the trusted-companion
// check + startup untrusted-server count live in mcp_cli.zig (600-line goal).
// The 3 externally-called entry points are aliased back.
const mcp_cli = @import("mcp_cli.zig");
const countMcpServers = mcp_cli.countMcpServers;
const persistMcpServer = mcp_cli.persistMcpServer;
const mcpCommand = mcp_cli.mcpCommand;

/// Pull plain text out of a message's content (string, or the text blocks of a
/// content array — anthropic "text", openai "text", responses "input/output_text").
pub fn extractText(arena: Allocator, m: Value) []const u8 {
    if (m != .object) return "";
    const c = m.object.get("content") orelse return "";
    if (c == .string) return c.string;
    if (c != .array) return "";
    var b: std.ArrayList(u8) = .empty;
    for (c.array.items) |blk| {
        if (blk != .object) continue;
        if (blk.object.get("text")) |t| if (t == .string) {
            if (b.items.len > 0) b.append(arena, '\n') catch {};
            b.appendSlice(arena, t.string) catch {};
        };
    }
    return b.items;
}

/// Rebuild the history as text-only user/assistant turns in `to_kind`'s format
/// — used to carry the conversation across a wire-format switch. Tool-call
/// structure is dropped (the dialogue is what matters for continuity).
fn translateHistory(arena: Allocator, msgs: *std.json.Array, to_kind: Provider.Kind) void {
    _ = to_kind; // textMessage's {role,content:string} shape is valid in all 3 formats
    var out = std.json.Array.init(arena);
    for (msgs.items) |m| {
        if (m != .object) continue;
        const role = if (m.object.get("role")) |r| (if (r == .string) r.string else "") else "";
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) continue;
        const text = std.mem.trim(u8, extractText(arena, m), " \t\r\n");
        if (text.len == 0) continue;
        out.append(textMessage(arena, role, text) catch continue) catch {};
    }
    msgs.* = out;
}

fn applyProvider(root: *Agent, arena: Allocator, p: Provider) []const u8 {
    const same_format = root.provider.kind == p.kind;
    var note: []const u8 = "context kept";
    if (!same_format) {
        if (root.keep_context) {
            translateHistory(arena, &root.messages, p.kind);
            note = "context translated & kept";
        } else {
            root.messages = std.json.Array.init(arena);
            root.last_context_tokens = 0;
            note = "history cleared — /keepcontext on to carry it across formats";
        }
    }
    root.cap_new = false; // per-provider token-cap quirk; relearn on rejection
    root.effort_rejected = false; // new model may accept reasoning_effort; relearn
    root.provider = p;
    saveModel(root.io, root.home, p.id, p.model); // remember for next launch
    return note;
}

fn resolveProviderControlRequest(
    keys: *Keys,
    arena: Allocator,
    provider_query: []const u8,
    model_query: []const u8,
    legacy_name: []const u8,
) !Provider {
    const provider_id = std.mem.trim(u8, provider_query, " \t");
    const model = std.mem.trim(u8, model_query, " \t");

    if (provider_id.len != 0) {
        for (provider_specs) |spec| {
            if (!std.mem.eql(u8, spec.id, provider_id)) continue;
            const selected_model = if (model.len == 0) spec.default_model else try arena.dupe(u8, model);
            return keys.providerById(spec.id, selected_model);
        }
        return error.InvalidProvider;
    }

    if (model.len != 0) {
        const resolved = resolveModelName(keys.*, model);
        const name = try arena.dupe(u8, resolved orelse model);
        return keys.providerFor(name);
    }

    return resolveProviderRequest(keys, arena, legacy_name);
}

fn resolveProviderRequest(keys: *Keys, arena: Allocator, query: []const u8) !Provider {
    const arg = std.mem.trim(u8, query, " \t");
    if (arg.len == 0) return error.InvalidModelRequest;

    if (std.mem.indexOfAny(u8, arg, " /\t")) |i| {
        const pid = arg[0..i];
        const mdl = std.mem.trim(u8, arg[i + 1 ..], " \t");
        for (provider_specs) |spec| {
            if (!std.mem.eql(u8, spec.id, pid) or mdl.len == 0) continue;
            const m = try arena.dupe(u8, mdl);
            return keys.providerById(pid, m);
        }
    }

    for (provider_specs) |spec| {
        if (!std.mem.eql(u8, spec.id, arg)) continue;
        return keys.providerById(spec.id, spec.default_model);
    }

    const resolved = resolveModelName(keys.*, arg);
    const name = try arena.dupe(u8, resolved orelse arg);
    return keys.providerFor(name);
}

/// Switch the active provider/model. Within the same wire format
/// (provider.kind) the conversation is kept verbatim. Across formats
/// (OpenAI↔Anthropic↔Responses) the stored messages don't fit the new shape:
/// with keep_context on (default) the dialogue is translated to a text-only
/// history and carried over; off clears it.
fn setModelRequestLabel(arena: Allocator, provider_query: []const u8, model_query: []const u8, legacy_name: []const u8) ![]const u8 {
    const provider_id = std.mem.trim(u8, provider_query, " \t");
    const model = std.mem.trim(u8, model_query, " \t");
    if (provider_id.len != 0 and model.len != 0) return std.fmt.allocPrint(arena, "{s} {s}", .{ provider_id, model });
    if (provider_id.len != 0) return arena.dupe(u8, provider_id);
    if (model.len != 0) return arena.dupe(u8, model);
    return arena.dupe(u8, std.mem.trim(u8, legacy_name, " \t"));
}

fn switchProvider(root: *Agent, arena: Allocator, p: Provider, out: *Io.Writer) !void {
    const note = applyProvider(root, arena, p);
    try out.print("switched to {s} via {s} ({t} format, {d}k ctx) — {s}\n", .{
        p.model, p.id, p.kind, p.context / 1000, note,
    });
    try out.flush();
}

/// Case-insensitive subsequence match (fzf-style): every char of `needle`
/// appears in `hay` in order, gaps allowed — so "gpt5.5" matches "gpt-5.5".
fn fuzzySubseq(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var ni: usize = 0;
    for (hay) |hc| {
        if (std.ascii.toLower(hc) == std.ascii.toLower(needle[ni])) {
            ni += 1;
            if (ni == needle.len) return true;
        }
    }
    return false;
}

/// Rank a fuzzy match for the pickers (higher = better, null = no match).
/// Tiers: basename/whole-string prefix > substring (earlier and shorter is
/// better) > bare subsequence — so "dem" puts demo.py above README.md, which
/// only matches as a d…e…m subsequence.
fn fuzzyScore(hay: []const u8, needle: []const u8) ?i32 {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    const len_pen: i32 = @intCast(@min(hay.len, 200));
    const base = if (std.mem.lastIndexOfScalar(u8, hay, '/')) |sl| sl + 1 else 0;
    if (std.ascii.startsWithIgnoreCase(hay[base..], needle) or
        std.ascii.startsWithIgnoreCase(hay, needle)) return 300_000 - len_pen;
    if (std.ascii.indexOfIgnoreCase(hay, needle)) |p| {
        const pos_pen: i32 = @intCast(@min(p, 1000));
        return 200_000 - pos_pen * 10 - len_pen;
    }
    if (fuzzySubseq(hay, needle)) return 100_000 - len_pen;
    return null;
}

/// Score a PickItem against a query: a name match always outranks a
/// desc-only match (the +1_000_000 tier gap dominates any name score).
fn pickScore(item: PickItem, q: []const u8) ?i32 {
    if (fuzzyScore(item.name, q)) |s| return s + 1_000_000;
    return fuzzyScore(item.desc, q);
}

/// Picker ranking entry: original item index + its pickScore/fuzzyScore.
const Scored = struct { idx: usize, score: i32 };

/// Sort order for picker results: best score first, ties keep item order.
fn scoredLess(_: void, a: Scored, b: Scored) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.idx < b.idx;
}

/// Interactive fuzzy model picker for a bare `/model` (codegraff-style). Opens
/// a full-screen alternate buffer: type to filter, ↑/↓ to move, Enter to pick,
/// Ctrl-C to cancel. Returns the chosen model_table index, or null.
fn modelPicker(root: *Agent, keys: *Keys, arena: Allocator, out: *Io.Writer) ?usize {
    const in = root.in orelse return null;
    const raw_state = tty.enterRaw(true) orelse return null;
    defer tty.restore(raw_state);
    out.writeAll("\x1b[?1049h") catch {}; // alternate screen
    defer {
        out.writeAll("\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(arena);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(arena);
    var filtered: std.ArrayList(usize) = .empty;
    defer filtered.deinit(arena);
    var sel: usize = 0;
    const visible = 18;

    while (true) {
        filtered.clearRetainingCapacity();
        // Two passes: models whose provider has a key/login first, so the
        // initial selection (and Enter) lands on something usable; keyless
        // rows trail with their ·no key tag. Within each pass the best
        // fuzzy match ranks first (ties keep table order).
        for ([2]bool{ true, false }) |want_keyed| {
            scored.clearRetainingCapacity();
            for (model_table, 0..) |m, i| {
                if ((keys.get(m.provider) != null) != want_keyed) continue;
                if (pickScore(.{ .name = m.name, .desc = m.provider }, query.items)) |s|
                    scored.append(arena, .{ .idx = i, .score = s }) catch {};
            }
            std.mem.sort(Scored, scored.items, {}, scoredLess);
            for (scored.items) |s| filtered.append(arena, s.idx) catch {};
        }
        if (filtered.items.len == 0) sel = 0 else if (sel >= filtered.items.len) sel = filtered.items.len - 1;

        out.writeAll("\x1b[2J\x1b[H") catch {};
        out.print("{s}Model ›{s} {s}\n", .{ style.cyan, style.reset, query.items }) catch {};
        out.print("{s}{d}/{d}{s}\n", .{ style.dim, filtered.items.len, model_table.len, style.reset }) catch {};
        out.print("{s}  {s:<26} {s:<11} CTX{s}\n", .{ style.dim, "MODEL", "PROVIDER", style.reset }) catch {};
        const off = if (sel >= visible) sel - visible + 1 else 0;
        var row = off;
        while (row < filtered.items.len and row < off + visible) : (row += 1) {
            const m = model_table[filtered.items[row]];
            const cur = std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id);
            const keyed = keys.get(m.provider) != null;
            if (row == sel) out.writeAll("\x1b[7m") catch {};
            out.print("{s} {s:<26} {s:<11} {d}k{s}{s}\n", .{
                if (cur) "▌" else " ",
                m.name,
                m.provider,
                m.context / 1000,
                if (keyed) "" else " ·no key",
                if (row == sel) "\x1b[0m" else "",
            }) catch {};
        }
        out.print("{s}↑/↓ move · type to filter · Enter switch · Ctrl-C cancel{s}", .{ style.dim, style.reset }) catch {};
        out.flush() catch {};

        const ch = in.takeByte() catch return null;
        switch (ch) {
            '\r', '\n' => return if (filtered.items.len > 0) filtered.items[sel] else null,
            0x03, 0x07 => return null, // Ctrl-C / Ctrl-G
            0x7f, 0x08 => if (query.items.len > 0) {
                query.shrinkRetainingCapacity(query.items.len - 1);
                sel = 0;
            },
            0x1b => {
                if ((in.takeByte() catch return null) != '[') continue;
                switch (in.takeByte() catch return null) {
                    'A' => if (sel > 0) {
                        sel -= 1;
                    },
                    'B' => if (sel + 1 < filtered.items.len) {
                        sel += 1;
                    },
                    else => {},
                }
            },
            else => if (ch >= 0x20) {
                query.append(arena, ch) catch {};
                sel = 0;
            },
        }
    }
}

const PickItem = struct { name: []const u8, desc: []const u8 = "" };

/// Generic full-screen fuzzy picker (same UI as the /model picker): type to
/// filter on name or description, ↑/↓ to move, Enter picks, Ctrl-C cancels.
/// Returns the index into `items`, or null.
fn listPicker(root: *Agent, arena: Allocator, out: *Io.Writer, title: []const u8, items: []const PickItem) ?usize {
    const in = root.in orelse return null;
    if (items.len == 0) return null;
    const raw_state = tty.enterRaw(true) orelse return null;
    defer tty.restore(raw_state);
    out.writeAll("\x1b[?1049h") catch {}; // alternate screen
    defer {
        out.writeAll("\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(arena);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(arena);
    var filtered: std.ArrayList(usize) = .empty;
    defer filtered.deinit(arena);
    var sel: usize = 0;
    const visible = 18;

    while (true) {
        // Score every item against the query and rank: best match on top
        // (ties keep the original item order). An empty query scores all
        // items 0, so the list stays in its given order.
        scored.clearRetainingCapacity();
        for (items, 0..) |item, i| {
            if (pickScore(item, query.items)) |s|
                scored.append(arena, .{ .idx = i, .score = s }) catch {};
        }
        std.mem.sort(Scored, scored.items, {}, scoredLess);
        filtered.clearRetainingCapacity();
        for (scored.items) |s| filtered.append(arena, s.idx) catch {};
        if (filtered.items.len == 0) sel = 0 else if (sel >= filtered.items.len) sel = filtered.items.len - 1;

        out.writeAll("\x1b[2J\x1b[H") catch {};
        out.print("{s}{s}{s} {s}\n", .{ style.cyan, title, style.reset, query.items }) catch {};
        out.print("{s}{d}/{d}{s}\n", .{ style.dim, filtered.items.len, items.len, style.reset }) catch {};
        const off = if (sel >= visible) sel - visible + 1 else 0;
        var row = off;
        while (row < filtered.items.len and row < off + visible) : (row += 1) {
            const item = items[filtered.items[row]];
            if (row == sel) out.writeAll("\x1b[7m") catch {};
            out.print(" {s:<16}{s} {s}{s}{s}\n", .{
                item.name,
                if (row == sel) "\x1b[0m" else "",
                style.dim,
                item.desc,
                style.reset,
            }) catch {};
        }
        out.print("{s}↑/↓ move · type to filter · Enter pick · Ctrl-C cancel{s}", .{ style.dim, style.reset }) catch {};
        out.flush() catch {};

        const ch = in.takeByte() catch return null;
        switch (ch) {
            '\r', '\n' => return if (filtered.items.len > 0) filtered.items[sel] else null,
            0x03, 0x07 => return null, // Ctrl-C / Ctrl-G
            0x7f, 0x08 => if (query.items.len > 0) {
                query.shrinkRetainingCapacity(query.items.len - 1);
                sel = 0;
            },
            0x1b => {
                if ((in.takeByte() catch return null) != '[') return null; // bare Esc cancels
                switch (in.takeByte() catch return null) {
                    'A' => if (sel > 0) {
                        sel -= 1;
                    },
                    'B' => if (sel + 1 < filtered.items.len) {
                        sel += 1;
                    },
                    else => {},
                }
            },
            else => if (ch >= 0x20) {
                query.append(arena, ch) catch {};
                sel = 0;
            },
        }
    }
}

const UltracodeMessage = struct {
    text: []const u8,
    explicit: bool,
};

const ultracode_explicit_note =
    \\[harness note: the user invoked the "ultracode" codeword, opting
    \\this turn into multi-agent orchestration. Fulfill the request with
    \\the workflow tool: decompose it into sequential phases of parallel
    \\subagents — fan out for coverage first, then a synthesis phase.
    \\Tell code-exploration subagents to go through the repo with the
    \\codedb tool (search / symbol / callers / outline / context) before
    \\reaching for bash grep — it is indexed and structural.
    \\Use the workflow even if you could do the work solo; skip it only
    \\if the message needs a purely conversational reply.]
;

const ultracode_persistent_note =
    \\[harness note: ultracode mode is enabled for this session. Use the
    \\workflow tool for coding tasks: decompose the work into sequential
    \\phases with parallel subagents for exploration/review where helpful,
    \\then synthesize and implement. Tell code-exploration subagents to go
    \\through the repo with the codedb tool (search / symbol / callers /
    \\outline / context) before reaching for bash grep — it is indexed and
    \\structural.]
;

fn applyUltracodeSteering(arena: Allocator, msg: []const u8, persistent_enabled: bool) !UltracodeMessage {
    const explicit = std.ascii.indexOfIgnoreCase(msg, "ultracode") != null;
    if (explicit) {
        return .{ .text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ msg, ultracode_explicit_note }), .explicit = true };
    }
    if (persistent_enabled) {
        return .{ .text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ msg, ultracode_persistent_note }), .explicit = false };
    }
    return .{ .text = msg, .explicit = false };
}

const ultracode_on_first = [_]PickItem{
    .{ .name = "on", .desc = "Enable ultracode orchestration" },
    .{ .name = "off", .desc = "Disable ultracode orchestration" },
};
const ultracode_off_first = [_]PickItem{
    .{ .name = "off", .desc = "Disable ultracode orchestration" },
    .{ .name = "on", .desc = "Enable ultracode orchestration" },
};

fn ultracodeToggleItems(enabled: bool) []const PickItem {
    return if (enabled) &ultracode_off_first else &ultracode_on_first;
}

fn pickUltracodeMode(root: *Agent, arena: Allocator, out: *Io.Writer) ?bool {
    const items = ultracodeToggleItems(root.ultracode_mode);
    const idx = listPicker(root, arena, out, "Ultracode ›", items) orelse return null;
    return std.mem.eql(u8, items[idx].name, "on");
}

/// The slash-command menu shown for a bare "/": every REPL command with a
/// one-line description, picked via listPicker. Returns the command to run.
const command_menu = [_]PickItem{
    .{ .name = "/model", .desc = "switch model/provider (picker)" },
    .{ .name = "/models", .desc = "list known models, context windows" },
    .{ .name = "/clear", .desc = "wipe the conversation, start fresh" },
    .{ .name = "/new", .desc = "start a new autosaved session" },
    .{ .name = "/rename", .desc = "rename the current session title" },
    .{ .name = "/goal", .desc = "set/show a standing objective, tracked as a live checklist" },
    .{ .name = "/loop", .desc = "run an autonomous plan→act→verify prompt" },
    .{ .name = "/bash", .desc = "run a shell command in the current workspace" },
    .{ .name = "/compact", .desc = "summarize history into a fresh context" },
    .{ .name = "/plan", .desc = "toggle plan mode (read-only, propose first)" },
    .{ .name = "/resume", .desc = "restore a saved session (picker)" },
    .{ .name = "/save", .desc = "save the conversation" },
    .{ .name = "/sessions", .desc = "list saved sessions" },
    .{ .name = "/rewind", .desc = "drop a past prompt & revert its file edits" },
    .{ .name = "/key", .desc = "API-key status / add one live" },
    .{ .name = "/login", .desc = "OAuth sign-in: codegraff | codex/oai | kimi" },
    .{ .name = "/yolo", .desc = "toggle permission prompts" },
    .{ .name = "/strict", .desc = "toggle every-message-is-a-tool mode" },
    .{ .name = "/keepcontext", .desc = "keep history across wire-format switches" },
    .{ .name = "/effort", .desc = "thinking depth: low|medium|high (codex, deepseek, codegraff)" },
    .{ .name = "/reasoning", .desc = "alias for /effort" },
    .{ .name = "/fast", .desc = "codex priority service tier — lower latency (gpt-5.5)" },
    .{ .name = "/ultracode", .desc = "toggle persistent ultracode (multi-agent workflow) mode" },
    .{ .name = "/thinking", .desc = "show/collapse the model's live reasoning stream" },
    .{ .name = "/title", .desc = "AI-name the tab from your first prompt (on by default)" },
    .{ .name = "/image", .desc = "attach an image to the next message" },
    .{ .name = "/paste", .desc = "attach the clipboard image" },
    .{ .name = "/trace", .desc = "toggle the JSONL event trace" },
    .{ .name = "/fleet", .desc = "toggle federated fleet contribution (DGM propose/submit/elite_pull)" },
    .{ .name = "/trajectory", .desc = "show this session's agent tree (DGM-style)" },
    .{ .name = "/agents", .desc = "list agent types (builtins + .harness/agents)" },
    .{ .name = "/skills", .desc = "optional companion tools: list, /skills add|remove <name>" },
    .{ .name = "/hooks", .desc = "list lifecycle hooks (pre_tool/post_tool/turn_end)" },
    .{ .name = "/todo", .desc = "show the task list" },
    .{ .name = "/jobs", .desc = "list background bash jobs (bash run_in_background)" },
    .{ .name = "/cost", .desc = "session usage: api calls, tokens, USD total" },
    .{ .name = "/animation", .desc = "pick the thinking animation (braille, matrix, pacman…)" },
    .{ .name = "/theme", .desc = "pick a terminal color theme (PastelPink/Midnight/Forest/Amber)" },
    .{ .name = "/mcp", .desc = "list/add/trust MCP servers" },
    .{ .name = "/help", .desc = "list all commands" },
};

/// After an in-session `/login` writes its credential file, pull the fresh key
/// (and the Codex account id) into the live Keys so the current conversation
/// uses it without a restart — the in-session twin of the startup loaders.
fn reloadLoginKey(root: *Agent, keys: *Keys, arena: Allocator, provider_id: []const u8) void {
    const home = root.home;
    for (provider_specs, &keys.values) |spec, *value| {
        if (!std.mem.eql(u8, spec.id, provider_id)) continue;
        if (std.mem.eql(u8, provider_id, "codegraff")) {
            if (oauth.loadCodegraffKey(root.io, arena, home)) |k| value.* = k;
        } else if (std.mem.eql(u8, provider_id, "kimi")) {
            if (oauth.loadKimiOAuth(root.io, root.gpa, arena, home)) |k| value.* = k;
        } else if (std.mem.eql(u8, provider_id, "codex")) {
            if (oauth.loadCodexAuth(root.io, arena, home)) |auth| {
                value.* = auth.token;
                keys.codex_account = auth.account;
            }
        }
    }
}

/// Better UX when /model targets a provider with no key: instead of a flat
/// "no key" dead-end, offer to log in (OAuth, for providers that have a flow)
/// or paste an API key, then switch to pid/model. Esc/blank/"keep" stays on the
/// current model. Non-TTY just prints the actionable one-liner. Best-effort.
fn offerProviderAuth(root: *Agent, keys: *Keys, arena: Allocator, out: *Io.Writer, pid: []const u8, model: []const u8) !void {
    var spec_idx: ?usize = null;
    for (provider_specs, 0..) |spec, i| if (std.mem.eql(u8, spec.id, pid)) {
        spec_idx = i;
    };
    const si = spec_idx orelse {
        try out.print("unknown provider '{s}' — see /model for the list\n", .{pid});
        try out.flush();
        return;
    };
    const can_login = std.mem.eql(u8, pid, "codegraff") or std.mem.eql(u8, pid, "codex") or std.mem.eql(u8, pid, "kimi");

    // Non-interactive (one-shot / no TTY): no picker — print the hint and bail.
    if (!use_color or root.in == null) {
        if (can_login)
            try out.print("no key for {s} — /login {s} (OAuth) or /key {s} <key>\n", .{ pid, pid, pid })
        else
            try out.print("no key for {s} — /key {s} <key> (or set {s})\n", .{ pid, pid, provider_specs[si].env_key });
        try out.flush();
        return;
    }

    // Choice menu — login row only when the provider actually has an OAuth flow.
    var items: [3]PickItem = undefined;
    var n: usize = 0;
    if (can_login) {
        items[n] = .{ .name = "log in (OAuth)", .desc = "device/browser sign-in — no key to paste" };
        n += 1;
    }
    items[n] = .{ .name = "paste an API key", .desc = "enter a key now (used live + saved)" };
    n += 1;
    items[n] = .{ .name = "keep current model", .desc = "cancel — stay on the current model" };
    n += 1;

    const title = std.fmt.allocPrint(arena, "No key for {s} \xe2\x80\xba", .{pid}) catch "No key \xe2\x80\xba";
    const choice = listPicker(root, arena, out, title, items[0..n]) orelse {
        try out.print("kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    const picked = items[choice].name;

    if (std.mem.eql(u8, picked, "keep current model")) {
        try out.print("kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, picked, "log in (OAuth)")) {
        const home = root.home;
        try out.flush(); // hand stdout to the login flow's own writer
        if (std.mem.eql(u8, pid, "codegraff")) {
            oauth.codegraffLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 codegraff login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "codex")) {
            oauth.codexLogin(root.io, root.gpa, arena, home, false) catch |err| {
                try out.print("\xe2\x9c\x97 codex login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "kimi")) {
            oauth.kimiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 kimi login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        }
        reloadLoginKey(root, keys, arena, pid);
    } else {
        // Paste a key: one cooked-mode line read (echoes), same pattern as the
        // tool-approval prompt. Blank input cancels.
        const in = root.in orelse return;
        try out.print("paste your {s} API key, then Enter (blank cancels): ", .{pid});
        try out.flush();
        const raw = (in.takeDelimiter('\n') catch null) orelse "";
        const key = std.mem.trim(u8, raw, " \t\r\n");
        if (key.len == 0) {
            try out.print("cancelled — kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
            try out.flush();
            return;
        }
        const dup = arena.dupe(u8, key) catch key;
        keys.values[si] = dup;
        const saved = storeKey(root.io, root.gpa, arena, root.home, pid, dup);
        try out.print("\xe2\x9c\x93 {s} key set (live{s})\n", .{ pid, if (saved) " + Keychain" else "" });
    }

    // Auth done — switch now if the key/login took, else keep the current model.
    const provider = keys.providerById(pid, model) catch {
        try out.print("still no usable key for {s} — kept {s}{s}{s}\n", .{ pid, style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    try switchProvider(root, arena, provider, out);
}

fn handleCommand(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !void {
    if (std.mem.eql(u8, line, "/clear")) {
        root.messages = std.json.Array.init(arena);
        root.last_context_tokens = 0;
        root.last_cache_read = 0;
        root.tui_header_shown = false;
        root.session_title = null; // re-summarize the now-empty conversation
        root.ai_title_done = false;
        root.todos.clearRetainingCapacity();
        saveSession(root, arena, root.session_name) catch {};
        setTerminalTitle(out, "Chat", g_cwd_display);
        try out.writeAll("context cleared — fresh conversation\n");
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/new")) {
        root.messages = std.json.Array.init(arena);
        root.last_context_tokens = 0;
        root.last_cache_read = 0;
        root.todos.clearRetainingCapacity();
        root.goal = null;
        root.ultracode_mode = false;
        root.session_title = null;
        root.ai_title_done = false; // let the new session earn its own AI title
        root.tui_header_shown = false;
        root.session_name = try std.fmt.allocPrint(arena, "session-{d}", .{unixMs(root.io)});
        saveSession(root, arena, root.session_name) catch {};
        try out.print("new session → {s}{s}\n", .{ root.session_name, session_ext });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/rename")) {
        const title = std.mem.trim(u8, line["/rename".len..], " \t");
        if (title.len == 0) {
            try out.writeAll("usage: /rename <title>\n");
        } else {
            root.session_title = try arena.dupe(u8, title);
            root.ai_title_done = true; // a manual /rename wins over the auto-titler
            saveSession(root, arena, root.session_name) catch {};
            try out.print("session title → {s}\n", .{title});
        }
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/goal")) {
        const text = std.mem.trim(u8, line["/goal".len..], " \t");
        if (text.len == 0) {
            if (root.goal) |goal| try out.print("Current goal: {s}\nClear it with /goal clear.\n", .{goal}) else try out.writeAll("No active goal. Set one with /goal <objective>.\n");
        } else if (std.ascii.eqlIgnoreCase(text, "clear") or std.ascii.eqlIgnoreCase(text, "off")) {
            root.goal = null;
            saveSession(root, arena, root.session_name) catch {};
            try out.writeAll("Goal cleared. Future turns will not get goal steering.\n");
        } else {
            root.goal = try arena.dupe(u8, text);
            saveSession(root, arena, root.session_name) catch {};
            try out.print("Goal set: {s}\nI'll track it as a live checklist (todo_write) and work through it across turns.\n", .{text});
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/loop")) {
        try out.writeAll("usage: /loop <prompt> — run an autonomous plan→act→verify pass.\n");
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/bash") or std.mem.startsWith(u8, line, "/bash ")) {
        const cmd = std.mem.trim(u8, line["/bash".len..], " \t\r\n");
        if (cmd.len == 0) {
            try out.writeAll("usage: /bash <command>\n");
            try out.flush();
            return;
        }
        var input_obj: std.json.ObjectMap = .empty;
        try input_obj.put(arena, "command", .{ .string = cmd });
        const call: ToolCall = .{ .id = "slash-bash", .name = "bash", .input = .{ .object = input_obj } };
        if (try root.gateTool(call)) |denied| {
            try out.print("{s}\n", .{denied.text});
            try out.flush();
            return;
        }
        const result = execTool(.{
            .gpa = root.gpa,
            .io = root.io,
            .client = root.client,
            .provider = root.provider,
            .registry = root.registry,
            .from_sub = false,
            .approvals = root.approvals,
            .tracer = root.tracer,
            .snapshots = root.snapshots,
            .tools_used = &root.tools_used,
        }, call);
        defer root.gpa.free(result.text);
        try out.writeAll(result.text);
        if (result.text.len == 0 or result.text[result.text.len - 1] != '\n') try out.writeAll("\n");
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/agents promote")) {
        const personal = std.mem.indexOf(u8, line, "--personal") != null or std.mem.indexOf(u8, line, "--global") != null;
        try out.print("{s}promoting local champions{s} → {s} tier (from {s})\n", .{ style.bold, style.reset, if (personal) "personal ~/.harness/agents" else "private ./.harness/agents", trajectory_path });
        const n = promoteAgents(root.io, root.gpa, out, fleet.g_home, personal);
        if (n > 0) try out.print("{s}✓ promoted {d} niche(s) — they load on next start{s}\n", .{ style.green, n, style.reset });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/agents")) {
        try out.print("{s}agent types{s} — MAP-Elites niches: builtins + {s}/*.md (file shadows builtin); spawn via subagent agent:\"<name>\"\n", .{ style.bold, style.reset, fleet.agents_dir });
        for (fleet.g_agent_types) |t| {
            const fp = promptFingerprint(t.prompt);
            try out.print("  {s}{s:<14}{s} {s} {s}{s}{s}", .{
                style.cyan,
                t.name,
                style.reset,
                if (t.builtin) "builtin" else "file   ",
                style.dim,
                &fp,
                style.reset,
            });
            if (t.score) |sc| try out.print(" {s}score {d:.2}{s}", .{ style.green, sc, style.reset });
            try out.print("  {s}\n", .{t.desc});
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/animation") or std.mem.startsWith(u8, line, "/animation ")) {
        const arg = std.mem.trim(u8, line["/animation".len..], " ");
        if (arg.len == 0) {
            const current: []const u8 = if (anim.g_anim_off) "off" else if (anim.g_anim_random) "random" else anim.anims[anim.g_anim_index].name;
            try out.print("{s}thinking animations{s} (current: {s}{s}{s}) — /animation <name> picks one, persists to {s}\n", .{ style.bold, style.reset, style.cyan, current, style.reset, Approvals.settings_path });
            for (anim.anims) |a| {
                try out.print("  {s}{s:<12}{s} {s}  preview: ", .{ style.cyan, a.name, style.reset, a.desc });
                try a.frame(out, 3);
                try out.writeAll("\n");
            }
            try out.print("  {s}{s:<12}{s} a different one each request\n  {s}{s:<12}{s} no animation\n", .{ style.cyan, "random", style.reset, style.cyan, "off", style.reset });
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "off")) {
            anim.g_anim_off = true;
            anim.g_anim_random = false;
        } else if (std.mem.eql(u8, arg, "random")) {
            anim.g_anim_off = false;
            anim.g_anim_random = true;
        } else if (anim.animIndex(arg)) |i| {
            anim.g_anim_off = false;
            anim.g_anim_random = false;
            anim.g_anim_index = i;
        } else {
            try out.print("unknown animation '{s}' — /animation lists them\n", .{arg});
            try out.flush();
            return;
        }
        const saved = anim.saveAnimationSetting(root.io, root.gpa, arg);
        try out.print("{s}✓ thinking animation: {s}{s}", .{ style.green, arg, style.reset });
        if (!anim.g_anim_off and !anim.g_anim_random) {
            try out.writeAll("  ");
            try anim.anims[anim.g_anim_index].frame(out, 3);
        }
        try out.writeAll("\n");
        if (!saved) try out.print("{s}warning: could not persist to {s} — lasts only this session{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/theme") or std.mem.startsWith(u8, line, "/theme ")) {
        const arg = std.mem.trim(u8, line["/theme".len..], " ");
        if (arg.len == 0) {
            const current: []const u8 = if (anim.g_theme) |i| anim.themes[i].name else "off";
            try out.print("{s}color themes{s} (current: {s}{s}{s}) — /theme <name> applies + persists, /theme off resets to your terminal default\n", .{ style.bold, style.reset, style.cyan, current, style.reset });
            for (anim.themes) |t| try out.print("  {s}{s:<12}{s} {s}\n", .{ style.cyan, t.name, style.reset, t.desc });
            try out.print("  {s}{s:<12}{s} terminal default (no theme)\n", .{ style.cyan, "off", style.reset });
            try out.flush();
            return;
        }
        if (std.ascii.eqlIgnoreCase(arg, "off") or std.ascii.eqlIgnoreCase(arg, "none")) {
            if (anim.g_theme != null) out.writeAll(anim.theme_reset) catch {};
            anim.g_theme = null;
        } else if (anim.themeIndex(arg)) |i| {
            anim.g_theme = i;
            out.writeAll(anim.themes[i].seq) catch {};
            out.flush() catch {};
        } else {
            try out.print("unknown theme '{s}' — /theme lists them\n", .{arg});
            try out.flush();
            return;
        }
        const saved = anim.saveThemeSetting(root.io, root.gpa, arg);
        const shown: []const u8 = if (anim.g_theme) |i| anim.themes[i].name else "off";
        try out.print("{s}✓ theme: {s}{s}\n", .{ style.green, shown, style.reset });
        if (!saved) try out.print("{s}warning: could not persist to {s} — lasts only this session{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/hooks")) {
        try out.print("{s}codedb guard{s} (built-in, issue #626): {s} — blocks bash grep/sed/cat/wc on indexed source files and redirects to the codedb tool; GRAFF_NO_CODEDB_GUARD=1 disables.\n", .{ style.bold, style.reset, if (g_codedb_guard) "on" else "off" });
        if (g_hooks.total() == 0) {
            try out.print("no lifecycle hooks. Add them to {s}:\n  {s}{{\"hooks\": {{\"pre_tool\": [{{\"match\": \"bash\", \"command\": \"./guard.sh\"}}]}}}}{s}\n  events: pre_tool (exit 2 blocks, stderr → model) · post_tool · turn_end; loaded at startup\n", .{ Approvals.settings_path, style.dim, style.reset });
            try out.flush();
            return;
        }
        try out.print("{s}lifecycle hooks{s} (from {s}; event JSON on stdin, pre_tool exit 2 blocks):\n", .{ style.bold, style.reset, Approvals.settings_path });
        inline for (.{ "pre_tool", "post_tool", "turn_end" }) |ev| {
            for (@field(g_hooks, ev)) |h| {
                try out.print("  {s}{s:<9}{s} match {s}{s:<16}{s} {d}ms  {s}\n", .{ style.cyan, ev, style.reset, style.dim, h.match, style.reset, h.timeout_ms, h.command });
            }
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/skills") or std.mem.startsWith(u8, line, "/skills ")) {
        const rest = std.mem.trim(u8, line["/skills".len..], " ");
        if (std.mem.startsWith(u8, rest, "remove ")) {
            const name = std.mem.trim(u8, rest["remove ".len..], " ");
            if (skillIndex(name)) |i| {
                if (g_skill_disabled[i]) {
                    try out.print("{s} is already disabled\n", .{name});
                } else {
                    g_skill_disabled[i] = true;
                    const saved = saveSkillSetting(root.io, root.gpa, name, false);
                    try out.print("{s}✓ {s} disabled{s} — ignored even when its binaries are on PATH (webfetch falls back, no context note); /skills add {s} re-enables\n", .{ style.green, name, style.reset, name });
                    if (!saved) try out.print("{s}warning: could not persist to {s} — the opt-out lasts only this session{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
                }
                try out.flush();
                return;
            }
            try out.print("unknown skill: {s} — /skills lists the registry\n", .{name});
            try out.flush();
            return;
        }
        if (std.mem.startsWith(u8, rest, "add ")) {
            const name = std.mem.trim(u8, rest[4..], " ");
            for (skills_registry) |sk| {
                if (!std.mem.eql(u8, sk.name, name)) continue;
                if (skillDisabled(sk.name)) {
                    g_skill_disabled[skillIndex(sk.name).?] = false;
                    const saved = saveSkillSetting(root.io, root.gpa, sk.name, true);
                    try out.print("{s}✓ {s} re-enabled{s}{s}\n", .{ style.green, sk.name, style.reset, if (skillInstalled(root.io, sk)) " — restart the harness to add its context note" else "" });
                    if (!saved) try out.print("{s}warning: could not persist to {s}{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
                    if (skillInstalled(root.io, sk)) {
                        try out.flush();
                        return;
                    }
                    // not installed: fall through to the installer below
                }
                if (skillInstalled(root.io, sk)) {
                    try out.print("{s} is already installed\n", .{sk.name});
                    try out.flush();
                    return;
                }
                try out.print("installing {s}{s}{s}: {s}{s}{s}\n", .{ style.cyan, sk.name, style.reset, style.dim, sk.install, style.reset });
                try out.flush();
                // The user typed the install command themselves — that's the
                // consent; the installer runs with our stdio so its progress
                // and any sudo prompt reach the terminal directly.
                var child = std.process.spawn(root.io, .{ .argv = &.{ "/bin/sh", "-c", sk.install } }) catch |err| {
                    try out.print("failed to launch installer: {t}\n", .{err});
                    try out.flush();
                    return;
                };
                const term = child.wait(root.io) catch {
                    try out.writeAll("installer did not exit cleanly\n");
                    try out.flush();
                    return;
                };
                const ok = term == .exited and term.exited == 0 and skillInstalled(root.io, sk);
                if (ok) {
                    try out.print("{s}✓ {s} installed{s} — usable via bash now; restart the harness to add its context note\n", .{ style.green, sk.name, style.reset });
                } else {
                    try out.print("{s}{s} install did not complete{s} — run it manually: {s}\n", .{ style.yellow, sk.name, style.reset, sk.install });
                }
                try out.flush();
                return;
            }
            try out.print("unknown skill: {s} — /skills lists the registry\n", .{name});
            try out.flush();
            return;
        }
        try out.print("{s}skills{s} — optional companion tools (codex-style; one context line each when installed)\n", .{ style.bold, style.reset });
        for (skills_registry) |sk| {
            const inst = skillInstalled(root.io, sk);
            const disabled = skillDisabled(sk.name);
            const state: []const u8 = if (disabled) "disabled     " else if (inst) "installed    " else "not installed";
            try out.print("  {s}{s:<8}{s} {s}{s}{s}  {s}\n", .{
                style.cyan,                                                           sk.name, style.reset,
                if (disabled) style.yellow else if (inst) style.green else style.dim, state,   style.reset,
                sk.desc,
            });
        }
        try out.writeAll("  install/enable: /skills add <name> · disable: /skills remove <name>\n");
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/trajectory")) {
        const data = Io.Dir.cwd().readFileAlloc(root.io, trajectory_path, arena, .limited(4 << 20)) catch "";
        const S = struct {
            fn str(o: std.json.ObjectMap, k: []const u8) []const u8 {
                const v = o.get(k) orelse return "";
                return if (v == .string) v.string else "";
            }
            fn int(o: std.json.ObjectMap, k: []const u8) i64 {
                const v = o.get(k) orelse return 0;
                return if (v == .integer) v.integer else 0;
            }
            fn flag(o: std.json.ObjectMap, k: []const u8) bool {
                const v = o.get(k) orelse return false;
                return v == .bool and v.bool;
            }
            // Latest score recorded for a prompt fingerprint, across the
            // whole archive (scores persist between sessions).
            fn scoreFor(all: []const std.json.ObjectMap, sha: []const u8) ?f64 {
                var found: ?f64 = null;
                for (all) |o| {
                    if (!std.mem.eql(u8, str(o, "kind"), "score")) continue;
                    if (!std.mem.eql(u8, str(o, "prompt_sha"), sha)) continue;
                    const v = o.get("score") orelse continue;
                    found = switch (v) {
                        .float => |x| x,
                        .integer => |x| @floatFromInt(x),
                        else => found,
                    };
                }
                return found;
            }
        };
        var objs: std.ArrayList(std.json.ObjectMap) = .empty;
        var it = std.mem.tokenizeScalar(u8, data, '\n');
        while (it.next()) |ln| {
            const v = std.json.parseFromSliceLeaky(Value, arena, ln, .{ .allocate = .alloc_always }) catch continue;
            if (v == .object) objs.append(arena, v.object) catch {};
        }
        // Tree shows the CURRENT session (ids restart per session); scores
        // come from the whole archive.
        var session_start: usize = 0;
        for (objs.items, 0..) |o, i| {
            if (std.mem.eql(u8, S.str(o, "kind"), "session")) session_start = i + 1;
        }
        const session = objs.items[session_start..];
        var turns: usize = 0;
        for (session) |o| {
            if (std.mem.eql(u8, S.str(o, "kind"), "turn")) turns += 1;
        }
        if (turns == 0) {
            try out.writeAll("no trajectory recorded yet — run a turn first (the archive lives in harness.trajectory.jsonl)\n");
            try out.flush();
            return;
        }
        try out.print("{s}session trajectory{s} — {d} turn(s); archive: {s} ({d} record(s) total)\n", .{ style.bold, style.reset, turns, trajectory_path, objs.items.len });
        for (session) |o| {
            if (!std.mem.eql(u8, S.str(o, "kind"), "turn")) continue;
            const turn_id = S.int(o, "id");
            out.print("{s}●{s} turn {d} {s} {d}ms · prompt {s}{s}{s}{s} · {s}", .{
                style.cyan,
                style.reset,
                turn_id,
                if (S.flag(o, "ok")) "✓" else "✗",
                S.int(o, "ms"),
                style.dim,
                S.str(o, "prompt_sha"),
                if (S.flag(o, "prompt_mutated")) " (mutated)" else "",
                style.reset,
                utf8Prefix(S.str(o, "task"), 80),
            }) catch {};
            if (S.scoreFor(objs.items, S.str(o, "prompt_sha"))) |sc|
                out.print(" {s}· score {d:.2}{s}", .{ style.green, sc, style.reset }) catch {};
            out.writeAll("\n") catch {};
            // children: subagents / workflow tasks spawned during this turn
            var remaining: usize = 0;
            for (session) |c| {
                if (S.int(c, "parent") == turn_id and !std.mem.eql(u8, S.str(c, "kind"), "turn")) remaining += 1;
            }
            for (session) |c| {
                if (S.int(c, "parent") != turn_id or std.mem.eql(u8, S.str(c, "kind"), "turn")) continue;
                remaining -= 1;
                out.print("  {s} {s} {s} {d}ms · prompt {s}{s}{s}{s} · {s}", .{
                    if (remaining == 0) "└─" else "├─",
                    S.str(c, "label"),
                    if (S.flag(c, "ok")) "✓" else "✗",
                    S.int(c, "ms"),
                    style.dim,
                    S.str(c, "prompt_sha"),
                    if (S.flag(c, "prompt_mutated")) " (variant)" else "",
                    style.reset,
                    utf8Prefix(S.str(c, "task"), 70),
                }) catch {};
                if (S.scoreFor(objs.items, S.str(c, "prompt_sha"))) |sc|
                    out.print(" {s}· score {d:.2}{s}", .{ style.green, sc, style.reset }) catch {};
                out.writeAll("\n") catch {};
            }
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/plan")) {
        plan_mode = !plan_mode;
        if (plan_mode) {
            try out.print("plan mode {s}on{s} — read-only: the agent explores and proposes; writes/edits/mutating bash are denied. /plan again to execute.\n", .{ style.cyan, style.reset });
        } else {
            try out.writeAll("plan mode off — tools may modify things again (normal gating applies)\n");
        }
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/model") and !std.mem.startsWith(u8, line, "/models")) {
        const arg = std.mem.trim(u8, line["/model".len..], " \t");
        if (arg.len == 0) {
            if (use_color) { // interactive TTY → fuzzy picker
                if (modelPicker(root, keys, arena, out)) |idx| {
                    const m = model_table[idx];
                    const provider = keys.providerById(m.provider, m.name) catch {
                        try offerProviderAuth(root, keys, arena, out, m.provider, m.name);
                        return;
                    };
                    try switchProvider(root, arena, provider, out);
                }
                return;
            }
            try out.print("current model: {s}{s}{s} via {s}\n", .{ style.cyan, root.provider.model, style.reset, root.provider.id });
            try out.writeAll("switch with /model <name> or /model <provider>:\n");
            for (provider_specs) |spec| {
                const keyed = keys.get(spec.id) != null;
                try out.print("  {s} {s:<10}{s}  default {s}\n", .{
                    if (keyed) "✓" else "·",
                    spec.id,
                    if (keyed) "" else "  (no key)",
                    spec.default_model,
                });
            }
            try out.print("{s}add a key now:  /key <provider> <key>   ·   full model list: /models{s}\n", .{ style.dim, style.reset });
            try out.flush();
            return;
        }
        // `/model <provider> <model>` or `/model <provider>/<model>`: pin a
        // model to a SPECIFIC provider (e.g. `/model codex gpt-5.5` to force
        // codex when codegraff also serves gpt-5.5).
        if (std.mem.indexOfAny(u8, arg, " /\t")) |i| {
            const pid = arg[0..i];
            const mdl = std.mem.trim(u8, arg[i + 1 ..], " \t");
            for (provider_specs) |spec| {
                if (!std.mem.eql(u8, spec.id, pid) or mdl.len == 0) continue;
                const m = try arena.dupe(u8, mdl);
                const provider = keys.providerById(pid, m) catch {
                    try offerProviderAuth(root, keys, arena, out, pid, m);
                    return;
                };
                try switchProvider(root, arena, provider, out);
                return;
            }
        }
        // If the query names a provider (e.g. "openai"), switch to THAT
        // provider on its default model — not the priority router's pick.
        for (provider_specs) |spec| {
            if (!std.mem.eql(u8, spec.id, arg)) continue;
            // Local OpenAI-compatible servers (LM Studio :1234, mlx-lm :8080) serve a
            // live, user-loaded model set — list what's actually there instead of a
            // baked default. One loaded → switch straight to it; many → list to pick.
            if (isLocalUrl(spec.url)) {
                const key = keys.get(spec.id) orelse {
                    try offerProviderAuth(root, keys, arena, out, spec.id, spec.default_model);
                    return;
                };
                const murl = openAiModelsUrl(arena, spec.url);
                const models = fetchOpenAIModels(root.io, root.gpa, arena, murl, key);
                if (models.len == 0) {
                    try out.print("{s}{s}: no models at {s} — start the server and load a model{s}\n", .{ style.yellow, spec.id, murl, style.reset });
                    try out.flush();
                    return;
                }
                if (models.len == 1) {
                    try switchProvider(root, arena, keys.build(spec, key, try arena.dupe(u8, models[0])), out);
                    return;
                }
                try out.print("{s}{s} models{s} — pick with {s}/model {s} <id>{s}:\n", .{ style.bold, spec.id, style.reset, style.cyan, spec.id, style.reset });
                for (models) |id| try out.print("  {s}{s}{s}\n", .{ style.cyan, id, style.reset });
                try out.flush();
                return;
            }
            const provider = keys.providerById(spec.id, spec.default_model) catch {
                try offerProviderAuth(root, keys, arena, out, spec.id, spec.default_model);
                return;
            };
            try switchProvider(root, arena, provider, out);
            return;
        }
        const resolved = resolveModelName(keys.*, arg);
        const name = try arena.dupe(u8, resolved orelse arg);
        const provider = keys.providerFor(name) catch {
            for (model_table) |mt| if (std.mem.eql(u8, mt.name, name)) {
                try offerProviderAuth(root, keys, arena, out, mt.provider, name);
                return;
            };
            try out.writeAll("no API key for any provider serving that model — see /models, or add one with /key <provider> <key>\n");
            try out.flush();
            return;
        };
        try switchProvider(root, arena, provider, out);
        if (resolved == null) {
            // Not in the model table: providerFor routed it to the claude*/
            // gateway fallback. Say so — the API will reject a typo'd name.
            try out.print("{s}⚠ '{s}' isn't in the model table — sent to {s} as-is; the first request will fail if it doesn't exist (/models lists known names){s}\n", .{ style.dim, name, provider.id, style.reset });
            try out.flush();
        }
        return;
    }
    if (std.mem.eql(u8, line, "/compact")) {
        _ = root.compact() catch |err| switch (err) {
            error.ApiError => {},
            else => |e| return e,
        };
        return;
    }
    if (std.mem.startsWith(u8, line, "/rewind")) {
        // Conversation rewind (à la Claude Code): drop a past prompt and
        // everything after it, so you can branch from an earlier point.
        // Human turns are user messages whose content is a plain string
        // (tool-result user messages carry a content array).
        const arg = std.mem.trim(u8, line["/rewind".len..], " \t");
        var turns: std.ArrayList(usize) = .empty;
        defer turns.deinit(root.gpa);
        for (root.messages.items, 0..) |m, i| {
            if (m != .object) continue;
            const role = if (m.object.get("role")) |r| (if (r == .string) r.string else "") else "";
            if (!std.mem.eql(u8, role, "user")) continue;
            if (m.object.get("content")) |c| if (c == .string) try turns.append(root.gpa, i);
        }
        if (turns.items.len == 0) {
            try out.writeAll("nothing to rewind — no prompts in this conversation yet\n");
            try out.flush();
            return;
        }
        if (arg.len == 0) {
            try out.writeAll("rewind to before which prompt?\n");
            for (turns.items, 1..) |idx, n| {
                var snip = if (root.messages.items[idx].object.get("content")) |c| (if (c == .string) c.string else "[image]") else "";
                if (std.mem.indexOfScalar(u8, snip, '\n')) |nl| snip = snip[0..nl];
                const shown = if (snip.len > 70) snip[0..70] else snip;
                try out.print("  {s}{d}{s}: {s}{s}\n", .{ style.cyan, n, style.reset, shown, if (snip.len > 70) "…" else "" });
            }
            try out.print("{s}usage: /rewind <n> — drops prompt <n>+after and reverts its write_file/edit_file changes (bash edits aren't tracked){s}\n", .{ style.dim, style.reset });
            try out.flush();
            return;
        }
        const n = std.fmt.parseInt(usize, arg, 10) catch 0;
        if (n < 1 or n > turns.items.len) {
            try out.print("invalid — pick 1..{d} (see /rewind)\n", .{turns.items.len});
            try out.flush();
            return;
        }
        const cut = turns.items[n - 1];
        const dropped = root.messages.items.len - cut;
        root.messages.items.len = cut; // truncate (entries are arena-owned)
        root.last_context_tokens = 0;
        // Restore files written/edited during the rewound turns, and re-point the
        // turn counter so the next prompt re-takes turn n.
        var restored: usize = 0;
        if (root.snapshots) |snaps| {
            restored = snaps.restore(@intCast(n));
            snaps.turn = @intCast(n - 1);
        }
        try out.print("⏪ rewound to before prompt {d} — dropped {d} message(s)", .{ n, dropped });
        if (restored > 0) {
            try out.print(", restored {d} file(s)", .{restored});
        } else {
            try out.print("{s} (no tracked file changes){s}", .{ style.dim, style.reset });
        }
        try out.writeAll("\n");
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/fast") or std.mem.eql(u8, line, "/fast on") or std.mem.eql(u8, line, "/fast off")) {
        root.fast = if (std.mem.eql(u8, line, "/fast on")) true else if (std.mem.eql(u8, line, "/fast off")) false else !root.fast;
        _ = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("fast mode: {s}{s}\n", .{
            if (root.fast) "on" else "off",
            if (root.provider.kind != .responses) " (codex only — current model ignores it)" else "",
        });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/thinking") or std.mem.eql(u8, line, "/thinking on") or std.mem.eql(u8, line, "/thinking off")) {
        root.show_thinking = if (std.mem.eql(u8, line, "/thinking on")) true else if (std.mem.eql(u8, line, "/thinking off")) false else !root.show_thinking;
        const saved = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("thinking: {s} ({s}){s}\n", .{
            if (root.show_thinking) "shown" else "collapsed",
            if (root.show_thinking) "stream reasoning live" else "spinner only",
            if (saved) "" else " (not persisted)",
        });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/title") or std.mem.eql(u8, line, "/title on") or std.mem.eql(u8, line, "/title off")) {
        root.ai_title = if (std.mem.eql(u8, line, "/title on")) true else if (std.mem.eql(u8, line, "/title off")) false else !root.ai_title;
        const saved = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("AI session title: {s} ({s}){s}\n", .{
            if (root.ai_title) "on" else "off",
            if (root.ai_title) "name the tab from your first prompt" else "use the prompt text verbatim",
            if (saved) "" else " (not persisted)",
        });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/ultracode") or std.mem.startsWith(u8, line, "/ultracode ")) {
        const arg = std.mem.trim(u8, line["/ultracode".len..], " \t\r\n");
        const next = if (arg.len == 0) blk: {
            if (use_color and root.in != null) {
                break :blk pickUltracodeMode(root, arena, out) orelse return;
            }
            try out.writeAll("usage: /ultracode on|off\n");
            try out.flush();
            return;
        } else if (std.mem.eql(u8, arg, "on"))
            true
        else if (std.mem.eql(u8, arg, "off"))
            false
        else {
            try out.writeAll("usage: /ultracode on|off\n");
            try out.flush();
            return;
        };
        root.ultracode_mode = next;
        const saved = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("ultracode mode: {s}{s}\n", .{ if (root.ultracode_mode) "on" else "off", if (saved) "" else " (not persisted)" });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/effort") or std.mem.startsWith(u8, line, "/reasoning")) {
        const prefix: []const u8 = if (std.mem.startsWith(u8, line, "/effort")) "/effort" else "/reasoning";
        const arg = std.mem.trim(u8, line[prefix.len..], " \t");
        if (std.mem.eql(u8, arg, "low")) {
            root.reasoning = .low;
        } else if (std.mem.eql(u8, arg, "medium") or std.mem.eql(u8, arg, "med")) {
            root.reasoning = .medium;
        } else if (std.mem.eql(u8, arg, "high")) {
            root.reasoning = .high;
        } else if (arg.len != 0) {
            try out.writeAll("usage: /effort low|medium|high\n");
            try out.flush();
            return;
        }
        _ = saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
        try out.print("reasoning effort: {s}{s}\n", .{
            @tagName(root.reasoning),
            if (!root.effortApplies()) " (current model ignores it — applies to codex, deepseek, codegraff)" else "",
        });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/keepcontext")) {
        const arg = std.mem.trim(u8, line["/keepcontext".len..], " \t");
        if (std.mem.eql(u8, arg, "on")) {
            root.keep_context = true;
        } else if (std.mem.eql(u8, arg, "off")) {
            root.keep_context = false;
        } else root.keep_context = !root.keep_context; // bare: toggle
        try out.print("keep-context across model switches: {s} — {s}\n", .{
            if (root.keep_context) "ON" else "off",
            if (root.keep_context) "a wire-format switch (e.g. → claude) translates & keeps the dialogue" else "a wire-format switch clears history",
        });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/key")) {
        const rest = std.mem.trim(u8, line["/key".len..], " \t");
        if (rest.len == 0) { // show key status + how to add
            try out.writeAll("API keys (✓ = set via env / Keychain / login):\n");
            for (provider_specs) |spec| {
                try out.print("  {s} {s:<10}  {s}\n", .{ if (keys.get(spec.id) != null) "✓" else "·", spec.id, spec.env_key });
            }
            try out.print("{s}add one:  /key <provider> <key>   (used now + saved to the macOS Keychain){s}\n", .{ style.dim, style.reset });
            try out.flush();
            return;
        }
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            try out.writeAll("usage: /key <provider> <key>\n");
            try out.flush();
            return;
        };
        const pid = rest[0..sp];
        const key = std.mem.trim(u8, rest[sp + 1 ..], " \t");
        var idx: ?usize = null;
        for (provider_specs, 0..) |spec, i| if (std.mem.eql(u8, spec.id, pid)) {
            idx = i;
        };
        if (idx == null) {
            try out.print("unknown provider '{s}' — see /model for the list\n", .{pid});
            try out.flush();
            return;
        }
        if (key.len == 0) {
            try out.writeAll("usage: /key <provider> <key>\n");
            try out.flush();
            return;
        }
        keys.values[idx.?] = arena.dupe(u8, key) catch key; // live, usable immediately
        const home = root.home;
        const saved = storeKey(root.io, root.gpa, arena, home, pid, key); // persist
        try out.print("✓ {s} key set (live{s}) — now: /model {s}\n", .{ pid, if (saved) " + Keychain" else "", pid });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/login")) {
        // Interactive OAuth sign-in for the providers that have a device/PKCE
        // flow (codegraff, codex/ChatGPT, kimi). Mirrors the `graff login`
        // subcommands but runs in-session and pulls the fresh key into the live
        // Keys, so this conversation keeps going without a restart. Pure
        // API-key providers don't log in — they point back at /key.
        const rest = std.mem.trim(u8, line["/login".len..], " \t");
        var lit = std.mem.tokenizeAny(u8, rest, " \t");
        var target = lit.next() orelse "";
        const refresh = while (lit.next()) |a| {
            if (std.mem.eql(u8, a, "--refresh")) break true;
        } else false;
        const login_targets = [_]PickItem{
            .{ .name = "codegraff", .desc = "free codegraff key (device-code OAuth)" },
            .{ .name = "codex", .desc = "ChatGPT / OpenAI sign-in (alias: oai)" },
            .{ .name = "kimi", .desc = "Kimi Code sign-in (device-code OAuth)" },
        };
        // Bare /login: pick a provider on a TTY, else just list the options.
        if (target.len == 0) {
            if (use_color and root.in != null) {
                const idx = listPicker(root, arena, out, "Log in to \xe2\x80\xba", &login_targets) orelse return;
                target = login_targets[idx].name;
            } else {
                try out.writeAll("interactive logins (OAuth \xe2\x80\x94 no key to paste):\n");
                for (login_targets) |t| try out.print("  {s} /login {s:<10} {s}\n", .{ if (keys.get(t.name) != null) "\xe2\x9c\x93" else "\xc2\xb7", t.name, t.desc });
                try out.print("{s}other providers use an API key:  /key <provider> <key>{s}\n", .{ style.dim, style.reset });
                try out.flush();
                return;
            }
        }
        // codex is the OpenAI/ChatGPT login; accept the natural aliases.
        if (std.mem.eql(u8, target, "oai") or std.mem.eql(u8, target, "openai") or
            std.mem.eql(u8, target, "chatgpt") or std.mem.eql(u8, target, "gpt"))
            target = "codex";
        if (std.mem.eql(u8, target, "graff")) target = "codegraff";

        const home = root.home;
        try out.flush(); // hand stdout to the login flow's own writer
        if (std.mem.eql(u8, target, "codegraff")) {
            oauth.codegraffLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 codegraff login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, target, "codex")) {
            oauth.codexLogin(root.io, root.gpa, arena, home, refresh) catch |err| {
                try out.print("\xe2\x9c\x97 codex login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, target, "kimi")) {
            oauth.kimiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 kimi login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else {
            // A pure API-key provider, or something unrecognized.
            for (provider_specs) |spec| if (std.mem.eql(u8, spec.id, target)) {
                try out.print("{s} uses an API key, not a login \xe2\x80\x94 /key {s} <key>\n", .{ target, target });
                try out.flush();
                return;
            };
            try out.print("can't log into '{s}' \xe2\x80\x94 try /login codegraff | codex | kimi (others: /key <provider> <key>)\n", .{target});
            try out.flush();
            return;
        }
        // Login wrote its credential file; pull the key into the live session.
        reloadLoginKey(root, keys, arena, target);
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/image")) {
        const path = std.mem.trim(u8, line["/image".len..], " \t");
        if (path.len == 0) {
            if (root.pending_image) |pi| {
                try out.print("staged image: {s} — send a message to include it ('/image clear' to drop)\n", .{pi.label});
            } else {
                try out.writeAll("usage: /image <path.png|jpg|gif|webp>  (attaches to your next message)\n");
            }
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, path, "clear")) {
            root.pending_image = null;
            try out.writeAll("cleared the staged image\n");
            try out.flush();
            return;
        }
        switch (stageImagePath(root, path)) {
            .no_vision => try out.print("⚠ {s} can't see images — switch to a vision model first, e.g. /model claude-opus-4-8 or /model gpt-5.5\n", .{root.provider.model}),
            .read_fail => try out.print("can't read '{s}' (missing, or larger than 5MB)\n", .{path}),
            .ok => try out.print("📎 attached {s} — sent with your next message\n", .{path}),
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/paste")) {
        if (builtin.os.tag != .macos) {
            try out.writeAll("clipboard image paste is macOS-only — use /image <path>\n");
            try out.flush();
            return;
        }
        if (!visionCapable(root.provider)) {
            try out.print("⚠ {s} can't see images — /model to a vision model (claude-*, gpt-5*) first\n", .{root.provider.model});
            try out.flush();
            return;
        }
        const p = grabClipboardImage(root.io) orelse {
            try out.writeAll("no image on the clipboard — copy an image first (text? just paste it normally)\n");
            try out.flush();
            return;
        };
        switch (stageImagePath(root, p)) {
            .ok => try out.writeAll("📎 clipboard image attached — sent with your next message\n"),
            .no_vision => try out.print("⚠ {s} can't see images\n", .{root.provider.model}),
            .read_fail => try out.writeAll("failed to read the clipboard image\n"),
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/strict")) {
        root.strict = !root.strict;
        try out.print("strict mode {s} — {s}\n", .{
            if (root.strict) "ON" else "off",
            if (root.strict) "every message must be a tool; finish with attempt_completion" else "free-text replies allowed",
        });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/todo")) {
        try out.print("{s}\n", .{root.renderTodos()});
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/jobs")) {
        jobs.g_jobs.mutex.lockUncancelable(root.io);
        defer jobs.g_jobs.mutex.unlock(root.io);
        if (jobs.g_jobs.list.items.len == 0) {
            try out.writeAll("no background jobs — the model starts one with bash {run_in_background: true}\n");
            try out.flush();
            return;
        }
        try out.print("{s}background jobs{s}\n", .{ style.bold, style.reset });
        for (jobs.g_jobs.list.items) |job| {
            var sbuf: [32]u8 = undefined;
            const status: []const u8 = if (!job.done)
                "running"
            else if (job.killed)
                "killed"
            else if (job.exit_code) |c|
                (std.fmt.bufPrint(&sbuf, "exit {d}", .{c}) catch "exited")
            else
                "abnormal";
            try out.print("  {s}{d:>3}{s}  {s}{s:<8}{s} {d:>7} unread B  {s}\n", .{
                style.cyan,                               job.id,                  style.reset,
                if (job.done) style.dim else style.green, status,                  style.reset,
                job.buf.items.len - job.cursor,           utf8Prefix(job.cmd, 60),
            });
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/cost")) {
        const c = g_cost.snap(root.io);
        if (c.api_calls == 0) {
            try out.writeAll("no API calls yet this session\n");
            try out.flush();
            return;
        }
        try out.print("{s}session usage{s}\n", .{ style.bold, style.reset });
        try out.print("  api calls: {d}", .{c.api_calls});
        if (c.sub_calls > 0) try out.print(" ({d} subscription, flat-rate)", .{c.sub_calls});
        if (c.unpriced_calls > 0) try out.print(" ({d} on unpriced models)", .{c.unpriced_calls});
        try out.print("\n  tokens:    {d} in ({d} cached) + {d} out\n", .{ c.in_tokens + c.cache_tokens, c.cache_tokens, c.out_tokens });
        try out.print("  cost:      {s}${d:.4}{s}{s}\n", .{
            style.green,                                                                                     c.usd, style.reset,
            if (c.sub_calls > 0 or c.unpriced_calls > 0) " (API-key calls with a known price only)" else "",
        });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/mcp")) {
        const arg = std.mem.trim(u8, line["/mcp".len..], " \t");
        const reg = root.registry.?; // always present now
        if (std.mem.startsWith(u8, arg, "add")) {
            // /mcp add <name> <command> [args...]
            var it = std.mem.tokenizeAny(u8, arg["add".len..], " \t");
            const name = it.next() orelse {
                try out.writeAll("usage: /mcp add <name> <command> [args...]   e.g. /mcp add fs npx -y @modelcontextprotocol/server-filesystem .\n");
                try out.flush();
                return;
            };
            const command = it.next() orelse {
                try out.writeAll("usage: /mcp add <name> <command> [args...]\n");
                try out.flush();
                return;
            };
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(arena);
            while (it.next()) |a| try args.append(arena, a);
            const added = reg.addServer(name, command, args.items) catch |err| {
                try out.print("{s}✗ failed to add MCP server '{s}': {t}{s}\n", .{ style.red, name, err, style.reset });
                try out.flush();
                return;
            };
            // Re-render the tool lists so the new tools reach the model.
            root.tools_anthropic = try renderRootTools(arena, .anthropic, &root_specs, reg.tools);
            root.tools_openai = try renderRootTools(arena, .openai, &root_specs, reg.tools);
            root.tools_responses = try renderRootTools(arena, .responses, &root_specs, reg.tools);
            const persisted = persistMcpServer(root.io, arena, name, command, args.items);
            var has_note = false;
            for (mcp_notes) |mn| if (std.mem.eql(u8, mn.server, name)) {
                has_note = true;
            };
            try out.print("{s}✓{s} connected MCP server {s}{s}{s} — {d} tool(s){s}{s}\n", .{
                style.green, style.reset, style.cyan, name, style.reset, added,
                if (persisted) " · saved to .mcp.json" else " · (not persisted)",
                if (has_note) " · restart the harness to add its context note" else "",
            });
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "trust")) {
            // Connect workspace .mcp.json servers that were skipped at startup
            // (consent declined / no --yolo), live, without a restart.
            const n = reg.trustWorkspace(mcp_config_path) catch |err| {
                try out.print("{s}✗ /mcp trust failed: {t}{s}\n", .{ style.red, err, style.reset });
                try out.flush();
                return;
            };
            if (n == 0) {
                try out.writeAll("no untrusted workspace MCP server(s) to connect.\n");
            } else {
                // Re-render the tool lists so the new tools reach the model.
                root.tools_anthropic = try renderRootTools(arena, .anthropic, &root_specs, reg.tools);
                root.tools_openai = try renderRootTools(arena, .openai, &root_specs, reg.tools);
                root.tools_responses = try renderRootTools(arena, .responses, &root_specs, reg.tools);
                try out.print("{s}✓{s} trusted workspace — connected {d} MCP server(s); {d} tool(s) total\n", .{ style.green, style.reset, n, reg.tools.len });
            }
            try out.flush();
            return;
        }
        // Plain /mcp: list servers (with tool counts) then tools.
        const pending = reg.pendingWorkspace(mcp_config_path);
        if (reg.servers.len == 0) {
            try out.writeAll("no MCP servers connected.\n  add one: /mcp add <name> <command> [args...]\n  e.g.   /mcp add fs npx -y @modelcontextprotocol/server-filesystem .\n");
        } else {
            try out.print("{d} MCP server(s), {d} tool(s):\n", .{ reg.servers.len, reg.tools.len });
            for (reg.servers, 0..) |srv, i| {
                try out.print("  {s}{s}{s}  (mcp {s}, {d} tool(s))\n", .{ style.cyan, srv.name, style.reset, srv.protocol_version, reg.toolCount(i) });
            }
            for (reg.tools) |t| try out.print("    {s}{s}{s}\n", .{ style.dim, t.qualified_name, style.reset });
            try out.writeAll("  add more: /mcp add <name> <command> [args...]\n");
        }
        if (pending > 0) try out.print("  {s}{d} workspace server(s) not connected — /mcp trust to connect them{s}\n", .{ style.dim, pending, style.reset });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/models")) {
        try out.writeAll("model                      ctx      compact@   provider    key  vision\n");
        for (model_table) |m| {
            const has_key = keys.get(m.provider) != null;
            const current = std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id);
            try out.print("{s:<26} {d:>5}k   {d:>5}k    {s:<11} {s}    {s}{s}\n", .{
                m.name,
                m.context / 1000,
                m.context / 10 * 8 / 1000,
                m.provider,
                if (has_key) "✓" else "—",
                if (visionModel(m.name)) "✓" else "—",
                if (current) "  ← current" else "",
            });
        }
        try out.print("(unknown models: {d}k ctx; claude* → anthropic, else → codegraff)\n", .{default_context / 1000});
        // Live LM Studio models: query the local server so loaded models show up
        // in /models without hand-typing their ids. Best-effort and silent if the
        // server is down. Only probe when the user actually uses lmstudio (key set
        // or it's the current provider) so we never make a stray localhost hit.
        if (keys.get("lmstudio") != null or std.mem.eql(u8, root.provider.id, "lmstudio")) lmstudio: {
            var base: []const u8 = "";
            for (provider_specs) |sp| {
                if (std.mem.eql(u8, sp.id, "lmstudio")) {
                    base = sp.url;
                    break;
                }
            }
            if (base.len == 0) break :lmstudio;
            const suffix = "/chat/completions";
            const root_url = if (std.mem.endsWith(u8, base, suffix)) base[0 .. base.len - suffix.len] else base;
            const url = std.fmt.allocPrint(arena, "{s}/models", .{root_url}) catch break :lmstudio;
            var aw: Io.Writer.Allocating = .init(arena);
            defer aw.deinit();
            const res = root.client.fetch(.{
                .location = .{ .url = url },
                .method = .GET,
                .response_writer = &aw.writer,
                .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
            }) catch break :lmstudio; // server not running → skip silently
            if (@intFromEnum(res.status) != 200) break :lmstudio;
            if (aw.writer.buffered().len > 256 * 1024) break :lmstudio;
            const parsed = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch break :lmstudio;
            if (parsed != .object) break :lmstudio;
            const data = parsed.object.get("data") orelse break :lmstudio;
            if (data != .array) break :lmstudio;
            const has_key = keys.get("lmstudio") != null;
            var printed_header = false;
            for (data.array.items) |item| {
                if (item != .object) continue;
                const idv = item.object.get("id") orelse continue;
                if (idv != .string) continue;
                const id = idv.string;
                if (std.mem.indexOf(u8, id, "embed") != null) continue; // skip embedding models — not chat targets
                if (!printed_header) {
                    try out.print("{s}lm studio (live @ {s}):{s}\n", .{ style.dim, root_url, style.reset });
                    printed_header = true;
                }
                const current = std.mem.eql(u8, root.provider.id, "lmstudio") and std.mem.eql(u8, id, root.provider.model);
                try out.print("{s:<26} {s:>6}   {s:>6}    {s:<11} {s}    {s}{s}\n", .{
                    id,
                    "—",
                    "—",
                    "lmstudio",
                    if (has_key) "✓" else "—",
                    if (visionModel(id)) "✓" else "—",
                    if (current) "  ← current" else "",
                });
            }
            if (printed_header) try out.print("{s}  copy an id above: /model lmstudio <id>{s}\n", .{ style.dim, style.reset });
        }
        try out.print("{s}tip: /model <name> (fuzzy) · /model <provider> (its default) · /model <provider> <model> (pin, e.g. 'codex gpt-5.5'){s}\n", .{ style.dim, style.reset });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/yolo")) {
        const on = root.approvals.?.toggleYolo(root.io);
        try out.print("yolo mode {s} — {s}\n", .{
            if (on) "ON" else "off",
            if (on) "bash runs without asking" else "unapproved bash commands prompt y/a/n",
        });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/trace")) {
        if (root.tracer) |tr| {
            const on = tr.toggle();
            try out.print("tracing {s} → {s}\n", .{ if (on) "ON" else "off", trace_path });
        } else {
            try out.writeAll("no trace file (failed to open at startup)\n");
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/fleet") or std.mem.startsWith(u8, line, "/fleet ")) {
        const arg = std.mem.trim(u8, line["/fleet".len..], " \t");
        if (arg.len == 0) {
            try out.print("fleet contribution: {s} — federated DGM (propose/submit/elite_pull). /fleet off to disable, /fleet on to enable (or GRAFF_FLEET=off).\n", .{if (g_fleet) "ON" else "off"});
        } else if (std.mem.eql(u8, arg, "on")) {
            g_fleet = true;
            try out.writeAll("fleet ON — this session's persona variants + scores contribute to the federated grid.\n");
        } else if (std.mem.eql(u8, arg, "off")) {
            g_fleet = false;
            try out.writeAll("fleet off — no propose/submit/elite_pull this session (usage telemetry unaffected; /fleet on to re-enable).\n");
        } else {
            try out.writeAll("usage: /fleet [on|off]\n");
        }
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/save")) {
        const arg = std.mem.trim(u8, line["/save".len..], " \t");
        const name = if (arg.len == 0) root.session_name else arg;
        saveSession(root, arena, name) catch |err| {
            try out.print("save failed: {t}\n", .{err});
            try out.flush();
            return;
        };
        root.session_name = name;
        try out.print("saved session → {s}{s}\n", .{ name, session_ext });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/resume")) {
        const arg = std.mem.trim(u8, line["/resume".len..], " \t");
        var name: []const u8 = if (arg.len == 0) "last" else arg;
        // Bare /resume on a TTY: pick from the saved sessions interactively,
        // labeled by stored title + age instead of raw file names (#109).
        if (arg.len == 0 and use_color and root.in != null) {
            var entries = listSavedSessions(root, arena);
            defer entries.deinit(arena);
            if (entries.items.len == 0) {
                try out.writeAll("(no saved sessions in cwd — /save creates one)\n");
                try out.flush();
                return;
            }
            var sessions: std.ArrayList(PickItem) = .empty;
            defer sessions.deinit(arena);
            for (entries.items) |e| {
                const age = sessionAge(arena, root.io, e.updated_ms);
                const desc = if (e.title == null)
                    age
                else if (age.len > 0)
                    std.fmt.allocPrint(arena, "{s} · {s}", .{ age, e.base }) catch e.base
                else
                    e.base;
                try sessions.append(arena, .{ .name = e.title orelse e.base, .desc = desc });
            }
            const idx = listPicker(root, arena, out, "Resume session ›", sessions.items) orelse return;
            name = entries.items[idx].base;
        }
        loadSession(root, keys.*, arena, name) catch |err| {
            switch (err) {
                error.FileNotFound => try out.print("no session named '{s}' ({s}{s} not found in cwd) — /sessions lists saved ones\n", .{ name, name, session_ext }),
                else => try out.print("resume failed: {t}\n", .{err}),
            }
            try out.flush();
            return;
        };
        root.session_name = name;
        try out.print("resumed {s}{s} — {d} message(s), {s} via {s}{s}\n", .{
            name,                                 session_ext, root.messages.items.len, root.provider.model, root.provider.id,
            if (root.strict) " (strict)" else "",
        });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/sessions")) {
        var entries = listSavedSessions(root, arena);
        defer entries.deinit(arena);
        for (entries.items) |e| {
            const age = sessionAge(arena, root.io, e.updated_ms);
            const cur = if (std.mem.eql(u8, e.base, root.session_name)) "  ← current" else "";
            if (e.title) |t| {
                try out.print("  {s}  {s}{s}{s}{s}{s}{s}\n", .{ t, style.dim, e.base, if (age.len > 0) " · " else "", age, style.reset, cur });
            } else {
                try out.print("  {s}{s}{s}{s}{s}{s}\n", .{ e.base, style.dim, if (age.len > 0) "  " else "", age, style.reset, cur });
            }
        }
        if (entries.items.len == 0) try out.writeAll("(no saved sessions in cwd)\n");
        try out.flush();
        return;
    }
    // Unknown slash command → a short error + pointer (only /help dumps the list).
    if (!std.mem.eql(u8, line, "/help")) {
        try out.print("unknown command '{s}' — /help for the list\n", .{line});
        try out.flush();
        return;
    }
    try out.writeAll(
        \\commands:  (a bare "/" opens this list as a filterable menu)
        \\  /model <name>   switch model/provider, fuzzy match (e.g. "sonnet", "opus")
        \\  /models         list known models, context windows, compaction points
        \\  /clear          wipe the conversation and start fresh
        \\  /new            start a fresh autosaved session
        \\  /rename <title> set the current session title
        \\  /goal [text]    set/show a standing objective (tracked as a checklist); /goal clear clears
        \\  /loop <prompt>  run an autonomous plan→act→verify pass
        \\  /plan           toggle plan mode: read-only explore + propose; writes/edits denied
        \\  /ultracode      toggle persistent workflow mode; bare opens on/off picker, or /ultracode on|off
        \\  /key [prov key] show API-key status; /key <provider> <key> adds one live (+ Keychain)
        \\  /login [tgt]    OAuth sign-in (no key to paste): codegraff | codex (alias oai) | kimi; bare → picker
        \\  /keepcontext    toggle keeping the conversation when /model switches wire format (default on)
        \\  /effort         thinking depth: low|medium|high (codex, deepseek, codegraff; default medium, persists)
        \\  /reasoning      alias for /effort
        \\  /fast           codex only: priority service tier for lower latency (toggle, persists)
        \\  /strict         toggle "every message is a tool" mode
        \\  /yolo           toggle bash auto-approval (skip permission prompts)
        \\  /trace          toggle the JSONL event trace (harness.trace.jsonl)
        \\  /trajectory     show this session's agent tree — turns + spawned
        \\                  subagents with system-prompt fingerprints
        \\                  (harness.trajectory.jsonl, DGM-style)
        \\  /agents         list agent types — builtin personas + .harness/agents/*.md
        \\                  (spawn with subagent agent:"<name>")
        \\  /compact        summarize history into a fresh context
        \\  /rewind [n]     list past prompts; /rewind <n> drops prompt n+after & reverts its file edits
        \\  /image <path>   attach an image to your next message (vision models only)
        \\  /paste          attach the clipboard image — macOS; also Ctrl-V (⌘V can't be captured)
        \\  /save [name]    write the conversation to <name>.session.json (default: current)
        \\  /resume [name]  restore a saved conversation (no arg → interactive picker)
        \\  /sessions       list saved sessions in the cwd
        \\  /todo           show the current task list
        \\  /animation      pick the thinking animation (braille/pulse/orbit-dots/block-wave/
        \\                  shimmer/matrix/pacman/starfield/random/off); persists to settings
        \\  /mcp [add …]    list MCP servers/tools; /mcp add <name> <cmd> [args...] connects one live; /mcp trust connects skipped workspace servers
        \\  exit / /exit    quit (also: ctrl-d, or ctrl-c on an empty line)
        \\
        \\esc during a response interrupts the turn (what streamed stays in history).
        \\"always allow" answers persist to .harness/settings.json in the cwd.
        \\codeword: include "ultracode" in any message to force one multi-agent
        \\workflow turn; /ultracode on persists that behavior for future prompts.
        \\
        \\launch flags: --model <name> · --yolo (skip prompts) · -p "prompt" (one-shot) · --system-prompt/--append-system-prompt · --timing · --cost · --json (SDK protocol) · --help · --version
        \\subcommands: `graff login [codex]` (OAuth) · `graff key set <provider> <key>` (Keychain) · `graff --schema`
        \\
    );
    try out.flush();
}

const session_ext = ".session.json";
const sessions_dir = ".graff/sessions"; // title-named session files live here (resume reads this)

/// Path to a session file: .graff/sessions/<name>.session.json.
fn sessionPath(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ sessions_dir, name, session_ext });
}

/// Session-list metadata peeked from a session file WITHOUT parsing the
/// (potentially multi-MB) messages array: saveSession writes "title" and
/// "updated_ms" before "messages", so parsing the header slice alone is
/// enough. Zero-value fields when the file predates them or the header
/// can't be read — callers fall back to the raw session name (#109).
const SessionMeta = struct { title: ?[]const u8 = null, updated_ms: i64 = 0 };

fn sessionMetaFromBytes(arena: Allocator, data: []const u8) SessionMeta {
    // Embedded quotes inside string values are escaped in the file, so the
    // raw needle can only match the real top-level "messages" key.
    const idx = std.mem.indexOf(u8, data, "\"messages\":") orelse return .{};
    const header = std.mem.trimEnd(u8, data[0..idx], " \t\r\n");
    if (header.len < 2 or header[header.len - 1] != ',') return .{};
    const hjson = std.fmt.allocPrint(arena, "{s}}}", .{header[0 .. header.len - 1]}) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(Value, arena, hjson, .{ .allocate = .alloc_always }) catch return .{};
    if (parsed != .object) return .{};
    return .{
        .title = if (parsed.object.get("title")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null,
        .updated_ms = if (parsed.object.get("updated_ms")) |v| (if (v == .integer) v.integer else 0) else 0,
    };
}

fn sessionMeta(root: *Agent, arena: Allocator, base: []const u8) SessionMeta {
    const path = sessionPath(arena, base) catch return .{};
    const data = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(8 * 1024 * 1024)) catch return .{};
    return sessionMetaFromBytes(arena, data);
}

/// "3m ago"-style age for the session lists; "" when the timestamp is missing.
fn sessionAge(arena: Allocator, io: Io, then_ms: i64) []const u8 {
    if (then_ms <= 0) return "";
    const s = @divTrunc(unixMs(io) - then_ms, 1000);
    if (s < 60) return "just now";
    if (s < 3600) return std.fmt.allocPrint(arena, "{d}m ago", .{@divTrunc(s, 60)}) catch "";
    if (s < 86_400) return std.fmt.allocPrint(arena, "{d}h ago", .{@divTrunc(s, 3600)}) catch "";
    return std.fmt.allocPrint(arena, "{d}d ago", .{@divTrunc(s, 86_400)}) catch "";
}

/// One row per saved session for the /resume picker and /sessions list:
/// newest first, keyed (and resumed) by the file base name.
const SessionEntry = struct { base: []const u8, title: ?[]const u8 = null, updated_ms: i64 = 0 };

fn listSavedSessions(root: *Agent, arena: Allocator) std.ArrayList(SessionEntry) {
    var entries: std.ArrayList(SessionEntry) = .empty;
    var dir = Io.Dir.cwd().openDir(root.io, sessions_dir, .{ .iterate = true }) catch return entries;
    defer dir.close(root.io);
    var it = dir.iterate();
    while (it.next(root.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, session_ext)) continue;
        const base = arena.dupe(u8, entry.name[0 .. entry.name.len - session_ext.len]) catch continue;
        const meta = sessionMeta(root, arena, base);
        entries.append(arena, .{ .base = base, .title = meta.title, .updated_ms = meta.updated_ms }) catch {};
    }
    std.mem.sort(SessionEntry, entries.items, {}, struct {
        fn newerFirst(_: void, a: SessionEntry, b: SessionEntry) bool {
            return a.updated_ms > b.updated_ms;
        }
    }.newerFirst);
    return entries;
}

test "sessionMetaFromBytes reads title + updated_ms from the header only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const meta = sessionMetaFromBytes(arena,
        \\{"provider":"codegraff","model":"glm-5.2","strict":false,"ultracode_mode":false,"goal":null,"title":"Fix \"login\" bug","updated_ms":1782294417239,"messages":[{"role":"user","content":"hi"}]}
    );
    try std.testing.expectEqualStrings("Fix \"login\" bug", meta.title.?);
    try std.testing.expectEqual(@as(i64, 1782294417239), meta.updated_ms);
}

test "sessionMetaFromBytes falls back cleanly on legacy/invalid headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const legacy = sessionMetaFromBytes(arena,
        \\{"provider":"kimi","model":"kimi-k2.7","strict":false,"messages":[]}
    );
    try std.testing.expect(legacy.title == null);
    try std.testing.expectEqual(@as(i64, 0), legacy.updated_ms);
    const tricky = sessionMetaFromBytes(arena,
        \\{"provider":"x","model":"y","goal":"say \"messages\": then stop","title":"T","updated_ms":5,"messages":[]}
    );
    try std.testing.expectEqualStrings("T", tricky.title.?);
    try std.testing.expectEqual(@as(i64, 5), tricky.updated_ms);
    try std.testing.expect(sessionMetaFromBytes(arena, "not json").title == null);
}

/// Filesystem-safe slug of an AI title: lowercase alnum, any other run collapses
/// to one '-', trimmed, capped at 60. "Fixing the login bug" -> "fixing-the-login-bug".
/// Returns "" for an empty/symbol-only title.
fn slugifyTitle(arena: Allocator, title: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var last_dash = true; // suppress a leading '-'
    for (title) |c| {
        if (buf.items.len >= 60) break;
        const lc = std.ascii.toLower(c);
        if ((lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9')) {
            buf.append(arena, lc) catch break;
            last_dash = false;
        } else if (!last_dash) {
            buf.append(arena, '-') catch break;
            last_dash = true;
        }
    }
    var s = buf.items;
    while (s.len > 0 and s[s.len - 1] == '-') s = s[0 .. s.len - 1];
    return s;
}

/// Rename an as-yet-untitled (session-<ts>) session to a slug of its AI title:
/// point session_name at a free <slug>[-N], write it there, and remove the old
/// file. Best-effort; only fires for the default timestamp name, so a manual
/// /rename or a resumed session keeps its name.
fn renameSession(root: *Agent, arena: Allocator, slug: []const u8) void {
    if (slug.len == 0) return;
    if (!std.mem.startsWith(u8, root.session_name, "session-")) return; // already titled
    if (std.mem.eql(u8, slug, root.session_name)) return;
    var name = slug;
    var n: usize = 2;
    while (n < 100) : (n += 1) {
        const p = sessionPath(arena, name) catch return;
        if (Io.Dir.cwd().statFile(root.io, p, .{})) |_| {
            name = std.fmt.allocPrint(arena, "{s}-{d}", .{ slug, n }) catch return;
        } else |_| break; // free
    }
    const old_name = root.session_name;
    root.session_name = arena.dupe(u8, name) catch return;
    saveSession(root, arena, root.session_name) catch {};
    if (sessionPath(arena, old_name)) |op| (Io.Dir.cwd().deleteFile(root.io, op) catch {}) else |_| {}
}

// Provider login/credential flows (Codex PKCE, Kimi + Codegraff device-code)
// live in oauth.zig (#123); it imports ansi + util and back-imports main for
// unixMs/kimi_user_agent/the codegraff base.
const oauth = @import("oauth.zig");
const CodexAuth = oauth.CodexAuth;

/// True for a provider served by a local server (LM Studio, mlx-lm) on the
/// loopback host — these expose a live, user-controlled model set.
fn isLocalUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "127.0.0.1") != null or std.mem.indexOf(u8, url, "localhost") != null;
}

/// Derive the OpenAI-compatible `/v1/models` URL from a provider's chat URL
/// (`…/v1/chat/completions` → `…/v1/models`).
fn openAiModelsUrl(arena: Allocator, chat_url: []const u8) []const u8 {
    const suffix = "/chat/completions";
    if (std.mem.endsWith(u8, chat_url, suffix))
        return std.fmt.allocPrint(arena, "{s}/models", .{chat_url[0 .. chat_url.len - suffix.len]}) catch chat_url;
    return chat_url;
}

/// GET an OpenAI-compatible `/v1/models` endpoint and return every model id it
/// advertises (arena-owned), or an empty slice on any failure. Lets `/model
/// <local-provider>` list what a local server (LM Studio :1234, mlx-lm :8080)
/// actually has loaded instead of a baked-in name.
fn fetchOpenAIModels(io: Io, gpa: Allocator, arena: Allocator, models_url: []const u8, key: []const u8) [][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{key}) catch return list.items;
    const extra = [_]std.http.Header{
        .{ .name = "authorization", .value = bearer },
        .{ .name = "Accept", .value = "application/json" },
    };
    const res = client.fetch(.{
        .location = .{ .url = models_url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = &extra,
    }) catch return list.items;
    if (@intFromEnum(res.status) != 200) return list.items;
    const v = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch return list.items;
    if (v != .object) return list.items;
    const data = v.object.get("data") orelse return list.items;
    if (data != .array) return list.items;
    for (data.array.items) |item| {
        if (item != .object) continue;
        if (strFieldObj(item.object, "id")) |id| if (id.len > 0)
            list.append(arena, arena.dupe(u8, id) catch continue) catch {};
    }
    return list.toOwnedSlice(arena) catch list.items;
}

test "openAiModelsUrl derives /v1/models from the chat URL; isLocalUrl flags loopback" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/v1/models", openAiModelsUrl(a.allocator(), "http://127.0.0.1:1234/v1/chat/completions"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1/models", openAiModelsUrl(a.allocator(), "http://127.0.0.1:8080/v1/chat/completions"));
    try std.testing.expect(isLocalUrl("http://127.0.0.1:1234/v1/chat/completions"));
    try std.testing.expect(isLocalUrl("http://localhost:1234/v1/chat/completions"));
    try std.testing.expect(!isLocalUrl("https://api.openai.com/v1/chat/completions"));
}

// ---------------------------------------------------------------------------
// `harness serve` — the same --json session protocol, served over HTTP so
// clients that cannot spawn a local process (edge runtimes, browsers, other
// machines) can still drive agents. The server is a thin bridge: each session
// is a real `harness --json` child process (the tested stdio path), and one
// HTTP request = one protocol request, streamed back as NDJSON until that
// request's terminal event. Endpoints:
//
//   GET    /healthz              → {"ok":true,...} (no auth)
//   GET    /v1/schema            → the `harness --schema` document
//   POST   /v1/sessions          → {"session_id":"<16 hex>"}; body may set
//                                  {"model","yolo","system_prompt","append_system_prompt"}
//   POST   /v1/sessions/<id>     → body is one protocol request object
//                                  ({"type":"user","text":...} etc); response
//                                  streams NDJSON events until turn/error/ack
//   DELETE /v1/sessions/<id>     → close the session (graceful: stdin EOF)
//
// Auth: --token / HARNESS_SERVE_TOKEN as a Bearer token. Binding a
// non-loopback host without a token is refused. CORS is fully open ONLY
// when a token is set (the token is then the actual gate); on token-less
// loopback no CORS headers are sent, so browsers stay same-origin.

// The `graff serve` HTTP bridge (HTTP <-> NDJSON child-process pool) lives in
// serve.zig (#123); it back-imports main for emitSchema + the version consts.
const serve = @import("serve.zig");

// ---------------------------------------------------------------------------

// Codegraff device-code login — mirrors graff's CodegraffDeviceStrategy:
// POST /v1/device/start → show verification_uri + user_code → poll
// /v1/device/poll until status "ok" yields the cg_sk_ key. Base derived from
// the codegraff provider URL (gateway.codegraff.com). The key is written to
// ~/.simple-harness-codegraff.json, which loadCodegraffKey reads at startup.
pub const codegraff_device_base = "https://gateway.codegraff.com";

// `graff cube` / `graff sandboxes` + the gateway REST helpers live in cube.zig
// (#123); it back-imports main for strFieldObj/intFieldObj + the gateway base.
const cube = @import("cube.zig");

// Safe API-key store. On macOS, keys live in the login Keychain (service
// "simple-harness", account=provider id) via the `security` CLI — never on
// disk in plaintext. Elsewhere they fall back to a 0600 file
// (~/.simple-harness-keys.json). `harness key set <provider> <key>` writes;
// startup reads for any provider whose env var isn't set (env always wins).
const keychain_service = "simple-harness";
const keys_file = ".simple-harness-keys.json";

/// User home directory env value: $HOME, or %USERPROFILE% on Windows (which has
/// no HOME). Key storage, sessions, history, login credentials, and saved model
/// all hang off this, so the Windows fallback is what makes them work there.
fn homeEnv(env: anytype) ?[]const u8 {
    if (env.get("HOME")) |h| return h;
    if (builtin.os.tag == .windows) {
        if (env.get("USERPROFILE")) |h| return h;
    }
    return null;
}

fn storeKey(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, provider: []const u8, key: []const u8) bool {
    if (builtin.os.tag == .macos) {
        var child = std.process.spawn(io, .{
            .argv = &.{ "security", "add-generic-password", "-U", "-s", keychain_service, "-a", provider, "-w", key },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return false;
        const term = child.wait(io) catch return false;
        return term == .exited and term.exited == 0;
    }
    // Linux/other: merge into a 0600 JSON file.
    _ = gpa;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, keys_file }) catch return false;
    var obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024))) |data| {
        if (std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) obj = v.object;
        } else |_| {}
    } else |_| {}
    obj.put(arena, provider, .{ .string = key }) catch return false;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(Value{ .object = obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.flush() catch return false;
    return true;
}

fn loadStoredKey(io: Io, arena: Allocator, home: []const u8, provider: []const u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        var child = std.process.spawn(io, .{
            .argv = &.{ "security", "find-generic-password", "-s", keychain_service, "-a", provider, "-w" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;
        defer _ = child.wait(io) catch {};
        const f = child.stdout orelse return null;
        var rbuf: [8 * 1024]u8 = undefined;
        var fr = f.readerStreaming(io, &rbuf);
        const out = fr.interface.allocRemaining(arena, .limited(64 * 1024)) catch return null;
        const key = std.mem.trim(u8, out, " \t\r\n");
        return if (key.len > 0) key else null;
    }
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, keys_file }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    if (v.object.get(provider)) |k| if (k == .string and k.string.len > 0) return k.string;
    return null;
}

/// `harness key set <provider> <key>` / `harness key list` — manage the safe
/// key store. Validates the provider id against provider_specs.
fn keyCommand(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        try out.writeAll("provider        env var               stored\n");
        for (provider_specs) |spec| {
            const stored = loadStoredKey(io, arena, home, spec.id) != null;
            try out.print("  {s:<14}{s:<22}{s}\n", .{ spec.id, spec.env_key, if (stored) "yes" else "—" });
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len < 3) {
            try out.writeAll("usage: graff key set <provider> <key>\n");
            try out.flush();
            return;
        }
        const provider = args[1];
        const key = args[2];
        var known = false;
        for (provider_specs) |spec| {
            if (std.mem.eql(u8, spec.id, provider)) known = true;
        }
        if (!known) {
            try out.print("unknown provider '{s}' — see /models for valid ids\n", .{provider});
            try out.flush();
            return;
        }
        if (storeKey(io, gpa, arena, home, provider, key)) {
            const where = if (builtin.os.tag == .macos) "macOS Keychain" else "~/" ++ keys_file;
            try out.print("✓ stored {s} key in the {s}\n", .{ provider, where });
        } else {
            try out.writeAll("✗ failed to store key\n");
        }
        try out.flush();
        return;
    }
    try out.writeAll("usage: graff key set <provider> <key>  |  graff key list\n");
    try out.flush();
}

fn sessionTitle(root: *Agent) []const u8 {
    if (root.session_title) |title| return title;
    for (root.messages.items) |m| {
        if (m != .object) continue;
        const role = if (m.object.get("role")) |v| (if (v == .string) v.string else "") else "";
        if (!std.mem.eql(u8, role, "user")) continue;
        if (m.object.get("content")) |c| switch (c) {
            .string => |text| return utf8Prefix(std.mem.trim(u8, text, " \t\r\n"), 80),
            .array => |arr| for (arr.items) |part| {
                if (part == .object) {
                    const typ = if (part.object.get("type")) |v| (if (v == .string) v.string else "") else "";
                    if (std.mem.eql(u8, typ, "text")) {
                        if (part.object.get("text")) |tv| if (tv == .string) return utf8Prefix(std.mem.trim(u8, tv.string, " \t\r\n"), 80);
                    }
                }
            },
            else => {},
        };
    }
    return "Untitled session";
}

/// Save the conversation (messages + provider id/model + strict flag) to
/// <name>.session.json in the cwd. The JSON message array is already the
/// provider-native wire shape, so resume is a verbatim restore.
fn saveSession(root: *Agent, arena: Allocator, name: []const u8) !void {
    var aw: Io.Writer.Allocating = .init(root.gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("provider");
    try s.write(root.provider.id);
    try s.objectField("model");
    try s.write(root.provider.model);
    try s.objectField("strict");
    try s.write(root.strict);
    try s.objectField("ultracode_mode");
    try s.write(root.ultracode_mode);
    try s.objectField("goal");
    if (root.goal) |goal| try s.write(goal) else try s.write(null);
    try s.objectField("title");
    if (root.session_title) |title| try s.write(title) else try s.write(sessionTitle(root));
    try s.objectField("updated_ms");
    try s.write(unixMs(root.io));
    try s.objectField("messages");
    try s.write(Value{ .array = root.messages });
    try s.endObject();

    Io.Dir.cwd().createDir(root.io, ".graff", .default_dir) catch {};
    Io.Dir.cwd().createDir(root.io, sessions_dir, .default_dir) catch {};
    const path = try sessionPath(arena, name);
    try Io.Dir.cwd().writeFile(root.io, .{ .sub_path = path, .data = aw.writer.buffered() });
}

/// Restore a saved session: parse the file (arena-owned), rebuild the
/// provider, and replace the live history. The wire format must still match
/// the restored provider's kind — same provider id guarantees it.
fn loadSession(root: *Agent, keys: Keys, arena: Allocator, name: []const u8) !void {
    const path = try sessionPath(arena, name);
    const data = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(8 * 1024 * 1024)) catch blk: {
        // backward-compat: older builds wrote <name>.session.json in cwd.
        const legacy = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, session_ext });
        break :blk try Io.Dir.cwd().readFileAlloc(root.io, legacy, arena, .limited(8 * 1024 * 1024));
    };
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.BadSession;
    const obj = parsed.object;
    const pid = if (obj.get("provider")) |v| v.string else return error.BadSession;
    const model = if (obj.get("model")) |v| v.string else return error.BadSession;
    const msgs = if (obj.get("messages")) |v| (if (v == .array) v.array else return error.BadSession) else return error.BadSession;
    const strict = if (obj.get("strict")) |v| (v == .bool and v.bool) else false;
    const ultracode_mode = if (obj.get("ultracode_mode")) |v| (v == .bool and v.bool) else false;
    const goal = if (obj.get("goal")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;
    const title = if (obj.get("title")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;

    root.provider = try keys.providerById(pid, model);
    root.messages = msgs;
    // Repair histories written by older builds where a Responses
    // `function_call_output.output` was persisted as a byte array instead of a
    // string. The Responses API rejects that ("input[N].output[0]: expected an
    // object, got an integer instead"), and we restore messages verbatim — so a
    // poisoned last.session.json would otherwise re-break every resume.
    for (root.messages.items) |*m| {
        if (m.* != .object) continue;
        const mtype = if (m.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (!std.mem.eql(u8, mtype, "function_call_output")) continue;
        const out = m.object.get("output") orelse continue;
        if (out == .string) continue; // already correct
        var repaired: std.ArrayList(u8) = .empty;
        if (out == .array) {
            for (out.array.items) |el| {
                if (el == .integer and el.integer >= 0 and el.integer <= 255) {
                    try repaired.append(arena, @intCast(el.integer));
                }
            }
        }
        try m.object.put(arena, "output", .{ .string = repaired.items });
    }
    root.strict = strict;
    root.ultracode_mode = ultracode_mode;
    root.goal = goal;
    root.session_title = title;
    root.last_context_tokens = 0;
    root.cap_new = false; // per-provider; relearn on rejection
    root.effort_rejected = false;
}

/// A normalized tool invocation — same shape for both providers.
const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    input: Value,
};

/// A tool's outcome, arena-owned, ready to wire into either format.
const ExecResult = struct {
    text: []const u8,
    is_error: bool,
    ms: i64 = 0, // wall-clock of the tool exec (external tools only; --timing)
};

const AnswerRequest = struct {
    text: []const u8,
    cancelled: bool,
    call_id: []const u8,
};

fn answerParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.AnswerNotObject => "answer must be a JSON object",
        error.AnswerWrongType => "expected answer request for ask_user",
        error.AnswerCallIdMismatch => "answer call_id did not match active ask_user prompt",
        else => "invalid answer JSON for ask_user",
    };
}

fn parseAnswerRequest(parsed: Value, expected_call_id: []const u8) !AnswerRequest {
    if (parsed != .object) return error.AnswerNotObject;
    const rtype = if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "";
    if (!std.mem.eql(u8, rtype, "answer")) return error.AnswerWrongType;
    const call_id = if (parsed.object.get("call_id")) |v| (if (v == .string) v.string else "") else "";
    if (call_id.len > 0 and expected_call_id.len > 0 and !std.mem.eql(u8, call_id, expected_call_id))
        return error.AnswerCallIdMismatch;
    const cancelled = if (parsed.object.get("cancelled")) |v| v == .bool and v.bool else false;
    const text = if (parsed.object.get("text")) |v| (if (v == .string) v.string else "") else "";
    return .{ .text = text, .cancelled = cancelled, .call_id = call_id };
}

const TodoItem = struct {
    content: []const u8,
    status: []const u8,
};

/// One agent: a message history plus the POST/tool-dispatch loop. The root
/// agent prints to stdout; subagents (sub = true) run on pool threads and
/// log through std.debug.print, which locks stderr and is thread-safe.
pub const Agent = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *std.http.Client,
    provider: Provider,
    messages: std.json.Array,
    sub: bool,
    label: []const u8,
    out: ?*Io.Writer,
    in: ?*Io.Reader = null, // stdin, root only — backs the ask_user tool
    registry: ?*mcp.Registry = null,
    approvals: ?*Approvals = null, // shared bash-approval state, set by main()
    tracer: ?*Tracer = null, // shared JSONL event trace, set by main()
    last_cache_read: u64 = 0, // KV-cache read tokens from the latest response
    sys_normal: []const u8 = main_system_prompt, // root system prompt (+ project instructions)
    sys_override: ?[]const u8 = null, // subagent-only: per-child system prompt (swarm prompt variants)
    tools_used: ToolSink = .{}, // external tool calls this agent made (per turn for the root)
    tool_calls_this_turn: u64 = 0, // root-only hard budget counter (--max-tool-calls)
    seen_tool_keys: std.ArrayList([]const u8) = .empty, // root-only per-turn dedupe keys
    md_buf: std.ArrayList(u8) = .empty, // current incomplete streamed line (markdown rendering)
    md_fence: bool = false, // inside a ``` code fence while streaming
    md_kind: MdKind = .classify, // incremental renderer: current line's classification
    md_span: MdSpan = .normal, // incremental renderer: inline **bold**/`code` span state
    md_table: std.ArrayList([]const u8) = .empty, // buffered table rows (gpa-duped), aligned+rendered when the table ends
    md_word: std.ArrayList(u8) = .empty, // prose wrap: pending word (incl. style bytes)
    md_word_vis: usize = 0, // its visible width
    md_col: usize = 0, // visible column on the current prose line
    md_indent: usize = 0, // hanging indent for wrapped continuation lines
    md_width: usize = 0, // cached termCols() for the current line (0 = unset)
    snapshots: ?*Snapshots = null, // file-edit history for /rewind (root only)
    pending_image: ?PendingImage = null, // staged by /image, sent with the next turn
    home: []const u8 = "", // $HOME, for /key persistence (set by main)
    keep_context: bool = true, // carry the conversation across wire-format model switches (/keepcontext)
    reasoning: ReasoningEffort = .medium, // reasoning/thinking depth — codex, deepseek, codegraff (/effort, /reasoning)
    fast: bool = false, // codex "fast" mode → priority service_tier (/fast)
    ultracode_mode: bool = false, // persistent ultracode (multi-agent workflow) mode (/ultracode)
    show_thinking: bool = true, // stream the model's reasoning live in the TUI (/thinking); off = spinner only
    ai_title: bool = true, // AI-generate the tab/session title from the first prompt (/title)
    goal: ?[]const u8 = null, // persistent objective steering (/goal)
    session_name: []const u8 = "last", // autosave/resume target (<name>.session.json)
    session_title: ?[]const u8 = null, // human-readable title/rename metadata
    sys_strict: []const u8 = main_system_prompt_strict,
    tools_anthropic: []const u8 = tools_anthropic_sub,
    tools_openai: []const u8 = tools_openai_sub,
    tools_responses: []const u8 = tools_responses_sub,
    todos: std.ArrayList(TodoItem) = .empty,
    eval_cmd: ?[]const u8 = null, // --eval: shell command that scores the current output (eval-driven loop)
    eval_target: u8 = 90, // --until: stop when the score reaches this (0-100)
    eval_niche: []const u8 = "", // --niche: fleet niche this eval session optimizes; tags submitted scores into a promotable (niche × tier × suite) cell
    eval_judge: ?[]const u8 = null, // --judge: LLM-as-judge rubric, min()-blended with the --eval score (runJudge). Dormant until a CLI flag sets it.
    eval_iter: u32 = 0, // eval-loop iteration counter (scores log)
    eval_best: f64 = -1, // best score seen this session (-1 = none yet)
    strict: bool = false,
    completed: ?[]const u8 = null,
    last_context_tokens: u64 = 0,
    /// Detail of the most recent API error — carried into the --json `error`
    /// event, which otherwise only knows "api error".
    last_api_error: ?[]const u8 = null,
    /// Text streamed so far in the current request — on Esc-interrupt this is
    /// what survives into history (with an "[interrupted]" marker appended).
    partial_text: std.ArrayList(u8) = .empty,
    stream_quiet: bool = false, // suppress live streaming (compaction summary)
    streamed_text: bool = false, // the last request printed its text live
    thinking_open: bool = false, // a live "Thinking" reasoning block is currently streaming (/thinking)
    thinking_rows: usize = 0, // on-screen rows the live Thinking block spans (#75 collapse)
    thinking_col: usize = 0, // running column within the block, for soft-wrap counting
    thinking_overflow: bool = false, // block scrolled past the screen -> don't erase on collapse
    thinking_folded: bool = false, // user folded the live Thinking block (#92)
    thinking_text: std.ArrayList(u8) = .empty, // buffered reasoning, so a fold can unfold (#92)
    ai_title_done: bool = false, // the one-time AI tab-title call has run this session
    arg_live: ArgLive = .{}, // live attempt_completion/ask_user argument text
    streamed_args: ArgTool = .none, // which meta tool's prose streamed live this request
    streamed_args_len: usize = 0, // raw bytes emitted for it (gates re-print suppression)
    cap_new: bool = false, // provider rejected max_tokens → use max_completion_tokens
    effort_rejected: bool = false, // model rejected reasoning_effort → drop it (e.g. gpt-5.5 on chat/completions wants /v1/responses)
    next_ask_id: u64 = 1,
    tui_header_shown: bool = false,

    fn prompt(self: *Agent) !void {
        if (json_mode) return; // SDK drives turns; no human prompt
        const w = self.out orelse return;
        const flag: []const u8 = if (self.strict and plan_mode) " strict·plan" else if (self.strict) " strict" else if (plan_mode) " plan" else "";
        var cbuf: [40]u8 = undefined;
        const cost: []const u8 = if (!show_cost) "" else blk: {
            if (std.mem.eql(u8, self.provider.id, "codex"))
                break :blk " · sub";
            if (priceFor(self.provider.model) == null) break :blk " · $?";
            break :blk std.fmt.bufPrint(&cbuf, " · ${d:.4}", .{g_cost.snap(self.io).usd}) catch "";
        };
        // Prompt-cache hit from the last response — proof caching is working.
        var kbuf: [32]u8 = undefined;
        const cached: []const u8 = if (self.last_cache_read > 0)
            (std.fmt.bufPrint(&kbuf, " · ⚡{d} cached", .{self.last_cache_read}) catch "")
        else
            "";
        if (self.last_context_tokens > 0) {
            const threshold = self.provider.compactAt();
            // % of the compaction budget already used — glanceable headroom.
            const pct = if (threshold > 0) self.last_context_tokens * 100 / threshold else 0;
            try w.print("\n{s}[{s}{s}{s}{s}{s} · cwd {s}{s}{s} · {d}/{d}k tok ({d}%){s}{s}]{s} {s}›{s} ", .{
                style.dim,   style.reset,   style.cyan,  self.provider.model,      flag,             style.dim,
                style.reset, g_cwd_display, style.dim,   self.last_context_tokens, threshold / 1000, pct,
                cached,      cost,          style.reset, style.bold,               style.reset,
            });
        } else {
            try w.print("\n{s}[{s}{s}{s}{s}{s} · cwd {s}{s}{s}{s}]{s} {s}›{s} ", .{
                style.dim,   style.reset,   style.cyan, self.provider.model, flag,        style.dim,
                style.reset, g_cwd_display, style.dim,  cost,                style.reset, style.bold,
                style.reset,
            });
        }
        try w.flush();
    }

    fn say(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
        if (self.out) |w| {
            try w.print(fmt, args);
            try w.flush();
        } else {
            std.debug.print("  [{s}] " ++ fmt, .{self.label} ++ args);
        }
    }

    /// Report an API error: remember the formatted message so the --json
    /// `error` event can carry the detail, then print it like say().
    fn sayApiError(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
        self.last_api_error = std.fmt.allocPrint(self.arena, fmt, args) catch null;
        try self.say(fmt ++ "\n", args);
    }

    /// Emit one structured JSONL event to stdout (--json mode). `ev` is any
    /// struct/anonymous struct; field names become JSON keys (a std.json.Value
    /// field, e.g. tool input, serializes correctly). Best-effort.
    fn emit(self: *Agent, ev: anytype) void {
        const w = self.out orelse return;
        // --json: the GUI stream is shared with pool-thread subagent emits
        // (guiEmit), so serialize + flush under the lock — a raw line must never
        // land mid-buffer and two writers must never interleave on stdout.
        if (json_mode) g_gui_mu.lockUncancelable(self.io);
        defer if (json_mode) g_gui_mu.unlock(self.io);
        var s: std.json.Stringify = .{ .writer = w };
        s.write(ev) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch return;
    }
    fn systemPrompt(self: *const Agent) []const u8 {
        if (self.sub) return self.sys_override orelse sub_system_prompt;
        return if (self.strict) self.sys_strict else self.sys_normal;
    }

    /// Whether the active provider honors a reasoning-effort hint: the
    /// Responses API (codex) via reasoning.effort, and the OpenAI-compatible
    /// providers we know normalize a top-level reasoning_effort — the
    /// codegraff gateway and deepseek. Everything else ignores it.
    fn effortApplies(self: *const Agent) bool {
        return providerTakesEffort(self.provider.kind, self.provider.id, self.provider.model);
    }

    fn toolsJson(self: *const Agent) []const u8 {
        return switch (self.provider.kind) {
            .anthropic => if (self.sub) tools_anthropic_sub else self.tools_anthropic,
            .openai => if (self.sub) tools_openai_sub else self.tools_openai,
            .responses => if (self.sub) tools_responses_sub else self.tools_responses,
        };
    }

    /// Run until the model stops (or, in strict mode, calls
    /// attempt_completion). Returns the final assistant text (arena-owned).
    fn runTurn(self: *Agent) anyerror![]const u8 {
        self.completed = null;
        if (!self.sub) esc_cancel.store(false, .release); // fresh turn, no stale cancel
        while (true) {
            // Esc during a tool join (set by escWatchTask) lands here: the
            // root consumes the flag and aborts before the next request;
            // subagents see it too and bail without consuming.
            if (esc_cancel.load(.acquire)) {
                if (!self.sub) esc_cancel.store(false, .release);
                return error.Interrupted;
            }
            const root = try self.request(self.toolsJson());
            const done = switch (self.provider.kind) {
                .anthropic => try self.stepAnthropic(root),
                .openai => try self.stepOpenAI(root),
                .responses => try self.stepResponses(root),
            };
            if (done) |final_text| return final_text;
        }
    }

    /// POST the current history; returns the parsed response root object
    /// (arena-owned). Reports API error envelopes and returns error.ApiError.
    /// In strict mode we force tool_choice; if a provider rejects that (e.g.
    /// the codegraff gateway with thinking on), we retry once without forcing
    /// and lean on the strict system prompt instead. Root requests stream:
    /// text deltas print live (postStream) and the buffered SSE events are
    /// reassembled into the non-streaming response shape afterwards.
    fn request(self: *Agent, tools: ?[]const u8) !std.json.ObjectMap {
        var force = self.strict and tools != null;
        var stream_usage = true; // openai stream_options; dropped if rejected
        // #95: scrub any malformed function_call_output before it hits the wire.
        sanitizeMessagesUtf8(self.arena, &self.messages); // invalid UTF-8 (any source/format) -> '?' so content never serializes as a byte-int array the API rejects
        if (self.provider.kind == .responses) normalizeResponsesHistory(self.arena, &self.messages);
        if (self.provider.kind == .openai) normalizeOpenAIHistory(self.arena, &self.messages); // #99: chat-completions sibling of the above
        while (true) {
            const live = !self.sub and self.out != null and !self.stream_quiet;
            self.streamed_text = false;
            self.streamed_args = .none;
            const body = try self.buildBody(tools, force, live, stream_usage);
            defer self.gpa.free(body);
            const t0: Io.Timestamp = .now(self.io, .awake);
            if (json_mode and !self.sub) self.emit(.{ .type = "model_call_started", .provider = self.provider.id, .model = self.provider.model });
            // HTTP calls are flaky: a kept-alive connection the server closed
            // (HttpConnectionClosing), a reset, a truncated TLS read. Retry a
            // few times with a fresh connection; on persistent failure surface
            // error.ApiError so the REPL returns to the prompt, never crashes.
            const resp_body = blk: {
                var attempt: usize = 0;
                while (true) : (attempt += 1) {
                    const attempt_body = if (live)
                        self.postStream(body)
                    else
                        postWatched(self.gpa, self.io, self.client, self.provider, body);
                    if (attempt_body) |ok| break :blk ok else |err| {
                        if (self.streamed_text) if (self.out) |w| {
                            w.writeAll("\n") catch {};
                            w.flush() catch {};
                        };
                        self.streamed_text = false;
                        self.streamed_args = .none;
                        // Esc is a deliberate stop, not a flaky network — no retry.
                        if (err == error.Interrupted) return error.Interrupted;
                        // 429/5xx: the server asked us to back off — wait
                        // (1s·2ⁿ, capped at 8s; Esc cancels) and allow a few
                        // more attempts than a plain transport flake gets.
                        const throttled = err == error.RateLimited or err == error.ServerError;
                        const max_attempts: usize = RetryPlan.maxAttempts(throttled);
                        if (attempt < max_attempts) {
                            if (throttled) {
                                const delay_ms = RetryPlan.delayMs(throttled, attempt);
                                const what: []const u8 = if (err == error.RateLimited) "rate limited (429)" else "server error (5xx)";
                                if (g_5xx_body_len > 0) {
                                    try self.say("[{s} — retrying in {d}s ({d}/{d})] {s}\n", .{ what, delay_ms / 1000, attempt + 1, max_attempts, g_5xx_body_buf[0..g_5xx_body_len] });
                                } else {
                                    try self.say("[{s} — retrying in {d}s ({d}/{d})]\n", .{ what, delay_ms / 1000, attempt + 1, max_attempts });
                                }
                                if (self.tracer) |tr| tr.note("retry", if (g_5xx_body_len > 0) g_5xx_body_buf[0..g_5xx_body_len] else what);
                                self.sleepInterruptible(delay_ms) catch return error.Interrupted;
                            } else {
                                // Transport flake (HttpConnectionClosing, a reset,
                                // a truncated TLS read): back off before a fresh
                                // connection. Rapid-fire retries against a
                                // just-closed keep-alive almost always re-fail
                                // (#86). 250ms·2ⁿ, capped at 4s over 6 tries; Esc cancels.
                                const delay_ms = RetryPlan.delayMs(throttled, attempt);
                                try self.say("[network error: {t} — retrying in {d}ms ({d}/{d})]\n", .{ err, delay_ms, attempt + 1, max_attempts });
                                self.sleepInterruptible(delay_ms) catch return error.Interrupted;
                            }
                            continue;
                        }
                        if (g_5xx_body_len > 0) {
                            try self.say("[request failed: {t} — giving up this turn] {s}\n", .{ err, g_5xx_body_buf[0..g_5xx_body_len] });
                        } else {
                            try self.say("[request failed: {t} — giving up this turn]\n", .{err});
                        }
                        // Network give-up is its own error kind: the ApiError
                        // handler's last_api_error would otherwise be an API
                        // envelope, stale or null on a pure transport failure —
                        // record the real reason so the failed turn's --json error
                        // event and trajectory node preserve it (#86).
                        self.last_api_error = std.fmt.allocPrint(self.arena, "network error: {s} (gave up after {d} attempts)", .{ @errorName(err), max_attempts }) catch null;
                        if (telemetry.g_telem) |t| t.errorEvent("net", @errorName(err));
                        if (self.tracer) |tr| tr.api(self.label, self.provider.model, 0, body.len, 0, 0, 0, true);
                        return error.ApiError;
                    }
                }
            };
            defer self.gpa.free(resp_body);
            const ms: i64 = t0.untilNow(self.io, .awake).toMilliseconds();

            // Codex Responses API: the body is an SSE stream, not one JSON
            // object — pull the final `response` out of it (or an error).
            if (self.provider.kind == .responses) {
                const r = self.parseResponses(resp_body) catch {
                    try self.say("unparseable codex response: {s}\n", .{resp_body[0..@min(resp_body.len, 600)]});
                    if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                    return error.ApiError;
                };
                switch (r) {
                    .ok => |obj| {
                        self.recordUsageResponses(obj);
                        if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                        if (json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                        return obj;
                    },
                    .err => |msg| {
                        if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                        try self.sayApiError("codex api error: {s}", .{msg});
                        return error.ApiError;
                    },
                }
            }

            // Streamed anthropic/openai bodies are SSE too: reassemble them.
            // null → the body wasn't SSE (a JSON error envelope, or a
            // provider that ignored `stream`) — fall through to the regular
            // parse, which also handles the soft-strict retry.
            if (live) {
                if (try self.assembleStream(resp_body)) |root| {
                    if (root.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "error")) {
                        const eo = if (root.get("error")) |ev| (if (ev == .object) ev.object else null) else null;
                        const etype = if (eo) |e| (if (e.get("type")) |tv| (if (tv == .string) tv.string else "error") else "error") else "error";
                        const emsg = if (eo) |e| (if (e.get("message")) |mv| (if (mv == .string) mv.string else "") else "") else "";
                        if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                        try self.sayApiError("api error ({s}): {s}", .{ etype, emsg });
                        return error.ApiError;
                    };
                    self.recordUsage(root);
                    if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                    if (json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                    return root;
                }
            }

            const resp = std.json.parseFromSliceLeaky(Value, self.arena, resp_body, .{
                .allocate = .alloc_always,
            }) catch {
                try self.sayApiError("unparseable response: {s}", .{resp_body[0..@min(resp_body.len, 400)]});
                return error.ApiError;
            };
            const root = resp.object;

            if (root.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "error")) {
                const eo = if (root.get("error")) |ev| (if (ev == .object) ev.object else null) else null;
                const etype = if (eo) |e| (if (e.get("type")) |tv| (if (tv == .string) tv.string else "error") else "error") else "error";
                const emsg = if (eo) |e| (if (e.get("message")) |mv| (if (mv == .string) mv.string else "") else "") else "";
                if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                try self.sayApiError("api error ({s}): {s}", .{ etype, emsg });
                return error.ApiError;
            };
            if (apiErrorMessage(root)) |msg| {
                if (force and std.mem.indexOf(u8, msg, "tool_choice") != null) {
                    force = false; // provider can't force a tool; soft-strict
                    continue;
                }
                if (stream_usage and std.mem.indexOf(u8, msg, "stream_options") != null) {
                    stream_usage = false; // provider can't report streamed usage
                    continue;
                }
                if (!self.cap_new and std.mem.indexOf(u8, msg, "max_completion_tokens") != null) {
                    self.cap_new = true; // provider wants the post-deprecation name
                    continue;
                }
                if (!self.effort_rejected and mentionsReasoningEffort(msg)) {
                    self.effort_rejected = true; // model rejects the effort hint here; drop + retry
                    continue;
                }
                if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                try self.sayApiError("api error: {s}", .{msg});
                return error.ApiError;
            }

            self.recordUsage(root);
            if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
            if (json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
            return root;
        }
    }

    fn recordUsage(self: *Agent, root: std.json.ObjectMap) void {
        const usage = root.get("usage") orelse return;
        if (usage != .object) return;
        const u = usage.object;
        self.last_cache_read = 0;
        switch (self.provider.kind) {
            .anthropic => {
                var total: i64 = 0;
                const fields = [_][]const u8{
                    "input_tokens",            "output_tokens",
                    "cache_read_input_tokens", "cache_creation_input_tokens",
                };
                for (fields) |f| total += usageInt(u, f);
                if (total > 0) self.last_context_tokens = @intCast(total);
                const cache = usageInt(u, "cache_read_input_tokens");
                if (cache > 0) self.last_cache_read = @intCast(cache);
                // cache writes bill ~like input; fold them into uncached input.
                self.recordCost(usageInt(u, "input_tokens") + usageInt(u, "cache_creation_input_tokens"), cache, usageInt(u, "output_tokens"));
            },
            .openai => {
                if (usageInt(u, "total_tokens") > 0) self.last_context_tokens = @intCast(usageInt(u, "total_tokens"));
                // deepseek reports prompt_cache_hit_tokens; the OpenAI shape
                // nests cached_tokens under prompt_tokens_details.
                var cache = usageInt(u, "prompt_cache_hit_tokens");
                if (cache == 0) if (u.get("prompt_tokens_details")) |d| if (d == .object) {
                    cache = usageInt(d.object, "cached_tokens");
                };
                if (cache > 0) self.last_cache_read = @intCast(cache);
                self.recordCost(usageInt(u, "prompt_tokens") - cache, cache, usageInt(u, "completion_tokens"));
            },
            // codex uses recordUsageResponses on its own path.
            .responses => {},
        }
    }

    /// An integer usage field, or 0 if absent / wrong type.
    fn usageInt(obj: std.json.ObjectMap, name: []const u8) i64 {
        if (obj.get(name)) |v| if (v == .integer) return v.integer;
        return 0;
    }

    /// Record one request's usage into the session-wide tally (g_cost):
    /// token counts always; USD only for API-key providers with a
    /// price_table row. Subscription providers (codex, claude) bill flat
    /// and tally as sub_calls; unpriced models as unpriced_calls.
    fn recordCost(self: *Agent, uncached_in: i64, cache_in: i64, out: i64) void {
        g_cost.add(self.io, self.provider.id, self.provider.model, uncached_in, cache_in, out);
    }

    const ResponsesResult = union(enum) { ok: std.json.ObjectMap, err: []const u8 };

    /// Pull the final `response` object out of a Codex SSE stream. Scans
    /// `data:` lines for the last `response.completed`/`response.incomplete`
    /// event; reports `response.failed`/`error` events or a plain JSON error
    /// body as an error.
    fn parseResponses(self: *Agent, body: []const u8) !ResponsesResult {
        // The final output items arrive as individual `response.output_item.done`
        // events; `response.completed` carries usage but an empty output array.
        // Collect the done-items and synthesize a {output, usage} object.
        var items = std.json.Array.init(self.arena);
        var usage: ?Value = null;
        var saw_completed = false;
        var err_msg: ?[]const u8 = null;
        var it = std.mem.tokenizeScalar(u8, body, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r");
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            const payload = std.mem.trim(u8, line["data:".len..], " ");
            if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
            const v = std.json.parseFromSliceLeaky(Value, self.arena, payload, .{ .allocate = .alloc_always }) catch continue;
            if (v != .object) continue;
            const t = v.object.get("type") orelse continue;
            if (t != .string) continue;
            if (std.mem.eql(u8, t.string, "response.output_item.done")) {
                if (v.object.get("item")) |item| try items.append(item);
            } else if (std.mem.eql(u8, t.string, "response.completed") or std.mem.eql(u8, t.string, "response.incomplete")) {
                saw_completed = true;
                if (v.object.get("response")) |r| if (r == .object) {
                    if (r.object.get("usage")) |u| usage = u;
                };
            } else if (std.mem.eql(u8, t.string, "response.failed") or std.mem.eql(u8, t.string, "error")) {
                err_msg = errorMessage(v.object) orelse "codex stream reported a failure";
            }
        }
        if (saw_completed or items.items.len > 0) {
            var resp: std.json.ObjectMap = .empty;
            try resp.put(self.arena, "output", .{ .array = items });
            if (usage) |u| try resp.put(self.arena, "usage", u);
            return .{ .ok = resp };
        }
        if (err_msg) |m| return .{ .err = m };
        // Not an SSE stream — maybe a JSON error body (401, rate limit, …).
        const v = std.json.parseFromSliceLeaky(Value, self.arena, body, .{ .allocate = .alloc_always }) catch return error.Unparseable;
        if (v == .object) if (errorMessage(v.object)) |m| return .{ .err = m };
        return error.Unparseable;
    }

    fn errorMessage(obj: std.json.ObjectMap) ?[]const u8 {
        if (obj.get("error")) |e| {
            if (e == .object) {
                if (e.object.get("message")) |m| if (m == .string) return m.string;
            } else if (e == .string) return e.string;
        }
        if (obj.get("response")) |r| if (r == .object) {
            if (r.object.get("error")) |e| if (e == .object) {
                if (e.object.get("message")) |m| if (m == .string) return m.string;
            };
        };
        if (obj.get("detail")) |d| if (d == .string) return d.string;
        if (obj.get("message")) |m| if (m == .string) return m.string;
        return null;
    }

    fn recordUsageResponses(self: *Agent, response: std.json.ObjectMap) void {
        self.last_cache_read = 0;
        const usage = response.get("usage") orelse return;
        if (usage != .object) return;
        const u = usage.object;
        const in_tokens = usageInt(u, "input_tokens");
        const out_tokens = usageInt(u, "output_tokens");
        const total_tokens = usageInt(u, "total_tokens");
        if (total_tokens > 0) {
            self.last_context_tokens = @intCast(total_tokens);
        } else {
            // Some Codex/Responses builds report only input/output counts.
            // Still surface the prompt token counter instead of leaving the
            // prompt stuck at "model · sub" with no context usage.
            const computed_total = in_tokens + out_tokens;
            if (computed_total > 0) self.last_context_tokens = @intCast(computed_total);
        }
        var cached: i64 = 0;
        if (u.get("input_tokens_details")) |d| if (d == .object) {
            cached = usageInt(d.object, "cached_tokens");
            if (cached > 0) self.last_cache_read = @intCast(cached);
        };
        self.recordCost(in_tokens - cached, cached, out_tokens);
    }

    /// Consume a Codex `response` object: append its output items to history
    /// (verbatim — they're valid Responses input items), surface text, and
    /// collect any function calls. Returns final text when no tools were
    /// called, else null to loop after running them.
    fn stepResponses(self: *Agent, response: std.json.ObjectMap) !?[]const u8 {
        const output = response.get("output") orelse return error.ApiError;
        if (output != .array) return error.ApiError;

        var calls: std.ArrayList(ToolCall) = .empty;
        defer calls.deinit(self.gpa);
        var final_text: []const u8 = "";

        for (output.array.items) |item| {
            if (item != .object) continue;
            try self.messages.append(item); // valid as next-turn input
            const itype = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
            if (std.mem.eql(u8, itype, "message")) {
                if (item.object.get("content")) |c| if (c == .array) {
                    for (c.array.items) |block| {
                        if (block != .object) continue;
                        const bt = if (block.object.get("type")) |x| (if (x == .string) x.string else "") else "";
                        if (std.mem.eql(u8, bt, "output_text")) {
                            if (block.object.get("text")) |txt| if (txt == .string) {
                                final_text = txt.string;
                                if (!self.sub and !self.streamed_text) try self.say("{s}\n", .{txt.string});
                            };
                        }
                    }
                };
            } else if (std.mem.eql(u8, itype, "function_call")) {
                const name = if (item.object.get("name")) |n| (if (n == .string) n.string else continue) else continue;
                const call_id = if (item.object.get("call_id")) |c| (if (c == .string) c.string else continue) else continue;
                const args = if (item.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
                const input: Value = if (args.len == 0)
                    .{ .object = .empty }
                else
                    std.json.parseFromSliceLeaky(Value, self.arena, args, .{ .allocate = .alloc_always }) catch .{ .object = .empty };
                try calls.append(self.gpa, .{ .id = call_id, .name = name, .input = input });
            }
        }

        if (calls.items.len > 0) {
            const results = try self.runTools(calls.items);
            for (calls.items, results) |call, r| {
                const fco = try toolResultMessage(self.arena, .responses, call.id, r.text, r.is_error);
                try self.messages.append(fco);
            }
            if (self.completed) |result| return result;
            return null;
        }
        return final_text;
    }

    fn stepAnthropic(self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
        const content = root.get("content") orelse {
            try self.say("[api error: response had no content]\n", .{});
            return error.ApiError;
        };
        if (content != .array) {
            try self.say("[api error: malformed content block]\n", .{});
            return error.ApiError;
        }
        const stop_reason = if (root.get("stop_reason")) |s| (if (s == .string) s.string else "") else "";

        var assistant: std.json.ObjectMap = .empty;
        try assistant.put(self.arena, "role", .{ .string = "assistant" });
        try assistant.put(self.arena, "content", content);
        try self.messages.append(.{ .object = assistant });

        var calls: std.ArrayList(ToolCall) = .empty;
        defer calls.deinit(self.gpa);
        var final_text: []const u8 = "";
        for (content.array.items) |block| {
            if (block != .object) continue;
            const kind = if (block.object.get("type")) |t| (if (t == .string) t.string else "") else "";
            if (std.mem.eql(u8, kind, "text")) {
                if (block.object.get("text")) |tx| if (tx == .string) {
                    final_text = tx.string;
                    if (!self.sub and !self.streamed_text) try self.say("{s}\n", .{final_text});
                };
            } else if (std.mem.eql(u8, kind, "tool_use")) {
                const name = if (block.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                if (name.len == 0) continue;
                const id = if (block.object.get("id")) |x| (if (x == .string) x.string else "") else "";
                const input = block.object.get("input") orelse Value{ .object = .empty };
                try calls.append(self.gpa, .{ .id = id, .name = name, .input = input });
            }
        }

        if (calls.items.len > 0) {
            const results = try self.runTools(calls.items);
            var blocks = std.json.Array.init(self.arena);
            for (calls.items, results) |call, r| {
                const tr = try toolResultMessage(self.arena, .anthropic, call.id, r.text, r.is_error);
                try blocks.append(tr);
            }
            var user_msg: std.json.ObjectMap = .empty;
            try user_msg.put(self.arena, "role", .{ .string = "user" });
            try user_msg.put(self.arena, "content", .{ .array = blocks });
            try self.messages.append(.{ .object = user_msg });

            if (self.completed) |result| return result;
            return null; // loop again
        }

        if (std.mem.eql(u8, stop_reason, "pause_turn")) return null;
        if (!std.mem.eql(u8, stop_reason, "end_turn")) try self.say("[stopped: {s}]\n", .{stop_reason});
        return final_text;
    }

    fn stepOpenAI(self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
        const choices = root.get("choices");
        if (choices == null or choices.? != .array or choices.?.array.items.len == 0 or choices.?.array.items[0] != .object) {
            try self.say("[api error: response had no choices]\n", .{});
            return error.ApiError;
        }
        const choice = choices.?.array.items[0].object;
        const message = choice.get("message") orelse {
            try self.say("[api error: choice had no message]\n", .{});
            return error.ApiError;
        };
        try self.messages.append(message); // echo verbatim (content may be null)

        var final_text: []const u8 = "";
        if (message.object.get("content")) |c| if (c == .string and c.string.len > 0) {
            final_text = c.string;
            if (!self.sub and !self.streamed_text) try self.say("{s}\n", .{c.string});
        };

        var calls: std.ArrayList(ToolCall) = .empty;
        defer calls.deinit(self.gpa);
        if (message.object.get("tool_calls")) |tcs| if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                const function = tc.object.get("function") orelse continue;
                if (function != .object) continue;
                const args_str = if (function.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
                const input: Value = if (args_str.len == 0)
                    .{ .object = .empty }
                else
                    (std.json.parseFromSliceLeaky(Value, self.arena, args_str, .{ .allocate = .alloc_always }) catch .{ .object = .empty });
                const name = if (function.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                if (name.len == 0) continue; // can't dispatch a nameless call
                const id = if (tc.object.get("id")) |x| (if (x == .string) x.string else "") else "";
                try calls.append(self.gpa, .{ .id = id, .name = name, .input = input });
            }
        };

        if (calls.items.len > 0) {
            const results = try self.runTools(calls.items);
            for (calls.items, results) |call, r| {
                const tool_msg = try toolResultMessage(self.arena, .openai, call.id, r.text, r.is_error);
                try self.messages.append(tool_msg);
            }
            if (self.completed) |result| return result;
            return null;
        }

        const finish = choice.get("finish_reason").?;
        if (finish == .string and !std.mem.eql(u8, finish.string, "stop")) try self.say("[stopped: {s}]\n", .{finish.string});
        return final_text;
    }

    /// Run a batch of tool calls. Meta tools are handled inline (they mutate
    /// agent state); everything else fans out across the Io thread pool.
    /// Bash calls must clear the permission gate before dispatch. Results
    /// are returned in call order, arena-owned.
    fn runTools(self: *Agent, calls: []const ToolCall) ![]ExecResult {
        const results = try self.arena.alloc(ExecResult, calls.len);

        // Collect the indices of external (non-meta) calls for parallel exec.
        var ext_idx: std.ArrayList(usize) = .empty;
        defer ext_idx.deinit(self.gpa);
        for (calls, 0..) |call, i| {
            if (try self.rejectToolCall(call)) |denied| {
                results[i] = denied;
                continue;
            }
            try self.sayToolUse(call);
            if (isMetaName(call.name)) {
                results[i] = try self.handleMeta(call);
            } else if (try self.gateTool(call)) |denied| {
                results[i] = denied;
            } else {
                try ext_idx.append(self.gpa, i);
            }
        }

        if (ext_idx.items.len > 0) {
            if (ext_idx.items.len > 1 and !self.sub) {
                try self.say("  {s}↯ running {d} tools in parallel{s}\n", .{ style.dim, ext_idx.items.len, style.reset });
            }
            const ctx: ToolCtx = .{
                .gpa = self.gpa,
                .io = self.io,
                .client = self.client,
                .provider = self.provider,
                .registry = if (self.sub) null else self.registry,
                .from_sub = self.sub,
                .approvals = self.approvals,
                .tracer = self.tracer,
                .snapshots = self.snapshots,
                .tools_used = &self.tools_used,
            };
            // Esc while tools run: spawn a stdin watcher for the duration of
            // the join (see esc_cancel). Subagents notice the flag mid-flight;
            // the root aborts the turn at its next runTurn iteration.
            const esc_watch = !self.sub and self.in != null and use_color and !json_mode;
            var esc_tio: ?tty.RawState = null;
            var esc_fut: ?Io.Future(void) = null;
            if (esc_watch) if (rawNonblockStdin()) |tio| {
                esc_tio = tio;
                esc_watch_done.store(false, .release);
                esc_fut = self.io.async(escWatchTask, .{});
            };
            defer if (esc_tio) |tio| {
                esc_watch_done.store(true, .release);
                if (esc_fut) |*f| f.await(self.io);
                drainStdin();
                tty.restore(tio);
            };
            // Join ALL futures before any fallible work: an early error
            // return would otherwise free the futures while pool tasks are
            // still writing into them (and abandon running tools).
            const futures = try self.gpa.alloc(Io.Future(ToolOutput), ext_idx.items.len);
            defer self.gpa.free(futures);
            const outputs = try self.gpa.alloc(ToolOutput, ext_idx.items.len);
            defer self.gpa.free(outputs);
            for (ext_idx.items, futures) |i, *fut| fut.* = self.io.async(execTool, .{ ctx, calls[i] });
            for (futures, outputs) |*fut, *output| output.* = fut.await(self.io);
            defer for (outputs) |output| self.gpa.free(output.text);
            for (ext_idx.items, outputs) |i, output| {
                results[i] = .{ .text = try self.arena.dupe(u8, output.text), .is_error = output.is_error, .ms = output.ms };
            }
        }
        // Show a compact ✓/✗ + preview for each non-meta call (no-op for subs).
        for (calls, results) |call, r| self.sayToolResult(call.name, r);
        return results;
    }

    fn rejectToolCall(self: *Agent, call: ToolCall) !?ExecResult {
        if (self.sub) return null;
        if (std.mem.eql(u8, call.name, "attempt_completion")) return null;
        if (max_tool_calls) |max| {
            if (self.tool_calls_this_turn >= max) {
                const message = try std.fmt.allocPrint(self.arena, "tool call budget exhausted ({d}/{d}) — answer with what you have or ask for a higher --max-tool-calls", .{ self.tool_calls_this_turn, max });
                self.emitToolRejected(call, "budget", message);
                return .{ .text = message, .is_error = true };
            }
        }
        if (dedupe_tool_calls) {
            const key = try self.toolDedupeKey(call);
            for (self.seen_tool_keys.items) |seen| {
                if (std.mem.eql(u8, seen, key)) {
                    const message = try std.fmt.allocPrint(self.arena, "duplicate tool call rejected: {s} with the same normalized input already ran this turn", .{call.name});
                    self.emitToolRejected(call, "duplicate", message);
                    return .{ .text = message, .is_error = true };
                }
            }
            try self.seen_tool_keys.append(self.arena, key);
        }
        self.tool_calls_this_turn += 1;
        return null;
    }

    fn toolDedupeKey(self: *Agent, call: ToolCall) ![]const u8 {
        var aw: Io.Writer.Allocating = .init(self.arena);
        const w = &aw.writer;
        try w.writeAll(call.name);
        try w.writeByte('\n');
        var s: std.json.Stringify = .{ .writer = w };
        try s.write(call.input);
        const key = aw.writer.buffered();
        for (key) |*c| {
            c.* = if (std.ascii.isWhitespace(c.*)) ' ' else std.ascii.toLower(c.*);
        }
        return key;
    }

    fn emitToolRejected(self: *Agent, call: ToolCall, reason: []const u8, message: []const u8) void {
        if (!json_mode) return;
        self.emit(.{ .type = "tool_rejected", .name = call.name, .reason = reason, .input = call.input, .message = message });
    }

    /// The permission gate, root side: an unapproved bash command prompts
    /// the user — yes once, always (approve the command's first word for
    /// the rest of the session), or no. Returns the denial result, or null
    /// when cleared to execute. Subagents never prompt; their gate is the
    /// allowlist check in execToolInner.
    fn gateTool(self: *Agent, call: ToolCall) !?ExecResult {
        if (self.sub) {
            // Destructive git is blocked for subagents outright — they have no
            // human to confirm with. The root agent falls through to a y/n
            // prompt below. Completes the Codex-style `.git` guard across both.
            if (std.mem.eql(u8, call.name, "bash") and call.input == .object) {
                if (call.input.object.get("command")) |cv| if (cv == .string and Approvals.isDestructiveGit(cv.string)) return .{
                    .text = try self.arena.dupe(u8, "destructive git is blocked for subagents (no one to confirm) — leave reset --hard / clean -f / force-push / branch -D to the root session"),
                    .is_error = true,
                };
            }
            return null; // subagents: otherwise gated structurally, not by prompt
        }
        const approvals = self.approvals orelse return null;

        // Plan mode: read-only, regardless of approvals — deny mutating tools
        // up front (no point prompting for something the mode forbids).
        if (plan_mode) {
            if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or
                (mcp.Registry.isMcp(call.name) and !companionReadOnly(call.name, call.input))) return .{
                .text = try self.arena.dupe(u8, "plan mode is on — read-only. Fold this change into the plan you present; the user applies it after approving (/plan toggles the mode off)."),
                .is_error = true,
            };
            if (std.mem.eql(u8, call.name, "bash")) {
                const cmd_val = call.input.object.get("command") orelse return null;
                if (cmd_val != .string) return null;
                const cmd = std.mem.trim(u8, cmd_val.string, " \t");
                if (!Approvals.readOnlyAllowed(cmd)) return .{
                    .text = try self.arena.dupe(u8, "plan mode is on — only read-only commands run (ls/cat/grep/git status…). Put this command in the plan instead."),
                    .is_error = true,
                };
                return null;
            }
        }

        // Decide whether this call needs approval, and what the approval key
        // and prompt line are. bash keys on the command's first word; writes
        // and MCP tools key on the tool name.
        var key: []const u8 = undefined;
        var line_buf: [256]u8 = undefined;
        var prompt_line: []const u8 = undefined;

        if (std.mem.eql(u8, call.name, "bash")) {
            const cmd_val = call.input.object.get("command") orelse return null;
            if (cmd_val != .string) return null;
            const cmd = std.mem.trim(u8, cmd_val.string, " \t");
            // Destructive git (reset --hard, clean -f, branch -D, force-push…)
            // stays gated in normal mode + for subagents, but DOES run under --yolo
            // so the agent can't wipe the user's work or a worktree's checkpoints.
            // It falls through to a human y/n (or a deny in non-interactive runs).
            const destructive_git = Approvals.isDestructiveGit(cmd);
            const gate_ok = !destructive_git or Approvals.destructiveGitAllowed(approvals.yolo, self.sub);
            if (gate_ok and approvals.allowed(self.io, cmd)) return null;
            key = firstWord(cmd);
            prompt_line = if (destructive_git)
                std.fmt.bufPrint(&line_buf, "DESTRUCTIVE git — run: {s}", .{cmd}) catch cmd
            else
                std.fmt.bufPrint(&line_buf, "run: {s}", .{cmd}) catch cmd;
        } else if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file")) {
            if (approvals.allowedExact(self.io, call.name)) return null;
            key = call.name;
            const path = if (call.input == .object)
                (if (call.input.object.get("path")) |p| (if (p == .string) p.string else "?") else "?")
            else
                "?";
            prompt_line = std.fmt.bufPrint(&line_buf, "{s} {s}", .{ call.name, path }) catch call.name;
        } else if (mcp.Registry.isMcp(call.name)) {
            if (companionTrusted(call.name)) return null; // the whole suite: like native tools
            if (approvals.allowedExact(self.io, call.name)) return null;
            key = call.name;
            prompt_line = std.fmt.bufPrint(&line_buf, "call MCP tool {s}", .{call.name}) catch call.name;
        } else {
            return null; // read_file, subagent, workflow, meta: not gated
        }

        // No human to ask (one-shot -p, or stdin gone): deny instead of
        // hanging. Pre-approve in .harness/settings.json or pass --yolo.
        const in = self.in orelse return .{
            .text = try self.arena.dupe(u8, "not pre-approved, and no interactive user to ask in one-shot mode — pre-approve it in .harness/settings.json, or run with --yolo"),
            .is_error = true,
        };
        const w = self.out orelse return .{
            .text = try self.arena.dupe(u8, "not pre-approved, and no interactive user to ask — pre-approve it in .harness/settings.json, or run with --yolo"),
            .is_error = true,
        };

        try w.print("  ⚠ {s}\n  [y]es once · [a]lways allow \"{s}\" (saved to {s}) · [n]o › ", .{ prompt_line, key, Approvals.settings_path });
        try w.flush();
        const raw: []const u8 = (try in.takeDelimiter('\n')) orelse "";
        const answer = std.mem.trim(u8, raw, " \t\r");
        if (answer.len > 0) switch (answer[0]) {
            'y', 'Y' => return null,
            'a', 'A' => {
                try approvals.approve(self.io, self.gpa, key);
                if (std.mem.eql(u8, call.name, "bash") and Approvals.isInterpreter(key)) {
                    try w.print("  note: \"{s}\" can execute arbitrary code (e.g. {s} -c '…'); approving it is effectively unrestricted.\n", .{ key, key });
                    try w.flush();
                }
                return null;
            },
            else => {},
        };
        return .{
            .text = try self.arena.dupe(u8, "user declined this tool call — try another approach or ask them how to proceed"),
            .is_error = true,
        };
    }

    fn firstWord(cmd: []const u8) []const u8 {
        const end = std.mem.indexOfAny(u8, cmd, " \t") orelse cmd.len;
        return cmd[0..end];
    }

    /// Handle a meta tool inline on the agent's own thread.
    fn handleMeta(self: *Agent, call: ToolCall) !ExecResult {
        if (std.mem.eql(u8, call.name, "attempt_completion")) {
            const result = if (call.input.object.get("result")) |r| r.string else "";
            self.completed = try self.arena.dupe(u8, result);
            // Skip the re-print only when the result streamed live in full.
            if (!self.sub and !self.argStreamedFully(call)) try self.say("{s}\n", .{result});
            return .{ .text = "completion recorded", .is_error = false };
        }
        if (std.mem.eql(u8, call.name, "eval")) {
            const note = if (call.input.object.get("note")) |n| (if (n == .string) n.string else "") else "";
            return self.runEval(note);
        }
        if (std.mem.eql(u8, call.name, "todo_write")) {
            self.todos.clearRetainingCapacity();
            if (call.input.object.get("todos")) |list| if (list == .array) {
                for (list.array.items) |item| {
                    if (item != .object) continue;
                    const content = item.object.get("content") orelse continue;
                    if (content != .string) continue;
                    const status = if (item.object.get("status")) |st| (if (st == .string) st.string else "pending") else "pending";
                    try self.todos.append(self.arena, .{
                        .content = try self.arena.dupe(u8, content.string),
                        .status = try self.arena.dupe(u8, status),
                    });
                }
            };
            const rendered = self.renderTodos();
            if (!self.sub) try self.say("{s}\n", .{rendered});
            return .{ .text = rendered, .is_error = false };
        }
        if (std.mem.eql(u8, call.name, "ask_user")) return self.askUser(call);
        // todo_read
        return .{ .text = self.renderTodos(), .is_error = false };
    }

    /// The "user message as a tool" half of the loop: the agent calls
    /// ask_user, we block for a typed reply, and hand it back as the tool
    /// result. Only the root agent has stdin; subagents must self-decide.
    fn askUser(self: *Agent, call: ToolCall) !ExecResult {
        const in = self.in orelse return .{
            .text = "no human is attached — make a reasonable assumption and continue",
            .is_error = true,
        };
        const w = self.out.?;
        const question = if (call.input.object.get("question")) |q| q.string else "(no question)";
        if (json_mode) {
            const call_id = if (call.id.len > 0) call.id else blk: {
                const id = try std.fmt.allocPrint(self.arena, "ask_user-{d}", .{self.next_ask_id});
                self.next_ask_id += 1;
                break :blk id;
            };
            try self.emitAskUser(call_id, question, call.input);
            const raw = (try in.takeDelimiter('\n')) orelse return .{
                .text = "user ended input without answering",
                .is_error = true,
            };
            const parsed = std.json.parseFromSliceLeaky(Value, self.arena, std.mem.trim(u8, raw, " \t\r"), .{ .allocate = .alloc_always }) catch return .{
                .text = "invalid answer JSON for ask_user",
                .is_error = true,
            };
            const answer = parseAnswerRequest(parsed, call_id) catch |err| return .{
                .text = answerParseError(err),
                .is_error = true,
            };
            if (answer.cancelled) return .{ .text = "user cancelled the follow-up", .is_error = true };
            return .{ .text = try self.arena.dupe(u8, answer.text), .is_error = false };
        }
        // Skip the re-print only when the question streamed live in full.
        if (!self.argStreamedFully(call)) try w.print("\n❓ {s}\n", .{question});
        if (call.input.object.get("options")) |opts| if (opts == .array) {
            for (opts.array.items, 1..) |opt, n| try w.print("   {d}) {s}\n", .{ n, opt.string });
        };
        try w.writeAll("   your answer › ");
        try w.flush();

        const raw = (try in.takeDelimiter('\n')) orelse return .{
            .text = "user ended input without answering",
            .is_error = true,
        };
        const answer = std.mem.trim(u8, raw, " \t\r");
        return .{ .text = try self.arena.dupe(u8, answer), .is_error = false };
    }

    fn emitAskUser(self: *Agent, call_id: []const u8, question: []const u8, input: Value) !void {
        const w = self.out orelse return;
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("type");
        try s.write("ask_user");
        try s.objectField("call_id");
        try s.write(call_id);
        try s.objectField("question");
        try s.write(question);
        try s.objectField("input");
        try s.write(input);
        try s.endObject();
        try w.writeByte('\n');
        try w.flush();
    }

    fn renderTodos(self: *Agent) []const u8 {
        if (self.todos.items.len == 0) return "(no todos)";
        var aw: Io.Writer.Allocating = .init(self.arena);
        const w = &aw.writer;
        for (self.todos.items) |t| {
            const mark = if (std.mem.eql(u8, t.status, "completed"))
                "[x]"
            else if (std.mem.eql(u8, t.status, "in_progress"))
                "[~]"
            else
                "[ ]";
            w.print("{s} {s}\n", .{ mark, t.content }) catch break;
        }
        return std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
    }

    /// Run the configured --eval scoring command, append the result to the
    /// scores log (.graff/eval-log.tsv), and return a verdict for the model:
    /// score (0-100), best so far, target, and whether the target is met. The
    /// harness runs the command, so the model cannot fake the number. (eval tool)
    fn runEval(self: *Agent, note: []const u8) !ExecResult {
        const cmd = self.eval_cmd orelse return .{
            .text = "no eval command configured - relaunch graff with --eval <scoring cmd> and --until <N>, or ask the user to set one",
            .is_error = true,
        };
        const run = runCapped(self.gpa, self.io, &.{ "/bin/sh", "-c", cmd }, 64 * 1024, 16 * 1024, 0) catch |e|
            return .{ .text = try std.fmt.allocPrint(self.arena, "eval command could not run: {t}", .{e}), .is_error = true };
        defer self.gpa.free(run.stdout);
        defer self.gpa.free(run.stderr);
        self.eval_iter += 1;
        const exit_code: i32 = switch (run.term) {
            .exited => |c| @intCast(c),
            else => -1,
        };
        const det = parseEvalScore(run.stdout) orelse parseEvalScore(run.stderr);

        // LLM-as-judge (--judge): an independent subagent inspects the actual
        // artifacts against the rubric and returns its own 0-100 score. Both
        // scores must clear the target, so the binding value is their min().
        // Skip the judge when the deterministic command itself produced no
        // score - fix that first rather than burn a judge run.
        const judge: ?f64 = if (self.eval_judge != null and det != null) self.runJudge(self.eval_judge.?, run.stdout, note) else null;
        const combined: ?f64 = if (self.eval_judge == null)
            det
        else if (det != null and judge != null)
            @min(det.?, judge.?)
        else
            null;

        const target_f: f64 = @floatFromInt(self.eval_target);
        const improved = if (combined) |s| (self.eval_best < 0 or s > self.eval_best) else false;
        if (combined) |s| {
            if (self.eval_best < 0 or s > self.eval_best) self.eval_best = s;
        }
        const met = if (combined) |s| s >= target_f else false;
        self.appendEvalLog(note, det, judge, combined, exit_code, met) catch {};

        // Feed the eval-driven score into the fleet (docs/hyperagents.md §9.B):
        // on a NEW BEST, submit the genome (this agent's persona) with its achieved
        // score on the pinned eval set (the eval command's fingerprint). Without this
        // the score only ever reached .graff/eval-log.tsv and the DGM/fleet never saw
        // real eval-driven work — only darwincode/JSON-proto runs ever submitted.
        if (combined) |s| {
            if (improved and s > 0) { // s>0: skip the initial-state / total-failure 0 (don't pollute the cell mean)
                if (telemetry.g_telem) |t| {
                    const sys = self.systemPrompt();
                    const genome_fp = promptFingerprint(sys);
                    const esh_fp = promptFingerprint(cmd);
                    const genome: []const u8 = &genome_fp;
                    const esh: []const u8 = &esh_fp;
                    const run_id: []const u8 = &scoring.g_run_id;
                    const pclass = providerClass(self.provider.model);
                    // --niche tags this score's cell. Without it the score lands in the
                    // anonymous "" niche, which pullElites can never match to a builtin —
                    // so an eval session that wants to grow a champion must name its role.
                    const niche = self.eval_niche;
                    // Genome-send (graff-dgm.md §B): the eval genome is this agent's own
                    // persona, never spawned via runSub, so its prompt_text never reached
                    // the worker. A cell only promotes when harness_scores joins to a
                    // harness_genomes row, so ride the genome text over on a `propose`
                    // (deduped by prompt_sha) before the score — else a winning eval cell
                    // has nothing to serve. Gated on a niche: a "" cell is unpromotable.
                    if (niche.len > 0) t.fleetEvent("propose", niche, genome, "", pclass, "", 0, sys);
                    const sig = signScore(genome, "", s, run_id, "", "", esh);
                    const sig_s: []const u8 = if (scoring.g_score_key != null) &sig else "";
                    var provbuf: [512]u8 = undefined;
                    const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ "", "", esh, pclass, niche }) catch "";
                    t.scoreEvent(genome, "", s, run_id, sig_s, prov);
                    t.fleetEvent("submit", niche, genome, "", pclass, esh, 0, "");
                }
            }
        }

        var aw: Io.Writer.Allocating = .init(self.arena);
        const w = &aw.writer;
        if (combined) |s| {
            if (self.eval_judge != null) {
                try w.print("eval #{d}: deterministic {d:.1} + judge {d:.1} -> {d:.1}/100 (best {d:.1}, target {d}). ", .{ self.eval_iter, det.?, judge.?, s, self.eval_best, self.eval_target });
            } else {
                try w.print("eval #{d}: score {d:.1}/100 (best {d:.1}, target {d}). ", .{ self.eval_iter, s, self.eval_best, self.eval_target });
            }
            if (met)
                try w.writeAll("TARGET MET - finish and report the final scores.")
            else if (improved)
                try w.writeAll("Improved - keep going: fix the next biggest failure with one focused change.")
            else
                try w.writeAll("No gain over the best - try a different change; do not build on a regression.");
        } else if (self.eval_judge != null and det != null and judge == null) {
            try w.print("eval #{d}: deterministic score {d:.1}/100, but the judge returned no parseable score (it may have errored). Re-run after checking the rubric. ", .{ self.eval_iter, det.? });
        } else {
            try w.print("eval #{d}: command ran but no score parsed - print a bare number, or JSON with a score field (0-100 or 0-1), on the last line. ", .{self.eval_iter});
        }
        const tail = if (run.stdout.len > 1500) run.stdout[run.stdout.len - 1500 ..] else run.stdout;
        try w.print("\n[exit {d}] eval output (tail):\n{s}", .{ exit_code, tail });
        return .{ .text = try self.arena.dupe(u8, aw.writer.buffered()), .is_error = false };
    }

    /// Append one tab-separated row to the scores log (.graff/eval-log.tsv).
    /// Best-effort - a failed write never breaks the loop.
    fn appendEvalLog(self: *Agent, note: []const u8, det: ?f64, judge: ?f64, score: ?f64, exit_code: i32, met: bool) !void {
        Io.Dir.cwd().createDir(self.io, ".graff", .default_dir) catch {};
        const path = ".graff/eval-log.tsv";
        const existing = Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(2 * 1024 * 1024)) catch "";
        var aw: Io.Writer.Allocating = .init(self.arena);
        const w = &aw.writer;
        try w.writeAll(existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') try w.writeByte('\n');
        try w.print("iter={d}\tscore=", .{self.eval_iter});
        if (score) |s| try w.print("{d:.2}", .{s}) else try w.writeAll("NA");
        try w.writeAll("\tdet=");
        if (det) |d| try w.print("{d:.2}", .{d}) else try w.writeAll("NA");
        try w.writeAll("\tjudge=");
        if (judge) |j| try w.print("{d:.2}", .{j}) else try w.writeAll("NA");
        try w.print("\tbest={d:.2}\ttarget={d}\tmet={s}\texit={d}\tnote=", .{ self.eval_best, self.eval_target, if (met) "yes" else "no", exit_code });
        for (note) |ch| try w.writeByte(if (ch < 0x20) ' ' else ch);
        try w.writeByte('\n');
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = aw.writer.buffered() }) catch {};
    }

    /// Spawn an independent LLM judge (a read-only subagent) to score the
    /// current work against the --judge rubric on a 0-100 scale. The judge
    /// inspects the real artifacts with its own tools and ends its report with
    /// a `score:` line, parsed the same way as a deterministic eval. Runs on a
    /// pool thread via judgeTask (mirrors workflowTask) so the eval handler can
    /// await it. Returns null if the judge could not run or gave no score.
    fn runJudge(self: *Agent, rubric: []const u8, eval_output: []const u8, note: []const u8) ?f64 {
        const ctx: ToolCtx = .{
            .gpa = self.gpa,
            .io = self.io,
            .client = self.client,
            .provider = self.provider,
            .registry = if (self.sub) null else self.registry,
            .from_sub = self.sub,
            .approvals = self.approvals,
            .tracer = self.tracer,
            .snapshots = self.snapshots,
            .tools_used = &self.tools_used,
        };
        const evidence = if (eval_output.len > 1200) eval_output[eval_output.len - 1200 ..] else eval_output;
        const what = if (note.len > 0) note else "(no note given)";
        const judge_prompt = std.fmt.allocPrint(self.arena,
            \\Score the current state of the work in this directory against the rubric below, on a 0-100 scale.
            \\
            \\RUBRIC:
            \\{s}
            \\
            \\The author's note on the latest change: {s}
            \\
            \\An automated check was also run; its output (tail) is below as evidence. Form your OWN independent judgement of how well the artifacts satisfy the rubric - do not simply echo the check:
            \\---
            \\{s}
            \\---
            \\
            \\Inspect the actual files and artifacts the work produced (read them with your tools; do not modify anything), then score how fully they satisfy the rubric. End your reply with a single final line `score: <N>` where N is an integer from 0 to 100.
        , .{ rubric, what, evidence }) catch return null;
        var fut: Io.Future(ToolOutput) = self.io.async(judgeTask, .{ ctx, judge_prompt });
        const out = fut.await(self.io);
        defer self.gpa.free(out.text);
        if (out.is_error) return null;
        return parseEvalScore(out.text);
    }

    fn sayToolUse(self: *Agent, call: ToolCall) !void {
        if (json_mode) {
            if (std.mem.eql(u8, call.name, "ask_user")) return;
            self.emit(.{ .type = "tool_call", .name = call.name, .input = call.input });
            self.emit(.{ .type = "tool_call_started", .name = call.name, .input = call.input });
            return;
        }
        // The ⚙ line would just repeat prose that already streamed live.
        if (self.argStreamedFully(call)) return;
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.write(call.input);
        const full = aw.writer.buffered();
        const shown = if (full.len > 160) full[0..160] else full;
        try self.say("{s}⚙{s} {s}{s} {s}{s}{s}{s}\n", .{
            style.dim,   style.reset, style.cyan, call.name,
            style.dim,   shown,
            if (full.len > 160) "…" else "",
            style.reset,
        });
    }

    /// Compact result feedback for one finished tool call: a green ✓ / red ✗
    /// and a one-line preview of what it returned. Root only (subagents have
    /// no writer); meta tools render their own UX, so skip them.
    fn sayToolResult(self: *Agent, name: []const u8, r: ExecResult) void {
        const w = self.out orelse return;
        if (json_mode) {
            if (isMetaName(name) and !std.mem.eql(u8, name, "ask_user")) return;
            self.emit(.{ .type = "tool_result", .name = name, .is_error = r.is_error, .text = r.text });
            self.emit(.{ .type = "tool_call_finished", .name = name, .is_error = r.is_error, .ms = r.ms });
            return;
        }
        if (isMetaName(name)) return;
        const all = std.mem.trim(u8, r.text, " \t\r\n");
        var preview = all;
        if (std.mem.indexOfScalar(u8, preview, '\n')) |nl| preview = preview[0..nl];
        preview = std.mem.trim(u8, preview, " \t\r");
        const shown = if (preview.len > 100) preview[0..100] else preview;
        const truncated = shown.len < all.len; // more content (extra lines or >100 chars)
        const mark = if (r.is_error) "✗" else "✓";
        const mc = if (r.is_error) style.red else style.green;
        var tbuf: [24]u8 = undefined;
        const timing = if (show_timing and r.ms > 0)
            (std.fmt.bufPrint(&tbuf, " ({d}ms)", .{r.ms}) catch "")
        else
            "";
        w.print("  {s}{s}{s}{s}{s}{s} {s}{s}{s}{s}\n", .{
            mc,          mark,  style.reset, style.dim, timing, style.reset,
            style.dim,   shown,
            if (truncated) "…" else "",
            style.reset,
        }) catch return;
        w.flush() catch return;
    }

    /// Ask the model for a context-handoff summary (no tools), then restart
    /// history from that summary.
    fn compact(self: *Agent) anyerror!usize {
        if (self.messages.items.len == 0) {
            if (!json_mode) try self.say("nothing to compact\n", .{});
            return 0;
        }
        if (!json_mode) try self.say("[compacting ~{d} tokens…]\n", .{self.last_context_tokens});
        try self.messages.append(try textMessage(self.arena, "user", compact_instruction));
        errdefer _ = self.messages.pop();

        // The handoff summary is internal — don't stream it to the terminal.
        self.stream_quiet = true;
        defer self.stream_quiet = false;
        const root = try self.request(null);
        const summary = assistantText(self.provider.kind, root);
        if (summary.len == 0) {
            if (!json_mode) try self.say("[compaction failed: empty summary, history unchanged]\n", .{});
            _ = self.messages.pop();
            return error.EmptySummary;
        }

        var fresh = std.json.Array.init(self.arena);
        const handoff = try std.fmt.allocPrint(self.arena,
            \\Context: the prior conversation was compacted to save space.
            \\Summary of everything so far:
            \\
            \\{s}
            \\
            \\Continue assisting the user based on this summary.
        , .{summary});
        try fresh.append(try textMessage(self.arena, "user", handoff));
        self.messages = fresh;
        self.last_context_tokens = 0;
        if (!json_mode) try self.say("[history compacted to a {d}-char summary]\n", .{summary.len});
        return summary.len;
    }

    fn cleanUserTurn(m: Value) bool {
        if (m != .object) return false;
        const role = m.object.get("role") orelse return false;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
        const content = m.object.get("content") orelse return true;
        switch (content) {
            .string => return true, // a plain-text user turn
            .array => |arr| {
                // An anthropic user message that only carries tool_result blocks
                // is the response half of a tool call — it can't begin a
                // conversation, so it is not a safe trim boundary.
                for (arr.items) |blk| {
                    if (blk != .object) continue;
                    const t = blk.object.get("type") orelse continue;
                    if (t == .string and std.mem.eql(u8, t.string, "tool_result")) return false;
                }
                return true;
            },
            else => return true,
        }
    }

    /// Index to cut history at for an emergency trim: the first clean user turn
    /// at or after the midpoint, so messages[cut..] is always a valid
    /// conversation start (never an orphaned tool_result). null when there is no
    /// safe cut — too short, or only tool_result user messages remain.
    fn emergencyCutIndex(items: []const Value) ?usize {
        if (items.len < 4) return null;
        var i: usize = items.len / 2;
        while (i < items.len) : (i += 1) {
            if (cleanUserTurn(items[i])) return i;
        }
        return null;
    }

    /// Last-resort context recovery when compact() itself can't run — typically
    /// because the history already overflows the window, so the summarization
    /// request overflows too and fails. Drops the oldest messages at a safe
    /// boundary; returns the count dropped (0 if none). The next turn re-measures
    /// context from the provider usage.
    fn emergencyTrim(self: *Agent) usize {
        const cut = emergencyCutIndex(self.messages.items) orelse return 0;
        var fresh = std.json.Array.init(self.arena);
        for (self.messages.items[cut..]) |m| fresh.append(m) catch return 0;
        self.messages = fresh;
        self.last_context_tokens = 0;
        return cut;
    }

    /// Auto-compaction with recovery. compact() summarizes the whole history in
    /// one request; once context overflows the window that request overflows too
    /// and fails — historically swallowed silently, wedging the session so every
    /// later turn failed at the same huge token count (issue #88). Surface the
    /// failure and, when `trim_on_fail`, emergency-trim so the next turn has
    /// room. Best-effort; never throws into the REPL loop.
    fn compactOrRecover(self: *Agent, trim_on_fail: bool) void {
        if (self.compact()) |_| return else |err| {
            switch (err) {
                error.Interrupted => return, // user hit Esc mid-compaction
                error.EmptySummary => {}, // compact() already explained it
                else => {
                    if (json_mode)
                        self.emit(.{ .type = "error", .message = std.fmt.allocPrint(self.arena, "auto-compaction failed: {s}", .{@errorName(err)}) catch "auto-compaction failed" })
                    else
                        self.say("[auto-compaction failed: {t}]\n", .{err}) catch {};
                },
            }
            if (!trim_on_fail) return;
            const dropped = self.emergencyTrim();
            if (dropped > 0) {
                if (json_mode)
                    self.emit(.{ .type = "compact", .ok = true, .trimmed = dropped })
                else
                    self.say("[context emergency-trimmed: dropped {d} old message(s) so the session can continue]\n", .{dropped}) catch {};
            } else if (!json_mode) {
                self.say("[warning: context too large to compact and could not be trimmed safely]\n", .{}) catch {};
            }
        }
    }

    fn buildBody(self: *Agent, tools: ?[]const u8, force_tool: bool, stream: bool, stream_usage: bool) ![]u8 {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("model");
        try s.write(self.provider.model);
        switch (self.provider.kind) {
            .anthropic => {
                try s.objectField("max_tokens");
                try s.write(max_tokens);
                if (stream) {
                    try s.objectField("stream");
                    try s.write(true);
                }
                // Forced tool_choice conflicts with adaptive thinking; skip
                // thinking only when forcing.
                if (!force_tool) {
                    try s.objectField("thinking");
                    try s.print("{s}", .{"{\"type\":\"adaptive\"}"});
                }
                // Prompt caching (Anthropic): a cache_control breakpoint on the
                // system block caches the whole stable prefix (system + tools).
                // Must be block-level — a top-level cache_control is invalid.
                // Other anthropic-format providers (minimax) get a plain
                // string, since cache_control isn't part of their API.
                try s.objectField("system");
                const cc = "{\"type\":\"ephemeral\"}";
                if (std.mem.eql(u8, self.provider.id, "anthropic")) {
                    try s.beginArray();
                    try s.beginObject();
                    try s.objectField("type");
                    try s.write("text");
                    try s.objectField("text");
                    try s.write(self.systemPrompt());
                    try s.objectField("cache_control");
                    try s.print("{s}", .{cc});
                    try s.endObject();
                    try s.endArray();
                } else {
                    try s.write(self.systemPrompt());
                }
                if (tools) |t| {
                    try s.objectField("tools");
                    try s.print("{s}", .{t});
                    if (force_tool) {
                        try s.objectField("tool_choice");
                        try s.print("{s}", .{"{\"type\":\"any\"}"});
                    }
                }
                try s.objectField("messages");
                // Cache the conversation prefix too (not just system) on the real
                // Anthropic API: a rolling cache_control breakpoint on the last
                // message. minimax (anthropic-format, no cache_control) is excluded.
                const cache_msgs = std.mem.eql(u8, self.provider.id, "anthropic");
                try writeAnthropicMessages(&s, self.messages, cache_msgs);
            },
            .openai => {
                // graff's MakeOpenAiCompat: OpenAI deprecated max_tokens in
                // favor of max_completion_tokens — send the new name to the
                // direct OpenAI API, and to any provider that rejected the
                // old one (cap_new, learned via the retry in request()).
                const cap_field = if (std.mem.eql(u8, self.provider.id, "openai") or self.cap_new)
                    "max_completion_tokens"
                else
                    "max_tokens";
                try s.objectField(cap_field);
                try s.write(max_tokens);
                if (stream) {
                    try s.objectField("stream");
                    try s.write(true);
                    // Without include_usage the stream carries no token
                    // counts (context tracking + auto-compaction need them).
                    if (stream_usage) {
                        try s.objectField("stream_options");
                        try s.print("{s}", .{"{\"include_usage\":true}"});
                    }
                }
                if (tools) |t| {
                    try s.objectField("tools");
                    try s.print("{s}", .{t});
                    if (force_tool) {
                        try s.objectField("tool_choice");
                        try s.write("required");
                    }
                }
                try s.objectField("messages");
                try s.beginArray();
                try s.beginObject();
                try s.objectField("role");
                try s.write("system");
                try s.objectField("content");
                try s.write(self.systemPrompt());
                try s.endObject();
                for (self.messages.items) |m| try writeOpenAIMessageNormalized(&s, m);
                try s.endArray();
                // Reasoning-effort hint for OpenAI-compatible providers that
                // honor it (codegraff gateway, deepseek). Mirrors the
                // Responses `reasoning.effort` set in the branch below.
                if (self.effortApplies() and !self.effort_rejected) {
                    try s.objectField("reasoning_effort");
                    try s.write(@tagName(self.reasoning));
                }
                // Kimi K2.7's model card recommends temperature 1.0 + top_p 0.95
                // for its (always-on) Thinking mode; graff otherwise leaves
                // sampling to the server default.
                if (std.mem.eql(u8, self.provider.id, "kimi")) {
                    try s.objectField("temperature");
                    try s.write(@as(f64, 1.0));
                    try s.objectField("top_p");
                    try s.write(@as(f64, 0.95));
                }
            },
            .responses => {
                // Codex / ChatGPT Responses API. system prompt → instructions;
                // history items are valid input items; stream is required by
                // the backend (we buffer + parse the SSE). reasoning items are
                // returned encrypted and passed back for cross-turn continuity.
                try s.objectField("instructions");
                try s.write(self.systemPrompt());
                try s.objectField("input");
                try s.write(Value{ .array = self.messages });
                if (tools) |t| {
                    try s.objectField("tools");
                    try s.print("{s}", .{t});
                    try s.objectField("tool_choice");
                    try s.write(if (force_tool) "required" else "auto");
                    try s.objectField("parallel_tool_calls");
                    try s.write(true);
                }
                // Codex "fast" mode (/fast): request the priority service
                // tier for lower latency. This branch is codex-only, so it is
                // never emitted for other providers.
                if (self.fast) {
                    try s.objectField("service_tier");
                    try s.write("priority");
                }
                try s.objectField("reasoning");
                try s.beginObject();
                try s.objectField("effort");
                try s.write(@tagName(self.reasoning));
                try s.endObject();
                try s.objectField("include");
                try s.beginArray();
                try s.write("reasoning.encrypted_content");
                try s.endArray();
                try s.objectField("store");
                try s.write(false);
                try s.objectField("stream");
                try s.write(true);
            },
        }
        try s.endObject();
        return aw.toOwnedSlice();
    }

    /// Streaming POST for the root agent: the same wire request as post(),
    /// but the SSE body is read line-by-line, printing text deltas as they
    /// arrive. Returns the full raw body (gpa-owned) so the caller can
    /// reassemble the response. Non-SSE bodies (error envelopes, providers
    /// that ignore `stream`) pass through unharmed: no delta lines match
    /// and the buffered body falls back to regular parsing.
    // ── thinking spinner ────────────────────────────────────────────────
    // An animated indicator on the root agent's line while the model is
    // silent: from request send, through connect + time-to-first-token,
    // and through reasoning-model thinking deltas (which print nothing) —
    // cleared the moment the first visible text byte streams (printDelta)
    // or the stream ends (postStream's defer). Root + interactive TTY only;
    // single-threaded start/stop (root thread), the task itself is on the
    // pool and polls the stop flag every 20ms so stopping is near-instant.
    // The animation is picked via /animation (ported in spirit from
    // arpagon/pi-animations, MIT) and persists in .harness/settings.json.
    var g_spin_stop: std.atomic.Value(bool) = .init(true);
    var g_spin_future: ?Io.Future(void) = null;

    fn spinnerTask(io: Io) void {
        var i: usize = 0;
        var buf: [512]u8 = undefined;
        var w = Io.File.stdout().writer(io, &buf);
        while (!g_spin_stop.load(.acquire)) {
            if (g_steer_visible.load(.acquire)) {
                io.sleep(.fromMilliseconds(20), .awake) catch break;
                continue;
            }
            // Clear-then-draw each frame: animations may vary in width.
            w.interface.writeAll("\r\x1b[2K\x1b[?7l") catch return; // ?7l: autowrap off so a wide spinner truncates instead of wrapping in a narrow window (the "goes on and on" bug)
            anim.anims[anim.g_anim_current].frame(&w.interface, i) catch return;
            w.interface.writeAll("\x1b[?7h") catch return; // restore autowrap
            w.interface.flush() catch return;
            i += 1;
            var t: usize = 0;
            while (t < 4 and !g_spin_stop.load(.acquire)) : (t += 1) {
                if (g_steer_visible.load(.acquire)) break;
                io.sleep(.fromMilliseconds(20), .awake) catch break;
            }
        }
        if (!g_steer_visible.load(.acquire)) {
            w.interface.writeAll("\x1b[?7h\r\x1b[2K") catch return; // restore autowrap + clear
            w.interface.flush() catch {};
        }
    }

    fn spinnerStart(self: *Agent) void {
        if (self.sub or json_mode or !use_color or self.out == null) return;
        if (anim.g_anim_off) return;
        if (g_spin_future != null) return;
        anim.selectSpinner(self.io);
        g_spin_stop.store(false, .release);
        g_spin_future = self.io.concurrent(spinnerTask, .{self.io}) catch blk: {
            g_spin_stop.store(true, .release); // no spare concurrency: skip quietly
            break :blk null;
        };
    }

    fn spinnerStop(self: *Agent) void {
        if (self.sub) return; // root-only state — subs run on pool threads
        if (g_spin_future) |*f| {
            g_spin_stop.store(true, .release);
            f.await(self.io);
            g_spin_future = null;
        }
    }

    /// Stream a chunk of the model's reasoning into a live, dimmed "Thinking"
    /// block in the terminal, opening the block (and handing the line off from
    /// the spinner) on the first chunk. Gated by /thinking; when off the block is
    /// never opened and the spinner stands in for it. We track the block's
    /// on-screen height as it streams so closeThinkingBlock can collapse it to a
    /// one-line summary when the answer starts (#75).
    fn streamThinking(self: *Agent, chunk: []const u8) void {
        const w = self.out orelse return;
        if (!self.thinking_open) {
            self.spinnerStop();
            w.print("{s}▼ Thinking{s}\n{s}", .{ style.dim, style.reset, style.dim }) catch return;
            self.thinking_open = true;
            g_thinking_open = true;
            self.thinking_rows = 1; // the header newline already moved us down one line
            self.thinking_col = 0;
            self.thinking_overflow = false;
        }
        self.thinking_text.appendSlice(self.gpa, chunk) catch {};
        if (self.thinking_folded) return; // folded: buffer only, don't draw the live block
        w.writeAll(chunk) catch return;
        w.flush() catch return;
        advanceThinkingRows(&self.thinking_rows, &self.thinking_col, termCols(), chunk);
        if (self.thinking_rows + 1 >= termRows()) self.thinking_overflow = true;
    }

    /// Close an open "Thinking" block. If it still fits on screen, collapse it in
    /// place to a one-line "Thought" summary (#75); if it has scrolled off
    /// (overflow) leave the reasoning and just append the summary, so we never
    /// erase the user's earlier output. Runs on the reasoning->answer transition
    /// and at stream end.
    fn closeThinkingBlock(self: *Agent) void {
        if (!self.thinking_open) return;
        self.thinking_open = false;
        g_thinking_open = false;
        self.thinking_folded = false;
        const w = self.out orelse return;
        if (!self.thinking_overflow and self.thinking_rows >= 1 and use_color) {
            w.print("\x1b[{d}F\x1b[0J{s}✓ Thought{s}\n\n", .{ self.thinking_rows, style.dim, style.reset }) catch return;
        } else {
            w.print("{s}\n{s}✓ Thought{s}\n\n", .{ style.reset, style.dim, style.reset }) catch return;
        }
        w.flush() catch return;
    }

    /// Ctrl-T: fold/unfold the live "Thinking" block in place (#92/#85). Only
    /// acts on an open, on-screen block; folding erases it to a one-line marker,
    /// unfolding re-streams the buffered reasoning. Cursor math mirrors
    /// closeThinkingBlock (erase `thinking_rows` lines up, clear to end).
    fn toggleThinkingFold(self: *Agent) void {
        if (!self.thinking_open or self.thinking_overflow or !use_color) return;
        const w = self.out orelse return;
        if (!self.thinking_folded) {
            w.print("\x1b[{d}F\x1b[0J{s}▶ Thinking (folded · ^T){s}\n", .{ self.thinking_rows, style.dim, style.reset }) catch return;
            self.thinking_folded = true;
            self.thinking_rows = 1;
            self.thinking_col = 0;
        } else {
            w.print("\x1b[1F\x1b[0J{s}▼ Thinking{s}\n{s}", .{ style.dim, style.reset, style.dim }) catch return;
            self.thinking_folded = false;
            self.thinking_rows = 1;
            self.thinking_col = 0;
            w.writeAll(self.thinking_text.items) catch return;
            advanceThinkingRows(&self.thinking_rows, &self.thinking_col, termCols(), self.thinking_text.items);
        }
        w.flush() catch return;
    }

    fn postStream(self: *Agent, body: []const u8) ![]u8 {
        self.spinnerStart();
        defer self.spinnerStop();
        self.thinking_open = false; // fresh "Thinking" block state per request
        g_thinking_open = false;
        self.thinking_rows = 0;
        self.thinking_col = 0;
        self.thinking_folded = false;
        self.thinking_text.clearRetainingCapacity();
        self.thinking_overflow = false;
        defer self.closeThinkingBlock(); // close a reasoning-only turn's block
        const gpa = self.gpa;
        const provider = self.provider;
        const bearer = switch (provider.auth) {
            .x_api_key => "",
            .bearer => try std.fmt.allocPrint(gpa, "Bearer {s}", .{provider.api_key}),
        };
        defer if (bearer.len > 0) gpa.free(bearer);
        var headers_buf: [6]std.http.Header = undefined;
        const extra = providerHeaders(provider, bearer, &headers_buf);

        self.md_buf.clearRetainingCapacity(); // fresh markdown state per stream
        self.arg_live = .{}; // fresh tool-argument extractor per stream
        self.md_fence = false;
        self.md_kind = .classify;
        self.md_span = .normal;
        self.md_word.clearRetainingCapacity();
        self.md_word_vis = 0;
        self.md_col = 0;
        self.md_indent = 0;
        self.md_width = 0; // re-read the terminal width (resizes)
        for (self.md_table.items) |r| gpa.free(r); // an errored stream can leave rows behind
        self.md_table.clearRetainingCapacity();
        self.partial_text.clearRetainingCapacity(); // fresh Esc-interrupt capture

        // Esc-interrupt: while the root's request is on a TTY, stdin sits in
        // raw non-blocking no-echo mode — from *before* the connect, so Esc
        // pressed during a slow time-to-first-token wait neither echoes ^[
        // nor leaks into the next prompt. Polled between SSE lines; leftover
        // bytes are drained before canonical mode returns, so gate prompts
        // and the line editor see a clean tty.
        const watch_esc = !self.sub and self.in != null and use_color and !json_mode;
        var orig_tio: ?tty.RawState = null;
        if (watch_esc) {
            orig_tio = rawNonblockStdin();
            // SGR mouse reporting is intentionally NOT enabled. Grabbing the mouse
            // (\x1b[?1000;1006h) makes the terminal forward wheel events to us instead
            // of scrolling its own scrollback, so scrolling up mid-stream got captured
            // as input. Leaving the mouse to the terminal keeps native scroll — parity
            // with Claude Code. The live Thinking block still folds via Ctrl-T (see
            // escPressed); its SGR click-to-fold path stays wired but dormant.
        }
        defer if (orig_tio) |o| {
            _ = drainSteerStdin(true);
            tty.restore(o);
        };
        var req = try self.client.request(.POST, try std.Uri.parse(provider.url), .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .user_agent = providerUserAgent(provider),
            },
            .extra_headers = extra,
        });
        defer req.deinit();
        // A failed SEND leaves reader.state == .ready, which Request.deinit
        // reads as "connection still clean" and returns it to the keep-alive
        // pool — every retry (and every later turn) then pulls the same dead
        // connection back out: HttpConnectionClosing once, WriteFailed
        // forever after (observed in the wild). Poison it on any error so
        // deinit discards it and the retry dials fresh.
        errdefer if (req.connection) |conn| {
            conn.closing = true;
        };
        // Race the send + head receive against a stall watchdog so a
        // freshly-redialed connection that the server accepts but never
        // answers can't hang the turn (issue #54: "retrying (1/3)" then
        // "thinking… forever"). Mirrors the SSE line-loop and postWatched
        // patterns. Falls back to a bare send+receiveHead (the old behavior)
        // when no spare concurrency exists.
        var response: std.http.Client.Response = undefined;
        head: {
            const HeadDone = union(enum) { sent: anyerror!void, stall: WatchdogFired };
            var hd_buf: [2]HeadDone = undefined;
            var hsel: Io.Select(HeadDone) = .init(self.io, &hd_buf);
            hsel.concurrent(.sent, sendHeadTask, .{ &req, body, &response }) catch {
                // No spare concurrency: accept the hang risk (existing behavior).
                req.transfer_encoding = .{ .content_length = body.len };
                var bw = try req.sendBodyUnflushed(&.{});
                try bw.writer.writeAll(body);
                try bw.end();
                try req.connection.?.flush();
                response = try req.receiveHead(&.{});
                break :head;
            };
            hsel.concurrent(.stall, headStallTask, .{ self.io, orig_tio != null }) catch {
                const r = hsel.await() catch |e| {
                    hsel.cancelDiscard();
                    return e;
                };
                hsel.cancelDiscard();
                r.sent catch |e| {
                    return e;
                };
                break :head;
            };
            const first = hsel.await() catch |e| {
                hsel.cancelDiscard();
                return e;
            };
            hsel.cancelDiscard();
            switch (first) {
                .sent => |s| s catch |e| {
                    return e;
                },
                .stall => |w| {
                    if (req.connection) |conn| conn.closing = true;
                    return if (w == .esc) error.Interrupted else error.HungRequest;
                },
            }
        }

        // 429/5xx before any body: a retryable throttle — request() backs
        // off and retries (surfaced in the trace as a "retry" note).
        const status_code = @intFromEnum(response.head.status);
        if (status_code == 429 or status_code >= 500) {
            // Drain a snippet of the error body so the retry message can
            // surface the gateway's diagnostic (e.g. "upstream timeout")
            // instead of a bare "server error (5xx)".
            capture5xxBodyStream(self.gpa, &response);
            if (req.connection) |conn| conn.closing = true;
            return if (status_code == 429) error.RateLimited else error.ServerError;
        }
        // Esc pressed while connecting / waiting for headers? Stop before
        // reading any of the body.
        if (orig_tio != null and escPressed(true)) {
            if (req.connection) |conn| conn.closing = true;
            return error.Interrupted;
        }

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        var full: Io.Writer.Allocating = .init(gpa);
        errdefer full.deinit();
        var line: Io.Writer.Allocating = .init(gpa);
        defer line.deinit();

        while (true) {
            // Race the line read against an idle-stall watchdog so a dead
            // stream can't hang the turn (the Esc escape below is TTY-only, so
            // --json/GUI sessions would otherwise wait forever).
            read: {
                const ReadDone = union(enum) { line: anyerror!usize, stall: WatchdogFired };
                var rd_buf: [2]ReadDone = undefined;
                var rsel: Io.Select(ReadDone) = .init(self.io, &rd_buf);
                rsel.concurrent(.line, streamLineTask, .{ reader, &line.writer }) catch {
                    _ = try reader.streamDelimiterEnding(&line.writer, '\n'); // no spare concurrency
                    break :read;
                };
                rsel.concurrent(.stall, streamStallTask, .{ self.io, orig_tio != null }) catch {
                    const r = rsel.await() catch |e| {
                        rsel.cancelDiscard();
                        return e;
                    };
                    rsel.cancelDiscard();
                    _ = try r.line;
                    break :read;
                };
                const first = rsel.await() catch |e| {
                    rsel.cancelDiscard();
                    return e;
                };
                rsel.cancelDiscard();
                switch (first) {
                    .line => |r| _ = try r,
                    .stall => |w| {
                        self.flushStreamTail();
                        if (req.connection) |conn| conn.closing = true;
                        if (w == .deadline and !json_mode) if (self.out) |o| {
                            o.writeAll("\n⚠ stream stalled — ending turn\n") catch {};
                            o.flush() catch {};
                        };
                        return error.Interrupted;
                    },
                }
            }
            // End of stream leaves the reader empty; otherwise the '\n' is
            // still buffered (and consumed below, after the line is handled).
            const more = if (reader.peekByte()) |_| true else |_| false;
            try full.writer.writeAll(line.writer.buffered());
            try full.writer.writeByte('\n');
            self.printDelta(line.writer.buffered());
            if (g_thinking_fold_request) {
                g_thinking_fold_request = false;
                self.toggleThinkingFold();
            }
            line.clearRetainingCapacity();
            if ((orig_tio != null and escPressed(true)) or (self.sub and esc_cancel.load(.acquire))) {
                self.flushStreamTail();
                // Mark the connection closing so req.deinit() tears it down
                // instead of draining the rest of the stream (which would
                // block until the model finished generating anyway). Subs get
                // here via esc_cancel: the root saw Esc during a tool join.
                if (req.connection) |conn| conn.closing = true;
                return error.Interrupted;
            }
            if (!more) break;
            reader.toss(1);
        }
        self.flushStreamTail(); // render any held partial markdown line
        if (!json_mode and self.streamed_text) if (self.out) |w| {
            w.writeAll("\n") catch {};
            w.flush() catch {};
        };
        return full.toOwnedSlice();
    }

    /// Esc-during-tools cancellation. postStream only watches stdin while an
    /// HTTP stream is live, so a long tool join (bash, a subagent fan-out, a
    /// whole workflow) used to be Esc-deaf — exactly when turns feel longest.
    /// While the root awaits tool futures, escWatchTask polls stdin from the
    /// pool; Esc sets esc_cancel, which subagents poll between SSE lines and
    /// turn iterations, and the root consumes at its next loop head as
    /// error.Interrupted.
    pub var esc_cancel: std.atomic.Value(bool) = .init(false);
    var esc_watch_done: std.atomic.Value(bool) = .init(true);

    fn escWatchTask() void {
        while (!esc_watch_done.load(.acquire)) {
            if (tty.poll(100) and escPressed(false)) {
                esc_cancel.store(true, .release);
                return;
            }
        }
    }

    /// Non-blocking scan of stdin (terminal must be in VMIN=0 raw mode). A
    /// lone Esc cancels the turn (returns true); CSI sequences (arrows:
    /// ESC[…/ESC O…) are swallowed and don't cancel. Printable bytes are
    /// captured into the steering buffer and echoed when `echo` (main thread
    /// only — the esc watch task runs on the pool and must not race tool
    /// output); Enter flushes the line to g_steer_queue, which the REPL
    /// drains as follow-up turns after the current one finishes. A second
    /// Enter on an empty line (double-enter) with a non-empty queue
    /// force-interrupts the current turn so the queue drains immediately.
    fn escPressed(echo: bool) bool {
        var buf: [256]u8 = undefined;
        var n = tty.readStdin(&buf);
        var esc_found = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = buf[i];
            if (c == 0x1b) {
                if (i + 1 < n and buf[i + 1] == '[') {
                    // CSI escape sequence (arrows, Home/End, Delete, DSR reply,
                    // mouse, etc.). Consume through the final byte (0x40..0x7e) so
                    // bytes like "[A" never get captured as steering prompt text. A
                    // CSI run can straddle a VMIN=0 read boundary — e.g. the
                    // \x1b[<row>;<col>R cursor-position reply to our \x1b[6n, or a
                    // burst of SGR mouse-wheel reports if click-to-fold reporting is
                    // re-enabled. If the final byte hasn't landed yet, poll briefly and
                    // pull the tail into the same buffer so its trailing digits/';'/
                    // final byte don't leak in as steer text.
                    var j = i + 2;
                    while (true) {
                        while (j < n) : (j += 1) {
                            if (buf[j] >= 0x40 and buf[j] <= 0x7e) break;
                        }
                        if (j < n or n >= buf.len or !tty.poll(50)) break;
                        const more = tty.readStdin(buf[n..]);
                        if (more == 0) break;
                        n += more;
                    }
                    // SGR mouse report (ESC [ < btn ; col ; row, M=press/m=release):
                    // a plain left-button press (btn 0) on the live Thinking block
                    // toggles its fold — the clickable control for #92. Other mouse
                    // events fall through and are swallowed like any CSI sequence.
                    if (j < n and buf[j] == 'M' and i + 2 < n and buf[i + 2] == '<') {
                        var mk = i + 3;
                        var btn: usize = 0;
                        var got = false;
                        while (mk < j and buf[mk] >= '0' and buf[mk] <= '9') : (mk += 1) {
                            btn = btn * 10 + (buf[mk] - '0');
                            got = true;
                        }
                        if (got and btn == 0 and g_thinking_open) g_thinking_fold_request = true;
                    }
                    i = if (j < n) j else n - 1;
                    continue;
                } else if (i + 1 < n and buf[i + 1] == 'O') {
                    // SS3 escape sequence (common for function/cursor keys):
                    // ESC O <final>. Swallow the whole sequence.
                    i = @min(i + 2, n - 1);
                    continue;
                } else if (i + 1 >= n) {
                    // ESC is the LAST byte of this chunk — it may be the truncated
                    // head of a split CSI/SS3/DSR sequence (e.g. a delayed
                    // `\x1b[<row>;<col>R` cursor-position reply to our `\x1b[6n`)
                    // read across two VMIN=0 reads, NOT a real Esc keypress (#94).
                    // Briefly wait for a continuation before concluding it's an Esc.
                    if (tty.poll(50)) {
                        var more: [64]u8 = undefined;
                        if (tty.readStdin(&more) > 0) {
                            i = n; // a sequence/alt-chord followed — not a lone Esc
                            continue;
                        }
                    }
                    // Nothing followed within the grace window: a genuine lone Esc.
                    esc_found = true;
                    g_force_interrupt = false;
                } else {
                    // ESC + a non-CSI/SS3 byte in the same chunk: a real Esc.
                    esc_found = true;
                    g_force_interrupt = false;
                }
                continue;
            } else if (c == '\n' or c == '\r') {
                if (g_steer_buf.items.len > 0) {
                    // Flush the typed line to the queue as a regular
                    // follow-up (runs after the current turn finishes).
                    if (g_steer_buf.toOwnedSlice(std.heap.page_allocator)) |dup| {
                        g_steer_queue.append(std.heap.page_allocator, .{ .text = dup, .force = false }) catch std.heap.page_allocator.free(dup);
                    } else |_| g_steer_buf.clearRetainingCapacity();
                    if (echo and g_steer_echoed) {
                        var qbuf: [64]u8 = undefined;
                        const qmsg = std.fmt.bufPrint(&qbuf, "  \x1b[2m[queued · {d} waiting]\x1b[0m\n", .{g_steer_queue.items.len}) catch "\n";
                        steerEcho(qmsg);
                    }
                } else if (g_steer_queue.items.len > 0) {
                    // Double-enter (empty line + queue non-empty): force —
                    // promote the first queued item and interrupt the
                    // current turn so the queue drains starting now.
                    g_steer_queue.items[0].force = true;
                    esc_found = true;
                    g_force_interrupt = true;
                    if (echo) {
                        if (g_steer_echoed) steerEcho("\n");
                        steerEcho("\x1b[33m↳ force › interrupting…\x1b[0m\n");
                    }
                }
                g_steer_echoed = false;
                g_steer_visible.store(false, .release);
                continue;
            } else if (c == 0x7f or c == 0x08) { // backspace / Ctrl-H
                if (g_steer_buf.items.len > 0) {
                    _ = g_steer_buf.pop();
                    if (echo) steerEcho("\x08 \x08");
                }
                continue;
            } else if (c == 0x14) { // Ctrl-T: fold/unfold the live Thinking block (#92)
                g_thinking_fold_request = true;
                continue;
            } else if (c < 0x20) {
                continue; // other control bytes: ignore
            }
            g_steer_buf.append(std.heap.page_allocator, c) catch continue;
            if (echo) {
                if (!g_steer_echoed) {
                    g_steer_visible.store(true, .release);
                    steerEcho("\n\x1b[36m↳ steer ›\x1b[0m ");
                    g_steer_echoed = true;
                }
                steerEcho(buf[i .. i + 1]);
            }
        }
        return esc_found;
    }

    /// Process any bytes queued on stdin (terminal must be in VMIN=0 raw
    /// mode) so typed-ahead steering text is preserved instead of leaking into
    /// the next prompt or being blindly discarded. Returns true if Esc/force
    /// was seen while draining.
    pub fn drainSteerStdin(echo: bool) bool {
        var esc_found = false;
        while (true) {
            if (!tty.poll(0)) return esc_found;
            if (escPressed(echo)) esc_found = true;
        }
    }

    fn drainStdin() void {
        _ = drainSteerStdin(false);
    }

    /// Put stdin into raw non-blocking no-echo mode (VMIN=0) for Esc
    /// watching. Returns the termios to restore, or null off-tty.
    fn rawNonblockStdin() ?tty.RawState {
        return tty.enterRaw(false);
    }

    /// Sleep `ms` watching stdin for Esc (when the root is on a TTY), so the
    /// user can cancel a retry backoff instead of waiting it out.
    fn sleepInterruptible(self: *Agent, ms: u64) error{Interrupted}!void {
        const watch = !self.sub and self.in != null and use_color and !json_mode;
        const orig_tio: ?tty.RawState = if (watch) rawNonblockStdin() else null;
        defer if (orig_tio) |o| tty.restore(o);
        var left = ms;
        while (left > 0) {
            const chunk = @min(left, 100);
            self.io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch {};
            left -= chunk;
            if (orig_tio != null and escPressed(true)) return error.Interrupted;
        }
    }

    /// The `data: {...}` payload of one SSE line, or null for anything else
    /// (event: lines, keep-alive blanks, [DONE]).
    fn ssePayload(raw_line: []const u8) ?[]const u8 {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) return null;
        const payload = std.mem.trim(u8, line["data:".len..], " ");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) return null;
        return payload;
    }

    fn sseIndex(obj: std.json.ObjectMap) ?usize {
        const ix = obj.get("index") orelse return null;
        if (ix != .integer or ix.integer < 0) return null;
        return @intCast(ix.integer);
    }

    /// Print the user-visible text from one SSE line, if any. Best-effort:
    /// parse failures are ignored (the buffered body is parsed afterwards).
    fn printDelta(self: *Agent, raw_line: []const u8) void {
        const w = self.out orelse return;
        const payload = ssePayload(raw_line) orelse return;
        const parsed = std.json.parseFromSlice(Value, self.gpa, payload, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        self.argLiveDelta(obj);
        const text: []const u8 = switch (self.provider.kind) {
            .anthropic => blk: {
                const t = obj.get("type") orelse break :blk "";
                if (t != .string or !std.mem.eql(u8, t.string, "content_block_delta")) break :blk "";
                const d = obj.get("delta") orelse break :blk "";
                if (d != .object) break :blk "";
                const dt = d.object.get("type") orelse break :blk "";
                if (dt != .string or !std.mem.eql(u8, dt.string, "text_delta")) break :blk "";
                const x = d.object.get("text") orelse break :blk "";
                break :blk if (x == .string) x.string else "";
            },
            .openai => blk: {
                const choices = obj.get("choices") orelse break :blk "";
                if (choices != .array or choices.array.items.len == 0) break :blk "";
                const c0 = choices.array.items[0];
                if (c0 != .object) break :blk "";
                const d = c0.object.get("delta") orelse break :blk "";
                if (d != .object) break :blk "";
                const x = d.object.get("content") orelse break :blk "";
                break :blk if (x == .string) x.string else "";
            },
            .responses => blk: {
                const t = obj.get("type") orelse break :blk "";
                if (t != .string or !std.mem.eql(u8, t.string, "response.output_text.delta")) break :blk "";
                const x = obj.get("delta") orelse break :blk "";
                break :blk if (x == .string) x.string else "";
            },
        };
        // Reasoning/thinking deltas: deepseek streams reasoning_content, anthropic
        // a thinking_delta, codex a summary delta. JSON clients get a `reasoning`
        // event; on a TTY we stream it into a live, dimmed "Thinking" block when
        // /thinking is enabled, otherwise the spinner stands in for it.
        const reasoning = reasoningDelta(self.provider.kind, obj);
        if (reasoning.len != 0) {
            if (json_mode) {
                self.emit(.{ .type = "reasoning", .text = reasoning });
            } else if (self.show_thinking and !self.sub and !self.stream_quiet and use_color) {
                self.streamThinking(reasoning);
            }
        }
        if (text.len == 0) return;
        if (self.thinking_open) self.closeThinkingBlock(); // reasoning → answer transition
        self.spinnerStop(); // first visible byte: clear the thinking line
        self.streamed_text = true;
        self.partial_text.appendSlice(self.arena, text) catch {}; // Esc-interrupt capture
        if (json_mode) {
            self.emit(.{ .type = "text", .text = text });
        } else if (use_color) {
            self.streamMarkdown(text);
        } else {
            w.writeAll(text) catch return;
            w.flush() catch return;
        }
    }

    const ArgTool = enum { none, attempt_completion, ask_user };

    fn argToolFor(name: []const u8) ArgTool {
        if (std.mem.eql(u8, name, "attempt_completion")) return .attempt_completion;
        if (std.mem.eql(u8, name, "ask_user")) return .ask_user;
        return .none;
    }

    fn argField(tool: ArgTool) []const u8 {
        return switch (tool) {
            .attempt_completion => "result",
            .ask_user => "question",
            .none => "",
        };
    }

    /// Live tool-argument text. attempt_completion and ask_user carry their
    /// user-facing prose inside tool-call argument JSON, which the text-delta
    /// matching in printDelta can't see — in strict mode that's the *whole*
    /// answer, so the turn looked frozen while it streamed, then dumped at
    /// once. This is a byte-at-a-time scanner over the argument fragments:
    /// skip to the target string field at the top level of the args object
    /// ("result" / "question"), then unescape its value and print it as it
    /// arrives. Best-effort mirror of the real parse that follows the stream
    /// — a glitch here is cosmetic, never semantic.
    const ArgLive = struct {
        tool: ArgTool = .none, // which whitelisted call is open
        index: i64 = -1, // the provider's stream index for that call
        state: State = .seek_key,
        depth: u32 = 0, // container nesting while skipping a non-target value
        in_str: bool = false, // inside a skipped string
        esc: bool = false, // previous byte was '\'
        uni_left: u8 = 0, // hex digits still expected in a \uXXXX escape
        uni_val: u16 = 0,
        hi_sur: u16 = 0, // pending UTF-16 high surrogate (0 = none)
        key: [24]u8 = undefined,
        key_len: usize = 0,
        key_over: bool = false, // key overflowed/escaped — cannot be the target

        const State = enum { seek_key, key, post_key, pre_val, skip_val, val, done };

        fn open(self: *ArgLive, name: []const u8, ix: i64) void {
            const tool = argToolFor(name);
            if (tool == .none) return;
            self.* = .{ .tool = tool, .index = ix };
        }

        fn close(self: *ArgLive, ix: i64) void {
            if (ix == self.index) self.* = .{};
        }

        fn feed(self: *ArgLive, agent: *Agent, ix: i64, frag: []const u8) void {
            if (self.tool == .none or ix != self.index or self.state == .done) return;
            var out_buf: [512]u8 = undefined;
            var out_len: usize = 0;
            for (frag) |c| {
                if (out_len > out_buf.len - 8) { // keep room for one decoded escape
                    agent.emitArgText(self.tool, out_buf[0..out_len]);
                    out_len = 0;
                }
                switch (self.state) {
                    .done => break,
                    .seek_key => switch (c) {
                        '"' => {
                            self.state = .key;
                            self.key_len = 0;
                            self.key_over = false;
                        },
                        '}' => self.state = .done,
                        else => {}, // '{', ',', whitespace
                    },
                    .key => if (self.esc) {
                        self.esc = false;
                        self.key_over = true; // escaped keys never match the plain target
                    } else switch (c) {
                        '\\' => self.esc = true,
                        '"' => self.state = .post_key,
                        else => if (self.key_len < self.key.len) {
                            self.key[self.key_len] = c;
                            self.key_len += 1;
                        } else {
                            self.key_over = true;
                        },
                    },
                    .post_key => if (c == ':') {
                        self.state = .pre_val;
                    },
                    .pre_val => switch (c) {
                        ' ', '\t', '\r', '\n' => {},
                        '"' => if (!self.key_over and std.mem.eql(u8, self.key[0..self.key_len], argField(self.tool))) {
                            self.state = .val;
                        } else {
                            self.state = .skip_val;
                            self.in_str = true;
                            self.depth = 0;
                        },
                        '{', '[' => {
                            self.state = .skip_val;
                            self.in_str = false;
                            self.depth = 1;
                        },
                        else => { // number / true / false / null
                            self.state = .skip_val;
                            self.in_str = false;
                            self.depth = 0;
                        },
                    },
                    .skip_val => if (self.in_str) {
                        if (self.esc) {
                            self.esc = false;
                        } else if (c == '\\') {
                            self.esc = true;
                        } else if (c == '"') {
                            self.in_str = false;
                            if (self.depth == 0) self.state = .seek_key;
                        }
                    } else switch (c) {
                        '"' => self.in_str = true,
                        '{', '[' => self.depth += 1,
                        ']' => {
                            if (self.depth > 0) self.depth -= 1;
                            if (self.depth == 0) self.state = .seek_key;
                        },
                        '}' => if (self.depth == 0) {
                            self.state = .done; // end of the args object
                        } else {
                            self.depth -= 1;
                            if (self.depth == 0) self.state = .seek_key;
                        },
                        ',' => if (self.depth == 0) {
                            self.state = .seek_key;
                        },
                        else => {},
                    },
                    .val => {
                        if (self.uni_left > 0) {
                            const d = std.fmt.charToDigit(c, 16) catch {
                                self.uni_left = 0; // malformed escape: drop it
                                continue;
                            };
                            self.uni_val = self.uni_val * 16 + d;
                            self.uni_left -= 1;
                            if (self.uni_left == 0) out_len += self.takeUnit(out_buf[out_len..]);
                            continue;
                        }
                        if (self.esc) {
                            self.esc = false;
                            switch (c) {
                                'n' => out_len += self.put(out_buf[out_len..], '\n'),
                                't' => out_len += self.put(out_buf[out_len..], '\t'),
                                'r' => out_len += self.put(out_buf[out_len..], '\r'),
                                'b' => out_len += self.put(out_buf[out_len..], 0x08),
                                'f' => out_len += self.put(out_buf[out_len..], 0x0c),
                                'u' => {
                                    self.uni_left = 4;
                                    self.uni_val = 0;
                                },
                                else => out_len += self.put(out_buf[out_len..], c), // " \ /
                            }
                        } else switch (c) {
                            '\\' => self.esc = true,
                            '"' => self.state = .done, // value captured — nothing else prints
                            else => out_len += self.put(out_buf[out_len..], c),
                        }
                    },
                }
            }
            if (out_len > 0) agent.emitArgText(self.tool, out_buf[0..out_len]);
        }

        /// Emit one literal byte, flushing any orphaned high surrogate first.
        fn put(self: *ArgLive, buf: []u8, c: u8) usize {
            var n: usize = 0;
            if (self.hi_sur != 0) {
                n = replacement(buf);
                self.hi_sur = 0;
            }
            buf[n] = c;
            return n + 1;
        }

        /// A completed \uXXXX code unit: pair surrogates, emit UTF-8.
        fn takeUnit(self: *ArgLive, buf: []u8) usize {
            const u = self.uni_val;
            self.uni_val = 0;
            if (u >= 0xD800 and u <= 0xDBFF) { // high surrogate: hold for its pair
                var n: usize = 0;
                if (self.hi_sur != 0) n = replacement(buf); // two highs in a row
                self.hi_sur = u;
                return n;
            }
            var cp: u21 = u;
            var n: usize = 0;
            if (u >= 0xDC00 and u <= 0xDFFF) { // low surrogate
                if (self.hi_sur == 0) return replacement(buf); // unpaired
                cp = 0x10000 + (@as(u21, self.hi_sur - 0xD800) << 10) + (u - 0xDC00);
                self.hi_sur = 0;
            } else if (self.hi_sur != 0) {
                n = replacement(buf); // high surrogate not followed by a low
                self.hi_sur = 0;
            }
            n += std.unicode.utf8Encode(cp, buf[n..]) catch 0;
            return n;
        }

        fn replacement(buf: []u8) usize {
            @memcpy(buf[0..3], "\u{FFFD}");
            return 3;
        }
    };

    fn outputIndex(obj: std.json.ObjectMap) ?i64 {
        const ix = obj.get("output_index") orelse return null;
        return if (ix == .integer) ix.integer else null;
    }

    /// Track tool-call open/delta/close events in the SSE stream and feed
    /// attempt_completion / ask_user argument fragments to the ArgLive
    /// extractor for live printing. Root interactive streams only — SDK
    /// (--json) clients get the assembled tool_call event instead.
    fn argLiveDelta(self: *Agent, obj: std.json.ObjectMap) void {
        if (self.sub or json_mode or self.stream_quiet) return;
        switch (self.provider.kind) {
            .anthropic => {
                const t = obj.get("type") orelse return;
                if (t != .string) return;
                if (std.mem.eql(u8, t.string, "content_block_start")) {
                    const ix = sseIndex(obj) orelse return;
                    const cb = obj.get("content_block") orelse return;
                    if (cb != .object) return;
                    const bt = cb.object.get("type") orelse return;
                    if (bt != .string or !std.mem.eql(u8, bt.string, "tool_use")) return;
                    const name = cb.object.get("name") orelse return;
                    if (name == .string) self.arg_live.open(name.string, @intCast(ix));
                } else if (std.mem.eql(u8, t.string, "content_block_delta")) {
                    const ix = sseIndex(obj) orelse return;
                    const d = obj.get("delta") orelse return;
                    if (d != .object) return;
                    const dt = d.object.get("type") orelse return;
                    if (dt != .string or !std.mem.eql(u8, dt.string, "input_json_delta")) return;
                    const pj = d.object.get("partial_json") orelse return;
                    if (pj == .string) self.arg_live.feed(self, @intCast(ix), pj.string);
                } else if (std.mem.eql(u8, t.string, "content_block_stop")) {
                    const ix = sseIndex(obj) orelse return;
                    self.arg_live.close(@intCast(ix));
                }
            },
            .openai => {
                const choices = obj.get("choices") orelse return;
                if (choices != .array or choices.array.items.len == 0) return;
                const c0 = choices.array.items[0];
                if (c0 != .object) return;
                const d = c0.object.get("delta") orelse return;
                if (d != .object) return;
                const tcs = d.object.get("tool_calls") orelse return;
                if (tcs != .array) return;
                for (tcs.array.items) |tc| {
                    if (tc != .object) continue;
                    const ix: i64 = if (tc.object.get("index")) |iv|
                        (if (iv == .integer) iv.integer else 0)
                    else
                        0;
                    const f = tc.object.get("function") orelse continue;
                    if (f != .object) continue;
                    if (f.object.get("name")) |n| if (n == .string and n.string.len > 0)
                        self.arg_live.open(n.string, ix);
                    if (f.object.get("arguments")) |a| if (a == .string)
                        self.arg_live.feed(self, ix, a.string);
                }
            },
            .responses => {
                const t = obj.get("type") orelse return;
                if (t != .string) return;
                if (std.mem.eql(u8, t.string, "response.output_item.added")) {
                    const ix = outputIndex(obj) orelse return;
                    const item = obj.get("item") orelse return;
                    if (item != .object) return;
                    const it = item.object.get("type") orelse return;
                    if (it != .string or !std.mem.eql(u8, it.string, "function_call")) return;
                    const name = item.object.get("name") orelse return;
                    if (name == .string) self.arg_live.open(name.string, ix);
                } else if (std.mem.eql(u8, t.string, "response.function_call_arguments.delta")) {
                    const ix = outputIndex(obj) orelse return;
                    const dl = obj.get("delta") orelse return;
                    if (dl == .string) self.arg_live.feed(self, ix, dl.string);
                } else if (std.mem.eql(u8, t.string, "response.output_item.done")) {
                    const ix = outputIndex(obj) orelse return;
                    self.arg_live.close(ix);
                }
            },
        }
    }

    /// Print live tool-argument text exactly like a text delta: clears the
    /// spinner, lands in the Esc-interrupt capture, and records which meta
    /// tool already showed its prose so handleMeta / sayToolUse don't repeat
    /// it after the call completes.
    fn emitArgText(self: *Agent, tool: ArgTool, text: []const u8) void {
        const w = self.out orelse return;
        if (text.len == 0) return;
        self.spinnerStop(); // first visible byte: clear the thinking line
        self.streamed_text = true;
        if (self.streamed_args != tool) self.streamed_args_len = 0;
        self.streamed_args = tool;
        self.streamed_args_len += text.len;
        self.partial_text.appendSlice(self.arena, text) catch {};
        if (use_color) {
            self.streamMarkdown(text);
        } else {
            w.writeAll(text) catch return;
            w.flush() catch return;
        }
    }

    /// True iff this meta call's prose already streamed live *in full*: the
    /// bytes ArgLive emitted match the parsed field exactly. Only then may
    /// the authoritative re-print be suppressed — a scanner glitch must cost
    /// duplication, never content.
    fn argStreamedFully(self: *Agent, call: ToolCall) bool {
        const at = argToolFor(call.name);
        if (at == .none or at != self.streamed_args) return false;
        const v = call.input.object.get(argField(at)) orelse return false;
        return v == .string and v.string.len == self.streamed_args_len;
    }

    /// Incremental streaming markdown: every delta byte either prints
    /// immediately or is held only as long as classification demands. Each
    /// line starts in .classify (md_buf accumulates the prefix); the moment
    /// the prefix proves what the line is, the buffered bytes are emitted
    /// with their styling and subsequent bytes stream straight through —
    /// prose and bullets/numbered items word-by-word with eager **bold** /
    /// `code` span styling, headers and fenced code styled-then-raw.
    /// Only genuinely whole-line constructs stay held to line end: fence
    /// toggles, tables, horizontal rules (and any still-ambiguous prefix).
    /// Well-formed markdown renders identically to renderMdLine; a span left
    /// unclosed at line end differs cosmetically (styled text, markers
    /// dropped) from renderMdLine's literal-marker fallback.
    fn streamMarkdown(self: *Agent, text: []const u8) void {
        const w = self.out orelse return;
        for (text) |b| self.mdByte(w, b);
        w.flush() catch {};
    }

    const MdKind = enum { classify, hold, prose, header, fenced };
    const MdSpan = enum { normal, star, bold, bold_star, code };

    fn mdByte(self: *Agent, w: *Io.Writer, b: u8) void {
        if (b == '\n') {
            // A swallowed line (table row joining the buffer) keeps its
            // newline too — the table renders with its own line breaks.
            if (self.mdFinishLine(w)) w.writeByte('\n') catch {};
            return;
        }
        switch (self.md_kind) {
            .classify => {
                self.md_buf.append(self.gpa, b) catch {};
                self.mdTryClassify(w);
            },
            .hold => self.md_buf.append(self.gpa, b) catch {},
            .prose => self.mdSpanByte(w, b),
            .header, .fenced => w.writeByte(b) catch {},
        }
    }

    /// Look at the held line prefix and commit to a line kind as soon as the
    /// bytes allow. Staying silent (returning with .classify) means "not
    /// decidable yet" — at most a few bytes for every construct.
    fn mdTryClassify(self: *Agent, w: *Io.Writer) void {
        const held = self.md_buf.items;
        var lead: usize = 0;
        while (lead < held.len and held[lead] == ' ') lead += 1;
        const body = held[lead..];
        if (body.len == 0) return; // only indentation so far

        // A buffered table ends at the first line that isn't another row —
        // render it before this line emits anything.
        if (self.md_table.items.len > 0 and body[0] != '|') self.flushTable(w);

        if (self.md_fence) {
            // Inside a fence the only special line is the ``` closer.
            const bt = countPrefix(body, '`');
            if (bt == body.len) {
                if (bt >= 3) self.md_kind = .hold; // closer: whole-line render
                return; // 1-2 backticks: could still become the closer
            }
            self.md_kind = .fenced; // body text: dim it and stream
            w.writeAll(style.dim) catch {};
            w.writeAll(held) catch {};
            self.md_buf.clearRetainingCapacity();
            return;
        }
        switch (body[0]) {
            '`' => {
                const bt = countPrefix(body, '`');
                if (bt >= 3) {
                    self.md_kind = .hold; // fence opener
                } else if (bt < body.len) {
                    self.mdStartProse(w); // inline code span
                } // else: 1-2 leading backticks, undecided
            },
            '#' => {
                const hn = countPrefix(body, '#');
                if (hn == body.len) return; // could still grow
                if (hn > 6 or body[hn] != ' ') {
                    self.mdStartProse(w);
                    return;
                }
                // Header. Mirror renderMdLine's left-trim: wait for the first
                // non-space byte of the title, then style and stream.
                var ns = hn + 1;
                while (ns < body.len and body[ns] == ' ') ns += 1;
                if (ns == body.len) return;
                self.md_kind = .header;
                w.print("{s}{s}{s}", .{ style.bold, style.cyan, body[ns..] }) catch {};
                self.md_buf.clearRetainingCapacity();
            },
            '|' => self.md_kind = .hold, // table row: cells need the whole line
            '-', '_', '*', '+' => {
                const run = countPrefix(body, body[0]);
                if (body[0] != '+' and run == body.len) return; // possible rule
                if ((body[0] == '-' or body[0] == '*' or body[0] == '+') and run == 1 and body.len >= 2 and body[1] == ' ') {
                    // Bullet: emit indent + styled marker, stream the rest.
                    self.md_kind = .prose;
                    self.md_span = .normal;
                    self.md_col = lead + 2; // "• " — wrapped lines align under the text
                    self.md_indent = lead + 2;
                    w.writeAll(held[0..lead]) catch {};
                    w.print("{s}•{s} ", .{ style.cyan, style.reset }) catch {};
                    const rest = body[2..];
                    self.md_buf.clearRetainingCapacity(); // before re-dispatch
                    var tmp: [8]u8 = undefined;
                    const n = @min(rest.len, tmp.len);
                    @memcpy(tmp[0..n], rest[0..n]);
                    for (tmp[0..n]) |rb| self.mdSpanByte(w, rb);
                    return;
                }
                if (body[0] == '+' and body.len == 1) return; // "+ " bullet still possible
                self.mdStartProse(w);
            },
            '0'...'9' => {
                var d: usize = 0;
                while (d < body.len and body[d] >= '0' and body[d] <= '9') d += 1;
                if (d == body.len) return; // all digits: could become "12. "
                if (body[d] == '.' or body[d] == ')') {
                    if (d + 1 == body.len) return; // "12." — needs one more byte
                    if (body[d + 1] == ' ') { // numbered item
                        self.md_kind = .prose;
                        self.md_span = .normal;
                        self.md_col = lead + d + 2; // "12. " — align under the text
                        self.md_indent = lead + d + 2;
                        w.writeAll(held[0..lead]) catch {};
                        w.print("{s}{s}.{s} ", .{ style.cyan, body[0..d], style.reset }) catch {};
                        const rest = body[d + 2 ..];
                        var tmp: [8]u8 = undefined;
                        const n = @min(rest.len, tmp.len);
                        @memcpy(tmp[0..n], rest[0..n]);
                        self.md_buf.clearRetainingCapacity();
                        for (tmp[0..n]) |rb| self.mdSpanByte(w, rb);
                        return;
                    }
                }
                self.mdStartProse(w);
            },
            else => self.mdStartProse(w),
        }
    }

    /// Commit to plain prose: replay the held prefix through the inline-span
    /// machine, then stream subsequent bytes directly.
    fn mdStartProse(self: *Agent, w: *Io.Writer) void {
        self.md_kind = .prose;
        self.md_span = .normal;
        var lead: usize = 0;
        while (lead < self.md_buf.items.len and self.md_buf.items[lead] == ' ') lead += 1;
        self.md_indent = lead; // wrapped lines keep the line's indentation
        for (self.md_buf.items) |b| self.mdSpanByte(w, b);
        self.md_buf.clearRetainingCapacity();
    }

    /// Streaming counterpart of renderInline: a left-to-right toggle machine
    /// for **bold** and `code` spans that styles eagerly — the opener turns
    /// styling on as soon as it's seen instead of waiting for the closer.
    /// Literal bytes route through mdWrapByte (terminal-width word wrap);
    /// style sequences through mdStyle (zero-width, ordered with the word).
    fn mdSpanByte(self: *Agent, w: *Io.Writer, b: u8) void {
        switch (self.md_span) {
            .normal => switch (b) {
                '*' => self.md_span = .star,
                '`' => {
                    self.mdStyle(w, style.yellow);
                    self.md_span = .code;
                },
                else => self.mdWrapByte(w, b),
            },
            .star => if (b == '*') {
                self.mdStyle(w, style.bold);
                self.md_span = .bold;
            } else {
                self.mdWrapByte(w, '*'); // lone star is literal
                self.md_span = .normal;
                self.mdSpanByte(w, b);
            },
            .bold => switch (b) {
                '*' => self.md_span = .bold_star,
                else => self.mdWrapByte(w, b),
            },
            .bold_star => if (b == '*') {
                self.mdStyle(w, style.reset);
                self.md_span = .normal;
            } else {
                self.mdWrapByte(w, '*');
                self.md_span = .bold;
                self.mdSpanByte(w, b);
            },
            .code => if (b == '`') {
                self.mdStyle(w, style.reset);
                self.md_span = .normal;
            } else self.mdWrapByte(w, b),
        }
    }

    /// Terminal-width word wrap for streamed prose. Literal bytes buffer
    /// into the current word; a space flushes it — and a word that would
    /// cross the terminal edge breaks the line first and continues under
    /// the hanging indent (set by the bullet/numbered/prose classifiers),
    /// instead of hard-wrapping at column 0 mid-word.
    fn mdWrapByte(self: *Agent, w: *Io.Writer, b: u8) void {
        if (b == ' ') {
            self.mdFlushWord(w);
            if (self.md_col < self.mdWidth()) {
                w.writeByte(' ') catch {};
                self.md_col += 1;
            } else if (self.md_col > self.md_indent) {
                self.mdWrapBreak(w); // line full: break instead of the space
            } // already at a fresh indent: swallow the space
            return;
        }
        self.md_word.append(self.gpa, b) catch {
            w.writeByte(b) catch {}; // can't buffer: degrade to direct write
            return;
        };
        if ((b & 0xC0) != 0x80) self.md_word_vis += 1; // UTF-8 leads only
    }

    /// Style sequences are zero-width but must stay ordered with the word
    /// they're inside of — buffer them with a pending word, else pass through.
    fn mdStyle(self: *Agent, w: *Io.Writer, s: []const u8) void {
        if (self.md_word.items.len > 0) {
            self.md_word.appendSlice(self.gpa, s) catch {};
        } else w.writeAll(s) catch {};
    }

    fn mdFlushWord(self: *Agent, w: *Io.Writer) void {
        if (self.md_word.items.len == 0) return;
        const vis = self.md_word_vis;
        const width = self.mdWidth();
        // Break before a word that would cross the edge — unless the line is
        // already fresh or the word can't fit any line (URLs: let the
        // terminal wrap it rather than shred it).
        if (self.md_col + vis > width and self.md_col > self.md_indent and self.md_indent + vis <= width)
            self.mdWrapBreak(w);
        w.writeAll(self.md_word.items) catch {};
        self.md_col += vis;
        self.md_word.clearRetainingCapacity();
        self.md_word_vis = 0;
    }

    fn mdWrapBreak(self: *Agent, w: *Io.Writer) void {
        w.writeByte('\n') catch {};
        for (0..self.md_indent) |_| w.writeByte(' ') catch {};
        self.md_col = self.md_indent;
    }

    fn mdWidth(self: *Agent) usize {
        if (self.md_width == 0) self.md_width = termCols();
        return self.md_width;
    }

    /// Settle the span machine at line end: pending markers print literally,
    /// open spans close their styling.
    fn mdSpanEnd(self: *Agent, w: *Io.Writer) void {
        self.mdFlushWord(w);
        switch (self.md_span) {
            .normal => {},
            .star => w.writeByte('*') catch {},
            .bold, .code => w.writeAll(style.reset) catch {},
            .bold_star => {
                w.writeByte('*') catch {};
                w.writeAll(style.reset) catch {};
            },
        }
        self.md_span = .normal;
    }

    /// End of line (newline or stream end): render anything still held,
    /// settle styling, and reset the per-line state. Returns false when the
    /// line was a table row swallowed into md_table — the caller then skips
    /// the newline; the table prints its own when it flushes.
    fn mdFinishLine(self: *Agent, w: *Io.Writer) bool {
        switch (self.md_kind) {
            // Still held: a whole-line construct or a prefix too short to
            // classify — renderMdLine does exactly the right thing (and
            // toggles md_fence for fence lines).
            .classify, .hold => {
                const line = self.md_buf.items;
                var lead: usize = 0;
                while (lead < line.len and line[lead] == ' ') lead += 1;
                if (!self.md_fence and lead < line.len and line[lead] == '|') {
                    // Table row: buffer it — columns can only align once the
                    // whole table is known.
                    if (self.gpa.dupe(u8, line[lead..])) |dup| {
                        self.md_table.append(self.gpa, dup) catch self.gpa.free(dup);
                        self.md_buf.clearRetainingCapacity();
                        self.md_kind = .classify;
                        self.md_span = .normal;
                        return false;
                    } else |_| {}
                }
                if (self.md_table.items.len > 0) self.flushTable(w);
                self.renderMdLine(w, line);
            },
            .prose => self.mdSpanEnd(w),
            .header, .fenced => w.writeAll(style.reset) catch {},
        }
        self.md_buf.clearRetainingCapacity();
        self.md_kind = .classify;
        self.md_span = .normal;
        self.md_col = 0;
        self.md_indent = 0;
        self.md_width = 0; // re-read the terminal width next line (resizes)
        return true;
    }

    fn countPrefix(s: []const u8, c: u8) usize {
        var i: usize = 0;
        while (i < s.len and s[i] == c) i += 1;
        return i;
    }

    /// Render the buffered table rows as aligned columns: widths from the
    /// widest visible cell, bold header above a dim ─┼─ rule, cells styled
    /// via renderInline. The one place streaming defers whole blocks —
    /// alignment is impossible row-by-row.
    fn flushTable(self: *Agent, w: *Io.Writer) void {
        const gpa = self.gpa;
        defer {
            for (self.md_table.items) |r| gpa.free(r);
            self.md_table.clearRetainingCapacity();
        }
        // Split rows into trimmed cells (slices into the row strings),
        // dropping the empty edges of leading/trailing '|'.
        var cells: std.ArrayList([]const []const u8) = .empty;
        defer {
            for (cells.items) |cr| gpa.free(cr);
            cells.deinit(gpa);
        }
        var header_rows: ?usize = null; // rows above the first separator
        var ncols: usize = 0;
        for (self.md_table.items) |row| {
            const body = std.mem.trim(u8, row, " ");
            if (isTableSeparator(body)) {
                if (header_rows == null and cells.items.len > 0) header_rows = cells.items.len;
                continue;
            }
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, body, '|');
            var first = true;
            while (it.next()) |cell| {
                defer first = false;
                if (first and cell.len == 0) continue;
                list.append(gpa, std.mem.trim(u8, cell, " ")) catch {};
            }
            while (list.items.len > 0 and list.items[list.items.len - 1].len == 0)
                _ = list.pop();
            ncols = @max(ncols, list.items.len);
            const owned = list.toOwnedSlice(gpa) catch blk: {
                list.deinit(gpa);
                break :blk &.{};
            };
            cells.append(gpa, owned) catch gpa.free(owned);
        }
        if (ncols == 0 or cells.items.len == 0) return;
        const widths = gpa.alloc(usize, ncols) catch return;
        defer gpa.free(widths);
        @memset(widths, 0);
        for (cells.items) |cr| for (cr, 0..) |c, i| {
            widths[i] = @max(widths[i], inlineVisibleLen(c));
        };
        // Cap the grid to the terminal: a column wider than the screen used
        // to hard-wrap at the terminal edge and shred the alignment. Shrink
        // the widest columns until the table fits, then word-wrap each cell
        // into its column — continuation lines keep the │ rails straight.
        fitWidths(widths, termCols() -| (3 * (ncols - 1)));
        const wraps = gpa.alloc(std.ArrayList([]const u8), ncols) catch return;
        defer gpa.free(wraps);
        for (cells.items, 0..) |cr, ri| {
            const head = header_rows != null and ri < header_rows.?;
            var nlines: usize = 1;
            for (0..ncols) |ci| {
                wraps[ci] = .empty;
                wrapCell(gpa, if (ci < cr.len) cr[ci] else "", widths[ci], &wraps[ci]);
                nlines = @max(nlines, wraps[ci].items.len);
            }
            defer for (wraps) |*l| l.deinit(gpa);
            for (0..nlines) |li| {
                for (0..ncols) |ci| {
                    const c = if (li < wraps[ci].items.len) wraps[ci].items[li] else "";
                    if (ci > 0) w.print("{s} │ {s}", .{ style.dim, style.reset }) catch {};
                    if (head) w.writeAll(style.bold) catch {};
                    renderInline(w, c);
                    if (head) w.writeAll(style.reset) catch {};
                    if (ci + 1 < ncols) {
                        var pad = widths[ci] -| inlineVisibleLen(c);
                        while (pad > 0) : (pad -= 1) w.writeByte(' ') catch {};
                    }
                }
                w.writeByte('\n') catch {};
            }
            if (header_rows != null and ri + 1 == header_rows.?) {
                w.writeAll(style.dim) catch {};
                for (0..ncols) |ci| {
                    if (ci > 0) w.writeAll("─┼─") catch {};
                    for (0..widths[ci]) |_| w.writeAll("─") catch {};
                }
                w.writeAll(style.reset) catch {};
                w.writeByte('\n') catch {};
            }
        }
    }

    /// Shrink the widest columns one cell at a time until the grid fits in
    /// `avail` visible columns, never below a readable floor. If the screen
    /// can't even hold the floor for every column, leave the widths alone —
    /// a torn render beats an unreadable one.
    fn fitWidths(widths: []usize, avail: usize) void {
        const min_w: usize = 8;
        if (avail < widths.len * min_w) return;
        var total: usize = 0;
        for (widths) |x| total += x;
        while (total > avail) {
            var wi: usize = 0;
            for (widths, 0..) |x, k| {
                if (x > widths[wi]) wi = k;
            }
            if (widths[wi] <= min_w) break;
            widths[wi] -= 1;
            total -= 1;
        }
    }

    /// One wrappable unit of a table cell: a maximal run of non-space bytes,
    /// where a **bold**/`code` span is atomic (spaces inside don't split it),
    /// so wrapping never tears a styled span apart.
    fn atomEnd(s: []const u8, start: usize) usize {
        var i = start;
        while (i < s.len) {
            if (s[i] == ' ') return i;
            if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
                if (std.mem.indexOfPos(u8, s, i + 2, "**")) |e| {
                    i = e + 2;
                    continue;
                }
            }
            if (s[i] == '`') {
                if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |e| {
                    i = e + 1;
                    continue;
                }
            }
            i += 1;
        }
        return s.len;
    }

    /// Greedy word-wrap of one table cell to a visible-width budget,
    /// appending slices of `cell` to `out` (one per rendered line). Atoms
    /// wider than the budget hard-split by codepoint. Always yields at least
    /// one (possibly empty) line.
    fn wrapCell(gpa: Allocator, cell: []const u8, width: usize, out: *std.ArrayList([]const u8)) void {
        const budget = @max(width, 1);
        var ls: usize = 0; // current line: first atom byte…
        var le: usize = 0; // …through end of its last atom
        var lv: usize = 0; // and its visible width
        var i: usize = 0;
        while (i < cell.len) {
            while (i < cell.len and cell[i] == ' ') i += 1;
            if (i >= cell.len) break;
            const ae = atomEnd(cell, i);
            const av = inlineVisibleLen(cell[i..ae]);
            if (lv > 0 and lv + 1 + av > budget) {
                out.append(gpa, cell[ls..le]) catch return;
                lv = 0;
            }
            if (lv == 0 and av > budget) { // oversized atom: hard-split
                var j = i;
                var v: usize = 0;
                while (j < ae and v < budget) {
                    j += std.unicode.utf8ByteSequenceLength(cell[j]) catch 1;
                    v += 1;
                }
                out.append(gpa, cell[i..j]) catch return;
                i = j;
                continue;
            }
            if (lv == 0) ls = i else lv += 1; // joining space
            lv += av;
            le = ae;
            i = ae;
        }
        if (lv > 0) out.append(gpa, cell[ls..le]) catch return;
        if (out.items.len == 0) out.append(gpa, "") catch {};
    }

    /// Columns a cell occupies once rendered: matched **bold**/`code` markers
    /// drop, and multi-byte UTF-8 sequences count as one column (wide CJK
    /// glyphs are approximated as one).
    fn inlineVisibleLen(s: []const u8) usize {
        var i: usize = 0;
        var n: usize = 0;
        while (i < s.len) {
            if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
                if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
                    n += codepointCount(s[i + 2 .. end]);
                    i = end + 2;
                    continue;
                }
            }
            if (s[i] == '`') {
                if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                    n += codepointCount(s[i + 1 .. end]);
                    i = end + 1;
                    continue;
                }
            }
            if ((s[i] & 0xC0) != 0x80) n += 1;
            i += 1;
        }
        return n;
    }

    fn codepointCount(s: []const u8) usize {
        var n: usize = 0;
        for (s) |b| {
            if ((b & 0xC0) != 0x80) n += 1;
        }
        return n;
    }

    /// Flush the trailing partial line at stream end (no forced newline — the
    /// caller adds the separating newline), and reset fence state.
    fn flushStreamTail(self: *Agent) void {
        const w = self.out orelse return;
        _ = self.mdFinishLine(w); // may swallow a final table row…
        if (self.md_table.items.len > 0) self.flushTable(w); // …then render it
        w.flush() catch {};
        self.md_fence = false;
    }

    /// Render one markdown line to ANSI (portable SGR only — bold/color, no
    /// italic, so iTerm/Ghostty/Terminal/Windows-Terminal all agree): code
    /// fences + fenced bodies dimmed, ATX headers bold-cyan, `-`/`*`/`+`
    /// bullets → cyan •, and inline `**bold**` / `` `code` `` spans.
    fn renderMdLine(self: *Agent, w: *Io.Writer, line: []const u8) void {
        var lead: usize = 0;
        while (lead < line.len and line[lead] == ' ') lead += 1;
        const body = line[lead..];
        if (std.mem.startsWith(u8, body, "```")) {
            self.md_fence = !self.md_fence;
            // Fence lines render as a dim rule — "── zig ────…" opening with
            // the language label when given, plain "────…" otherwise —
            // instead of raw backticks. Body lines stay unprefixed so code
            // copies cleanly out of the terminal.
            const lang = std.mem.trim(u8, body[3..], " `");
            w.writeAll(style.dim) catch {};
            var used: usize = 0;
            if (self.md_fence and lang.len > 0) {
                w.print("── {s} ", .{lang}) catch {};
                used = 4 + codepointCount(lang); // "── " + label + " "
            }
            while (used < 40) : (used += 1) w.writeAll("─") catch {};
            w.writeAll(style.reset) catch {};
            return;
        }
        if (self.md_fence) {
            w.print("{s}{s}{s}", .{ style.dim, line, style.reset }) catch {};
            return;
        }
        // ATX header: 1-6 '#' then a space.
        var h: usize = 0;
        while (h < body.len and body[h] == '#') h += 1;
        if (h >= 1 and h <= 6 and h < body.len and body[h] == ' ') {
            const head = std.mem.trim(u8, body[h + 1 ..], " ");
            w.print("{s}{s}{s}{s}", .{ style.bold, style.cyan, head, style.reset }) catch {};
            return;
        }
        // Horizontal rule: a line of only -, *, or _ (3+).
        if (body.len >= 3 and isRule(body)) {
            w.print("{s}────────────{s}", .{ style.dim, style.reset }) catch {};
            return;
        }
        // Table row (GFM): starts with '|'. Separator row → dim rule; data row
        // → cells joined by a dim │, each rendered inline.
        if (body.len > 0 and body[0] == '|') {
            if (isTableSeparator(body)) {
                w.print("{s}────────────{s}", .{ style.dim, style.reset }) catch {};
                return;
            }
            var cells = std.mem.splitScalar(u8, body, '|');
            var first = true;
            while (cells.next()) |cell| {
                const c = std.mem.trim(u8, cell, " ");
                if (c.len == 0) continue;
                if (!first) w.print("{s} │ {s}", .{ style.dim, style.reset }) catch {};
                first = false;
                renderInline(w, c);
            }
            return;
        }
        // Bullet list item.
        if (std.mem.startsWith(u8, body, "- ") or std.mem.startsWith(u8, body, "* ") or std.mem.startsWith(u8, body, "+ ")) {
            w.writeAll(line[0..lead]) catch {};
            w.print("{s}•{s} ", .{ style.cyan, style.reset }) catch {};
            renderInline(w, body[2..]);
            return;
        }
        // Numbered list: digits then '.' or ')' then a space.
        var d: usize = 0;
        while (d < body.len and body[d] >= '0' and body[d] <= '9') d += 1;
        if (d >= 1 and d + 1 < body.len and (body[d] == '.' or body[d] == ')') and body[d + 1] == ' ') {
            w.writeAll(line[0..lead]) catch {};
            w.print("{s}{s}.{s} ", .{ style.cyan, body[0..d], style.reset }) catch {};
            renderInline(w, body[d + 2 ..]);
            return;
        }
        renderInline(w, line);
    }

    /// True if every char is one of '-', '*', '_' (markdown thematic break).
    fn isRule(body: []const u8) bool {
        const c0 = body[0];
        if (c0 != '-' and c0 != '*' and c0 != '_') return false;
        for (body) |c| if (c != c0) return false;
        return true;
    }

    /// True if a `|`-delimited row contains only separator chars (-, :, space).
    fn isTableSeparator(body: []const u8) bool {
        var any_dash = false;
        for (body) |c| switch (c) {
            '|', ' ', ':' => {},
            '-' => any_dash = true,
            else => return false,
        };
        return any_dash;
    }

    /// Emit a line with inline `**bold**` and `` `code` `` spans styled; the
    /// markers themselves are dropped. Unmatched markers print literally.
    fn renderInline(w: *Io.Writer, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
                if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
                    w.print("{s}{s}{s}", .{ style.bold, s[i + 2 .. end], style.reset }) catch {};
                    i = end + 2;
                    continue;
                }
            }
            if (s[i] == '`') {
                if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                    w.print("{s}{s}{s}", .{ style.yellow, s[i + 1 .. end], style.reset }) catch {};
                    i = end + 1;
                    continue;
                }
            }
            w.writeByte(s[i]) catch {};
            i += 1;
        }
    }

    /// Reassemble a streamed SSE body into the non-streaming response shape
    /// the step functions expect. Returns null when the body contains no SSE
    /// events (a plain JSON body — error envelope, or a provider that
    /// ignored `stream`); the caller falls back to regular parsing.
    fn assembleStream(self: *Agent, body: []const u8) !?std.json.ObjectMap {
        return switch (self.provider.kind) {
            .anthropic => self.assembleAnthropic(body),
            .openai => self.assembleOpenAI(body),
            .responses => unreachable, // parseResponses owns this path
        };
    }

    /// One in-flight content block while reassembling an Anthropic stream.
    const BlockAcc = struct {
        obj: std.json.ObjectMap = .empty,
        text: std.ArrayList(u8) = .empty,
        json: std.ArrayList(u8) = .empty,
        thinking: std.ArrayList(u8) = .empty,
        signature: std.ArrayList(u8) = .empty,
    };

    /// message_start carries the message skeleton (role, model, input-token
    /// usage); content blocks open with content_block_start and accumulate
    /// via content_block_delta (text / partial_json / thinking / signature);
    /// message_delta carries stop_reason and output-token usage.
    fn assembleAnthropic(self: *Agent, body: []const u8) !?std.json.ObjectMap {
        var root: ?std.json.ObjectMap = null;
        var blocks: std.ArrayList(BlockAcc) = .empty;
        var stop_reason: ?Value = null;
        var usage_delta: ?Value = null;
        var it = std.mem.tokenizeScalar(u8, body, '\n');
        while (it.next()) |raw_line| {
            const payload = ssePayload(raw_line) orelse continue;
            const v = std.json.parseFromSliceLeaky(Value, self.arena, payload, .{ .allocate = .alloc_always }) catch continue;
            if (v != .object) continue;
            const t = v.object.get("type") orelse continue;
            if (t != .string) continue;
            if (std.mem.eql(u8, t.string, "message_start")) {
                if (v.object.get("message")) |m| if (m == .object) {
                    root = m.object;
                };
            } else if (std.mem.eql(u8, t.string, "content_block_start")) {
                const idx = sseIndex(v.object) orelse continue;
                while (blocks.items.len <= idx) try blocks.append(self.arena, .{});
                if (v.object.get("content_block")) |cb| if (cb == .object) {
                    blocks.items[idx].obj = cb.object;
                };
            } else if (std.mem.eql(u8, t.string, "content_block_delta")) {
                const idx = sseIndex(v.object) orelse continue;
                if (idx >= blocks.items.len) continue;
                const d = v.object.get("delta") orelse continue;
                if (d != .object) continue;
                const b = &blocks.items[idx];
                if (d.object.get("text")) |x| if (x == .string) try b.text.appendSlice(self.arena, x.string);
                if (d.object.get("partial_json")) |x| if (x == .string) try b.json.appendSlice(self.arena, x.string);
                if (d.object.get("thinking")) |x| if (x == .string) try b.thinking.appendSlice(self.arena, x.string);
                if (d.object.get("signature")) |x| if (x == .string) try b.signature.appendSlice(self.arena, x.string);
            } else if (std.mem.eql(u8, t.string, "message_delta")) {
                if (v.object.get("delta")) |d| if (d == .object) {
                    if (d.object.get("stop_reason")) |sr| if (sr == .string) {
                        stop_reason = sr;
                    };
                };
                if (v.object.get("usage")) |u| if (u == .object) {
                    usage_delta = u;
                };
            } else if (std.mem.eql(u8, t.string, "error")) {
                // Hand the envelope back as the root: request()'s existing
                // type=="error" check reports it.
                return v.object;
            }
        }
        var r = root orelse return null;
        var content = std.json.Array.init(self.arena);
        for (blocks.items) |*b| {
            if (b.obj.get("type") == null) continue; // never started
            if (b.text.items.len > 0) try b.obj.put(self.arena, "text", .{ .string = b.text.items });
            if (b.thinking.items.len > 0) try b.obj.put(self.arena, "thinking", .{ .string = b.thinking.items });
            if (b.signature.items.len > 0) try b.obj.put(self.arena, "signature", .{ .string = b.signature.items });
            if (b.json.items.len > 0) {
                const input = std.json.parseFromSliceLeaky(Value, self.arena, b.json.items, .{ .allocate = .alloc_always }) catch Value{ .object = .empty };
                try b.obj.put(self.arena, "input", input);
            }
            try content.append(.{ .object = b.obj });
        }
        try r.put(self.arena, "content", .{ .array = content });
        try r.put(self.arena, "stop_reason", stop_reason orelse Value{ .string = "end_turn" });
        if (usage_delta) |ud| {
            var usage: std.json.ObjectMap = .empty;
            if (r.get("usage")) |base| if (base == .object) {
                var e = base.object.iterator();
                while (e.next()) |kv| try usage.put(self.arena, kv.key_ptr.*, kv.value_ptr.*);
            };
            var e = ud.object.iterator();
            while (e.next()) |kv| try usage.put(self.arena, kv.key_ptr.*, kv.value_ptr.*);
            try r.put(self.arena, "usage", .{ .object = usage });
        }
        return r;
    }

    /// One in-flight tool call while reassembling an OpenAI chat stream;
    /// id and function.name arrive on the first fragment, arguments
    /// accumulate across fragments keyed by index.
    const CallAcc = struct {
        id: []const u8 = "",
        name: []const u8 = "",
        args: std.ArrayList(u8) = .empty,
    };

    fn assembleOpenAI(self: *Agent, body: []const u8) !?std.json.ObjectMap {
        var content: std.ArrayList(u8) = .empty;
        var reasoning_content: std.ArrayList(u8) = .empty;
        var reasoning: std.ArrayList(u8) = .empty;
        var calls: std.ArrayList(CallAcc) = .empty;
        var role: []const u8 = "assistant";
        var finish: ?Value = null;
        var usage: ?Value = null;
        var saw_chunk = false;
        var it = std.mem.tokenizeScalar(u8, body, '\n');
        while (it.next()) |raw_line| {
            const payload = ssePayload(raw_line) orelse continue;
            const v = std.json.parseFromSliceLeaky(Value, self.arena, payload, .{ .allocate = .alloc_always }) catch continue;
            if (v != .object) continue;
            // The final usage chunk (stream_options.include_usage) may have
            // an empty choices array.
            if (v.object.get("usage")) |u| if (u == .object) {
                usage = u;
                saw_chunk = true;
            };
            const choices = v.object.get("choices") orelse continue;
            if (choices != .array or choices.array.items.len == 0) continue;
            const c0 = choices.array.items[0];
            if (c0 != .object) continue;
            saw_chunk = true;
            if (c0.object.get("finish_reason")) |fr| if (fr == .string) {
                finish = fr;
            };
            const d = c0.object.get("delta") orelse continue;
            if (d != .object) continue;
            if (d.object.get("role")) |x| if (x == .string) {
                role = x.string;
            };
            if (d.object.get("content")) |x| if (x == .string) try content.appendSlice(self.arena, x.string);
            if (d.object.get("reasoning_content")) |x| if (x == .string) try reasoning_content.appendSlice(self.arena, x.string);
            if (d.object.get("reasoning")) |x| if (x == .string) try reasoning.appendSlice(self.arena, x.string);
            if (d.object.get("tool_calls")) |tcs| if (tcs == .array) {
                for (tcs.array.items) |tc| {
                    if (tc != .object) continue;
                    const idx: usize = blk: {
                        if (tc.object.get("index")) |ix| if (ix == .integer and ix.integer >= 0) break :blk @intCast(ix.integer);
                        // No index: a fresh id opens a new call, otherwise
                        // the fragment continues the latest one.
                        break :blk if (tc.object.get("id") != null or calls.items.len == 0) calls.items.len else calls.items.len - 1;
                    };
                    while (calls.items.len <= idx) try calls.append(self.arena, .{});
                    const acc = &calls.items[idx];
                    if (tc.object.get("id")) |x| if (x == .string and x.string.len > 0) {
                        acc.id = x.string;
                    };
                    if (tc.object.get("function")) |f| if (f == .object) {
                        if (f.object.get("name")) |x| if (x == .string and x.string.len > 0) {
                            acc.name = x.string;
                        };
                        if (f.object.get("arguments")) |x| if (x == .string) try acc.args.appendSlice(self.arena, x.string);
                    };
                }
            };
        }
        if (!saw_chunk) return null;

        var message: std.json.ObjectMap = .empty;
        try message.put(self.arena, "role", .{ .string = role });
        try message.put(self.arena, "content", if (content.items.len > 0) Value{ .string = content.items } else .null);
        if (reasoning_content.items.len > 0) try message.put(self.arena, "reasoning_content", .{ .string = reasoning_content.items });
        if (reasoning.items.len > 0) try message.put(self.arena, "reasoning", .{ .string = reasoning.items });
        if (calls.items.len > 0) {
            var tcs = std.json.Array.init(self.arena);
            for (calls.items) |c| {
                if (c.id.len == 0 and c.name.len == 0) continue;
                var function: std.json.ObjectMap = .empty;
                try function.put(self.arena, "name", .{ .string = c.name });
                try function.put(self.arena, "arguments", .{ .string = c.args.items });
                var tc: std.json.ObjectMap = .empty;
                try tc.put(self.arena, "id", .{ .string = c.id });
                try tc.put(self.arena, "type", .{ .string = "function" });
                try tc.put(self.arena, "function", .{ .object = function });
                try tcs.append(.{ .object = tc });
            }
            if (tcs.items.len > 0) try message.put(self.arena, "tool_calls", .{ .array = tcs });
        }
        var choice: std.json.ObjectMap = .empty;
        try choice.put(self.arena, "message", .{ .object = message });
        try choice.put(self.arena, "finish_reason", finish orelse Value{ .string = "stop" });
        var choices = std.json.Array.init(self.arena);
        try choices.append(.{ .object = choice });
        var r: std.json.ObjectMap = .empty;
        try r.put(self.arena, "choices", .{ .array = choices });
        if (usage) |u| try r.put(self.arena, "usage", u);
        return r;
    }
};

// Wire-format message construction + UTF-8/history normalization live in
// messages.zig (600-line goal). Aliased back so call sites stay unqualified;
// imported as messages_mod to avoid shadowing the `messages` params/fields.
const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;
const toolResultMessage = messages_mod.toolResultMessage;
const sanitizeMessagesUtf8 = messages_mod.sanitizeMessagesUtf8;
const normalizeResponsesHistory = messages_mod.normalizeResponsesHistory;
const normalizeOpenAIHistory = messages_mod.normalizeOpenAIHistory;

/// A base64-encoded image staged by `/image`, sent with the next user turn.
// Image/vision support (staged-image type, per-provider vision check, image
// message builder, /image·/paste stagers, macOS clipboard grab) lives in
// vision.zig (600-line goal). Public surface aliased back.
const vision = @import("vision.zig");
const PendingImage = vision.PendingImage;
const visionModel = vision.visionModel;
const visionCapable = vision.visionCapable;
const imageMediaType = vision.imageMediaType;
const imageMessage = vision.imageMessage;
const StageResult = vision.StageResult;
const stageImagePath = vision.stageImagePath;
const stageGuiImageAttachment = vision.stageGuiImageAttachment;
const grabClipboardImage = vision.grabClipboardImage;
/// Auth + provider-specific headers shared by post() and Agent.postStream().
/// User-Agent for an outbound provider call. The Kimi for Coding plan gates
/// access to recognized coding-agent clients by User-Agent (a graff/* or bare
/// UA gets `access_terminated`), so graff identifies as one — a user's Kimi
/// Code key then works here the same as in Kimi CLI or Claude Code. Every
/// other provider keeps the http client default.
pub const kimi_user_agent = "claude-code/1.0.0";
// HTTP transport (auth headers, raw POST, 5xx-body capture, request watchdogs)
// lives in http.zig (600-line goal). Aliased back so Agent's model-call and
// streaming select-arms stay unqualified.
const http = @import("http.zig");
const providerUserAgent = http.providerUserAgent;
const providerHeaders = http.providerHeaders;
const capture5xxBodyStream = http.capture5xxBodyStream;
const WatchdogFired = http.WatchdogFired;
const RetryPlan = http.RetryPlan;
const sendHeadTask = http.sendHeadTask;
const streamLineTask = http.streamLineTask;
const streamStallTask = http.streamStallTask;
const headStallTask = http.headStallTask;
const postWatched = http.postWatched;

pub const ToolOutput = struct {
    text: []u8 = &.{}, // gpa-owned
    is_error: bool = false,
    ms: i64 = 0, // set by execTool
};

/// Everything a tool executor may touch from a pool thread. All fields are
/// thread-safe (gpa, io, shared http client, mutex-guarded registry and
/// approvals) or read-only.
/// One pre-edit file snapshot, tagged with the turn that's about to modify it.
/// `before == null` means the file didn't exist (rewind deletes it).
const Snapshot = struct { turn: u32, path: []const u8, before: ?[]const u8 };

/// Per-session record of file mutations (write_file/edit_file), so `/rewind`
/// can restore the working tree to an earlier turn. Mutex-guarded — tools run
/// on the pool concurrently. Bash edits are NOT tracked.
const Snapshots = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    list: std.ArrayList(Snapshot) = .empty,
    turn: u32 = 0, // the turn currently executing (set by the REPL loop)

    /// Record a file's pre-modification content (called before the write).
    fn record(self: *Snapshots, path: []const u8, before: ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const p = self.gpa.dupe(u8, path) catch return;
        const b: ?[]const u8 = if (before) |x| (self.gpa.dupe(u8, x) catch {
            self.gpa.free(p);
            return;
        }) else null;
        self.list.append(self.gpa, .{ .turn = self.turn, .path = p, .before = b }) catch {
            self.gpa.free(p);
            if (b) |bb| self.gpa.free(bb);
        };
    }

    /// Restore every file modified at turn ≥ n to its state before turn n, then
    /// drop those snapshots. Returns the number of files restored.
    fn restore(self: *Snapshots, n: u32) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var done: std.ArrayList([]const u8) = .empty;
        defer done.deinit(self.gpa);
        var restored: usize = 0;
        for (self.list.items) |snap| {
            if (snap.turn < n) continue;
            var seen = false;
            for (done.items) |d| if (std.mem.eql(u8, d, snap.path)) {
                seen = true;
            };
            if (seen) continue; // earliest snapshot per path wins (= state before turn n)
            done.append(self.gpa, snap.path) catch {};
            if (snap.before) |b| {
                Io.Dir.cwd().writeFile(self.io, .{ .sub_path = snap.path, .data = b }) catch continue;
            } else {
                Io.Dir.cwd().deleteFile(self.io, snap.path) catch {};
            }
            restored += 1;
        }
        // Drop (and free) snapshots from the rewound turns.
        var i: usize = 0;
        while (i < self.list.items.len) {
            if (self.list.items[i].turn >= n) {
                const s = self.list.orderedRemove(i);
                self.gpa.free(s.path);
                if (s.before) |b| self.gpa.free(b);
            } else i += 1;
        }
        return restored;
    }

    fn deinit(self: *Snapshots) void {
        for (self.list.items) |s| {
            self.gpa.free(s.path);
            if (s.before) |b| self.gpa.free(b);
        }
        self.list.deinit(self.gpa);
    }
};

const ToolCtx = struct {
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    provider: Provider,
    registry: ?*mcp.Registry,
    from_sub: bool,
    approvals: ?*Approvals,
    tracer: ?*Tracer,
    snapshots: ?*Snapshots = null,
    tools_used: ?*ToolSink = null, // the calling agent's tool log (trajectory/process mining)
};

/// Event JSON for a tool lifecycle hook: {"event","tool","input"[,
/// "is_error","output"]} — written to the hook's stdin. gpa-owned.
fn hookPayload(gpa: Allocator, event: []const u8, call: ToolCall, output: ?*const ToolOutput) ?[]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    const built = blk: {
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.beginObject() catch break :blk false;
        s.objectField("event") catch break :blk false;
        s.write(event) catch break :blk false;
        s.objectField("tool") catch break :blk false;
        s.write(call.name) catch break :blk false;
        s.objectField("input") catch break :blk false;
        s.write(call.input) catch break :blk false;
        if (output) |o| {
            // Cap the echoed output and keep the cut on a UTF-8 boundary so
            // the JSON stays valid.
            var t = o.text[0..@min(o.text.len, 4096)];
            var strips: usize = 0;
            while (strips < 3 and t.len > 0 and !std.unicode.utf8ValidateSlice(t)) : (strips += 1) t = t[0 .. t.len - 1];
            if (!std.unicode.utf8ValidateSlice(t)) t = "";
            s.objectField("is_error") catch break :blk false;
            s.write(o.is_error) catch break :blk false;
            s.objectField("output") catch break :blk false;
            s.write(t) catch break :blk false;
        }
        s.endObject() catch break :blk false;
        break :blk true;
    };
    if (!built) {
        aw.deinit();
        return null;
    }
    return aw.toOwnedSlice() catch {
        aw.deinit();
        return null;
    };
}

/// pre_tool hooks: first matching hook that exits 2 blocks the call; its
/// stderr becomes the tool result the model sees. Timeouts and other exit
/// codes allow — a broken hook must never brick the loop.
fn hookGate(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    if (g_hooks.pre_tool.len == 0) return null;
    const payload = hookPayload(ctx.gpa, "pre_tool", call, null) orelse return null;
    defer ctx.gpa.free(payload);
    for (g_hooks.pre_tool) |h| {
        if (!h.matches(call.name)) continue;
        const res = hooks.runHookCmd(ctx.gpa, ctx.io, h.command, payload, h.timeout_ms);
        defer if (res.stderr.len > 0) ctx.gpa.free(res.stderr);
        if (res.code) |c| if (c == 2) {
            const msg: []const u8 = if (res.stderr.len > 0) res.stderr else "denied by hook";
            const text = std.fmt.allocPrint(ctx.gpa, "blocked by pre_tool hook: {s}", .{msg}) catch
                return .{ .text = &.{}, .is_error = true };
            return .{ .text = text, .is_error = true };
        };
    }
    return null;
}

/// post_tool hooks: best-effort, sequential (a formatter should finish
/// before the next tool runs), exit codes ignored.
fn runPostToolHooks(ctx: ToolCtx, call: ToolCall, out: ToolOutput) void {
    if (g_hooks.post_tool.len == 0) return;
    const payload = hookPayload(ctx.gpa, "post_tool", call, &out) orelse return;
    defer ctx.gpa.free(payload);
    for (g_hooks.post_tool) |h| {
        if (!h.matches(call.name)) continue;
        const res = hooks.runHookCmd(ctx.gpa, ctx.io, h.command, payload, h.timeout_ms);
        if (res.stderr.len > 0) ctx.gpa.free(res.stderr);
    }
}

/// Built-in pre_tool guard for issue #626. Blocks a bash command that scans or
/// reads a *concrete source file* (`grep`/`sed`/`cat`/… on a path ending in a
/// known code extension) and redirects the model to the codedb tool, whose
/// structural queries (symbol/callers/deps/outline/context) otherwise go
/// unused. Narrow on purpose: only known scan/read utilities, only a concrete
/// source path (globs like `*.zig` are left alone), only when `codedb` is on
/// PATH (else the model would be stuck between a blocked grep and no tool), and
/// never when GRAFF_NO_CODEDB_GUARD is set. A block returns is_error so the
/// model adapts — same contract as a pre_tool hook's exit 2.
fn codedbGuard(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    if (!g_codedb_guard) return null;
    if (!std.mem.eql(u8, call.name, "bash")) return null;
    const cmd = strField(call.input, "command") orelse return null;

    // First word must be a code scan/read utility (basename, so /usr/bin/grep
    // counts; sudo/env prefixes are intentionally not unwrapped).
    const trimmed = std.mem.trim(u8, cmd, " \t");
    const word_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const tool = std.fs.path.basename(trimmed[0..word_end]);
    const scanners = [_][]const u8{
        "grep", "egrep",  "fgrep", "rg",   "ripgrep", "ag", "ack",
        "sed",  "awk",    "cat",   "head", "tail",    "wc", "nl",
        "bat",  "batcat",
    };
    var is_scanner = false;
    for (scanners) |s| if (std.mem.eql(u8, s, tool)) {
        is_scanner = true;
    };
    if (!is_scanner) return null;

    // …aimed at a concrete source file (not a glob — codedb glob/tree cover that).
    const src_path = extractSourceFilePath(cmd) orelse return null;

    // Only redirect when codedb is actually installed (cache the PATH lookup).
    if (g_codedb_present == null) g_codedb_present = binOnPath(ctx.io, "codedb");
    if (g_codedb_present != true) return null;

    // Only redirect when codedb actually indexed this file. Large files
    // (e.g. a 13K-line main.zig) are silently skipped by codedb; blocking
    // bash grep on them traps the agent between a blocked grep and an empty
    // codedb result. Let bash through for un-indexed files (issue #54).
    if (!codedbFileIndexed(ctx.io, ctx.gpa, src_path)) return null;

    const msg = std.fmt.allocPrint(ctx.gpa, "blocked: this repo is codedb-indexed — don't shell out to `{s}` to read or search source. Use the codedb tool (indexed + structural): search <query> · symbol <name> [--body] · callers <name> · deps <path> · outline <path> · read <path> · context <task>. If you genuinely need raw bash here, set GRAFF_NO_CODEDB_GUARD=1.", .{tool}) catch return .{ .text = &.{}, .is_error = true };
    return .{ .text = msg, .is_error = true };
}

/// Extract the first concrete source file path from a bash command (after
/// the command word). Returns null for globs or non-source tokens. Used by
/// the codedb guard to check whether the target file is actually indexed
/// before redirecting bash to codedb — a file codedb skipped (too large)
/// must be allowed through bash, or the agent is trapped.
fn extractSourceFilePath(cmd: []const u8) ?[]const u8 {
    const exts = [_][]const u8{
        ".zig",  ".rs",  ".ts",  ".tsx", ".js",    ".jsx",   ".mjs",    ".cjs",
        ".py",   ".go",  ".c",   ".h",   ".cc",    ".cpp",   ".hpp",    ".cxx",
        ".java", ".kt",  ".rb",  ".php", ".swift", ".scala", ".cs",     ".lua",
        ".ex",   ".exs", ".erl", ".clj", ".dart",  ".vue",   ".svelte",
    };
    var it = std.mem.tokenizeAny(u8, cmd, " \t\n");
    var first = true;
    while (it.next()) |raw| {
        if (first) {
            first = false;
            continue; // skip the command word itself
        }
        const tok = std.mem.trim(u8, raw, "'\"`()");
        if (std.mem.indexOfAny(u8, tok, "*?") != null) continue; // glob, not a path
        for (exts) |e| if (std.mem.endsWith(u8, tok, e)) return tok;
    }
    return null;
}

/// True when `cmd` names a concrete source file (delegates to
/// extractSourceFilePath). Kept for the /hooks display and tests.
fn referencesSourceFile(cmd: []const u8) bool {
    return extractSourceFilePath(cmd) != null;
}

/// Built-in pre_tool router for the metered companion — the tool-layer twin of
/// providerFor()'s model routing (prefer the configured target, fall back to a
/// default). codedb-pro's tools (mcp__codedbpro__*) are only advertised while it
/// is connected; if the model calls one when the companion is gone (disconnected
/// mid-session, or a stale tool name carried over from a prior turn), don't hand
/// back a bare "unknown tool" — redirect to the native equivalent, which is
/// always registered. Returns null (let the call run) when the companion IS
/// connected, or when this isn't a companion tool at all.
fn companionRoute(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    const bare = companionToolName(call.name) orelse return null;
    if (ctx.registry) |reg| {
        for (companion_servers) |c| if (mcpServerConnected(reg.tools, c.server)) return null;
    }
    const native = companionNativeFallback(bare);
    const msg = std.fmt.allocPrint(ctx.gpa, "the codedb-pro companion isn't connected this session, so {s} can't run — it was only an accelerator. Use the native {s} instead (always available).", .{ call.name, native }) catch return .{ .text = &.{}, .is_error = true };
    return .{ .text = msg, .is_error = true };
}

/// Map a companion tool (bare name, sans the mcp__<server>__ prefix) to the
/// native tool that does the same job — the fallback companionRoute steers to.
fn companionNativeFallback(bare: []const u8) []const u8 {
    if (std.mem.eql(u8, bare, "read")) return "read_file tool";
    if (std.mem.eql(u8, bare, "search") or std.mem.eql(u8, bare, "faster_search") or std.mem.eql(u8, bare, "meta_search"))
        return "codedb tool (search/symbol/callers/outline), or bash grep";
    if (std.mem.eql(u8, bare, "edit") or std.mem.eql(u8, bare, "patch") or std.mem.eql(u8, bare, "replace"))
        return "edit_file tool";
    if (std.mem.eql(u8, bare, "create")) return "write_file tool";
    if (std.mem.eql(u8, bare, "diff")) return "bash `git diff`";
    if (std.mem.eql(u8, bare, "lint")) return "bash to run the linter directly";
    return "native read_file/edit_file/codedb/bash tools";
}

/// Runs on a pool thread; never throws — failures become is_error results.
/// Every execution is timed (out.ms) and traced.
fn execTool(ctx: ToolCtx, call: ToolCall) ToolOutput {
    const t0: Io.Timestamp = .now(ctx.io, .awake);
    if (codedbGuard(ctx, call) orelse companionRoute(ctx, call) orelse hookGate(ctx, call)) |blocked| {
        var out = blocked;
        out.ms = t0.untilNow(ctx.io, .awake).toMilliseconds();
        if (ctx.tracer) |tr| tr.tool(call.name, out.ms, true, out.text.len, ctx.from_sub);
        if (ctx.tools_used) |ts| ts.add(ctx.io, ctx.gpa, call.name, true);
        return out;
    }
    var out = execToolInner(ctx, call) catch |err| blk: {
        // Harness-level tool failure (spawn error, OOM, broken pipe) — not a
        // tool that ran and returned is_error; those are normal agent
        // feedback and already counted in the session summary.
        var ebuf: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(&ebuf, "{s}: {t}", .{ call.name, err }) catch @errorName(err);
        if (telemetry.g_telem) |t| t.errorEvent("tool", detail);
        break :blk failure(ctx.gpa, err);
    };
    out.ms = t0.untilNow(ctx.io, .awake).toMilliseconds();
    if (ctx.tracer) |tr| tr.tool(call.name, out.ms, out.is_error, out.text.len, ctx.from_sub);
    if (ctx.tools_used) |ts| ts.add(ctx.io, ctx.gpa, call.name, out.is_error);
    runPostToolHooks(ctx, call, out);
    return out;
}

fn failure(gpa: Allocator, err: anyerror) ToolOutput {
    const text = std.fmt.allocPrint(gpa, "error: {t}", .{err}) catch return .{ .is_error = true };
    return .{ .text = text, .is_error = true };
}

/// A required string argument, or null if absent / wrong type. Guards
/// against malformed model output panicking the process (DoS).
/// Pull a human-readable message from an OpenAI-style error envelope, handling
/// both `{"error":{"message":...}}` (OpenAI/Anthropic) and `{"error":"...","code":...}`
/// where `error` is a bare string (the codegraff gateway's shape, e.g. grok-build
/// rejecting an unsupported parameter). Returns null when there is no error field
/// (or it is explicitly null), so a normal response is never mistaken for an error.
fn apiErrorMessage(root: std.json.ObjectMap) ?[]const u8 {
    const e = root.get("error") orelse return null;
    return switch (e) {
        .null => null,
        .string => e.string,
        .object => if (e.object.get("message")) |m| (if (m == .string) m.string else "unknown error") else "unknown error",
        else => "unknown error",
    };
}

/// Does an API error message complain about the reasoning-effort hint? Gateways
/// word it differently: OpenAI says "reasoning_effort", the codegraff gateway
/// (e.g. for grok-build) says "reasoningEffort". Either means: drop it and retry.
fn mentionsReasoningEffort(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "reasoning_effort") != null or
        std.mem.indexOf(u8, msg, "reasoningEffort") != null;
}

fn strField(input: Value, name: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const v = input.object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// An integer argument, or null if absent / wrong type (same DoS guard).
fn intField(input: Value, name: []const u8) ?i64 {
    if (input != .object) return null;
    const v = input.object.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn missingArg(gpa: Allocator, name: []const u8) !ToolOutput {
    return .{ .text = try std.fmt.allocPrint(gpa, "missing or non-string argument: {s}", .{name}), .is_error = true };
}

fn outsideCwd(gpa: Allocator, path: []const u8) !ToolOutput {
    return .{
        .text = try std.fmt.allocPrint(gpa, "path '{s}' is outside the working directory — file tools are confined to the cwd subtree (no absolute paths, no '..'). Use bash for paths elsewhere.", .{path}),
        .is_error = true,
    };
}

const bash_stdout_cap = 128 * 1024;
const bash_stderr_cap = 32 * 1024;
const webfetch_cap = 256 * 1024;
const codedb_result_cap = 64 * 1024;

/// True when the text carries no real content (empty, or whitespace only) —
/// kuri-fetch "succeeds" on JS-rendered SPAs but emits pages of blank lines.
fn blankText(text: []const u8) bool {
    var meaningful: usize = 0;
    for (text) |c| switch (c) {
        ' ', '\t', '\r', '\n' => {},
        else => meaningful += 1,
    };
    return meaningful < 16;
}

/// Fallback webfetch path: a plain GET via the harness's shared HTTP client,
/// raw body (HTML/text), capped at webfetch_cap. Load-bearing even when kuri
/// is installed — it covers the servers kuri's TLS stack rejects and the
/// SPAs it renders blank.
fn rawFetch(gpa: Allocator, client: *std.http.Client, url: []const u8) ToolOutput {
    const buf = gpa.alloc(u8, webfetch_cap) catch return .{ .is_error = true };
    defer gpa.free(buf);
    var w: Io.Writer = .fixed(buf);
    var truncated = false;
    var status: ?std.http.Status = null;
    if (client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &w,
        .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
    })) |res| {
        status = res.status;
    } else |err| switch (err) {
        error.WriteFailed => truncated = true, // body hit the cap: keep what we have
        else => return failure(gpa, err),
    }
    const body = w.buffered();
    if (status) |st| {
        const code = @intFromEnum(st);
        if (code < 200 or code >= 300) return .{
            .text = std.fmt.allocPrint(gpa, "HTTP {d} {s}", .{ code, st.phrase() orelse "" }) catch return .{ .is_error = true },
            .is_error = true,
        };
    }
    if (std.mem.indexOfScalar(u8, body[0..@min(body.len, 4096)], 0) != null) return .{
        .text = std.fmt.allocPrint(gpa, "{s} returned binary content ({d} bytes) — webfetch only handles text; use bash (e.g. curl -o) to download it", .{ url, body.len }) catch return .{ .is_error = true },
        .is_error = true,
    };
    if (blankText(body)) return .{ .text = gpa.dupe(u8, "(empty response body)") catch return .{ .is_error = true } };
    var aw: Io.Writer.Allocating = .init(gpa);
    aw.writer.writeAll(body) catch {
        aw.deinit();
        return .{ .is_error = true };
    };
    if (truncated) aw.writer.print("\n[truncated at {d} KB]", .{webfetch_cap / 1024}) catch {};
    return .{ .text = aw.toOwnedSlice() catch return .{ .is_error = true } };
}

/// Wall-clock ceiling for one *subagent* bash command. Subagents run on pool
/// threads with no TTY, so there is no Esc to kill a runaway command — without
/// this, a codedb refusal that pushes a subagent onto an unfiltered `grep ~/`
/// hangs the whole workflow for ~48 min (#93). The root keeps its Esc-only,
/// no-deadline behavior (a human is watching and may want a long build).
const subagent_bash_deadline_ms: u64 = 120 * 1000;

// Subprocess execution: the capped runner (runCapped), git-worktree management,
// and the background bash-job pool live in jobs.zig (600-line goal). runCapped
// is re-exported (hooks.zig back-imports it); the worktree + job entry points
// are aliased back.
const jobs = @import("jobs.zig");
pub const runCapped = jobs.runCapped;
const worktreeAutoCommit = jobs.worktreeAutoCommit;
const worktreeCommand = jobs.worktreeCommand;
const spawnJob = jobs.spawnJob;
const jobOutput = jobs.jobOutput;
const jobKill = jobs.jobKill;
const jobsReap = jobs.jobsReap;
const shellArgv = jobs.shellArgv;

fn execToolInner(ctx: ToolCtx, call: ToolCall) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;

    // Plan mode backstop: the root gate already denies these with a nicer
    // message; this catches subagents (which skip the gate entirely).
    if (plan_mode) {
        if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or mcp.Registry.isMcp(call.name)) return .{
            .text = try gpa.dupe(u8, "plan mode is on — read-only; describe the change instead of making it"),
            .is_error = true,
        };
        if (std.mem.eql(u8, call.name, "bash")) {
            if (strField(call.input, "command")) |cmd| if (!Approvals.readOnlyAllowed(cmd)) return .{
                .text = try gpa.dupe(u8, "plan mode is on — only read-only commands run; describe this command in the plan instead"),
                .is_error = true,
            };
        }
    }

    if (mcp.Registry.isMcp(call.name)) {
        const reg = ctx.registry orelse return .{
            .text = try gpa.dupe(u8, "MCP not available in this context"),
            .is_error = true,
        };
        const r = try reg.call(gpa, call.name, call.input);
        return .{ .text = r.text, .is_error = r.is_error };
    }

    const input = call.input;
    if (std.mem.eql(u8, call.name, "bash")) {
        const cmd = strField(input, "command") orelse return missingArg(gpa, "command");
        // Subagents have no stdin to prompt on; their gate is the allowlist.
        if (ctx.from_sub) if (ctx.approvals) |ap| if (!ap.allowed(ctx.io, cmd)) return .{
            .text = try gpa.dupe(u8, "command not pre-approved — subagents may only run user-approved or read-only commands, with no chaining/pipes/redirection. Use read_file/edit_file/write_file, or report back what you need run."),
            .is_error = true,
        };
        const bg = if (input == .object) (if (input.object.get("run_in_background")) |v| v == .bool and v.bool else false) else false;
        if (bg) {
            const job = spawnJob(gpa, io, cmd) catch |err| return .{
                .text = try std.fmt.allocPrint(gpa, "could not start background job ({t}) — run it in the foreground instead", .{err}),
                .is_error = true,
            };
            return .{ .text = try std.fmt.allocPrint(gpa, "[job {d} started: {s}]\nIt keeps running across turns. Poll new output with bash_output (id {d}, optional wait_ms), stop it with bash_kill.", .{ job.id, job.cmd, job.id }) };
        }
        const sh = shellArgv(cmd);
        const run = try runCapped(gpa, io, &sh, bash_stdout_cap, bash_stderr_cap, if (ctx.from_sub) subagent_bash_deadline_ms else 0);
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);

        const exit_code: ?u8 = switch (run.term) {
            .exited => |code| code,
            else => null,
        };
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        if (run.stdout.len > 0) try w.writeAll(run.stdout);
        if (run.stdout_truncated) try w.print("\n[stdout truncated at {d} KB]", .{bash_stdout_cap / 1024});
        if (run.stderr.len > 0) try w.print("\n[stderr]\n{s}", .{run.stderr});
        if (run.stderr_truncated) try w.print("\n[stderr truncated at {d} KB]", .{bash_stderr_cap / 1024});
        if (run.timed_out) {
            try w.print("\n[timed out after {d}s and was killed — too long for a subagent. Don't retry as-is: scope it to specific paths or globs instead of scanning the whole directory, or report back what you need run.]", .{subagent_bash_deadline_ms / 1000});
        } else if (exit_code) |code| {
            if (code != 0) try w.print("\n[exit code {d}]", .{code});
        } else try w.writeAll("\n[terminated abnormally]");
        if (run.stdout.len == 0 and run.stderr.len == 0 and exit_code == 0) try w.writeAll("(no output)");
        return .{ .text = try aw.toOwnedSlice(), .is_error = exit_code == null or exit_code.? != 0 };
    }
    if (std.mem.eql(u8, call.name, "bash_output")) {
        const id = intField(input, "id") orelse return missingArg(gpa, "id");
        const wait_ms = intField(input, "wait_ms") orelse 0;
        if (id < 0 or id > std.math.maxInt(u32)) return .{ .text = try gpa.dupe(u8, "invalid job id"), .is_error = true };
        return jobOutput(gpa, io, @intCast(id), @intCast(@max(wait_ms, 0)));
    }
    if (std.mem.eql(u8, call.name, "bash_kill")) {
        const id = intField(input, "id") orelse return missingArg(gpa, "id");
        if (id < 0 or id > std.math.maxInt(u32)) return .{ .text = try gpa.dupe(u8, "invalid job id"), .is_error = true };
        return jobKill(gpa, io, @intCast(id));
    }
    if (std.mem.eql(u8, call.name, "webfetch")) {
        const url = strField(input, "url") orelse return missingArg(gpa, "url");
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return .{
            .text = try gpa.dupe(u8, "webfetch only handles absolute http:// and https:// URLs"),
            .is_error = true,
        };
        // kuri-preferred, never kuri-dependent: kuri-fetch converts HTML to
        // markdown, but its TLS stack rejects some servers and JS-rendered
        // SPAs come back blank — any failure or empty result falls through
        // to the harness's own HTTP client below.
        if (!skillDisabled("kuri") and binOnPath(io, "kuri-fetch")) kuri: {
            const run = runCapped(gpa, io, &.{ "kuri-fetch", "-q", "--no-color", url }, webfetch_cap, 4096, 0) catch break :kuri;
            defer {
                gpa.free(run.stdout);
                gpa.free(run.stderr);
            }
            if (run.term != .exited or run.term.exited != 0) break :kuri;
            if (blankText(run.stdout)) break :kuri; // SPA / conversion failure
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try aw.writer.writeAll(run.stdout);
            if (run.stdout_truncated) try aw.writer.print("\n[truncated at {d} KB]", .{webfetch_cap / 1024});
            return .{ .text = try aw.toOwnedSlice() };
        }
        return rawFetch(gpa, ctx.client, url);
    }
    if (std.mem.eql(u8, call.name, "read_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        if (!confinedPath(path) or !noSymlinkEscape(io, path)) return outsideCwd(gpa, path);
        const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024));
        // Binary guard: PDFs/images/archives would only poison the context
        // with mojibake — point the model at bash converters instead.
        if (binaryFileExt(path) or std.mem.indexOfScalar(u8, data[0..@min(data.len, 4096)], 0) != null) {
            defer gpa.free(data);
            return .{ .text = try std.fmt.allocPrint(gpa, "{s} is a binary file ({d} bytes) — read_file only handles text. Use bash instead (e.g. `file`, `strings`, `pdftotext`, `sips`, `unzip -l`).", .{ path, data.len }), .is_error = true };
        }
        return .{ .text = data };
    }
    if (std.mem.eql(u8, call.name, "codedb")) {
        const cmd = strField(input, "command") orelse return missingArg(gpa, "command");
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        const sub = it.next() orelse return .{ .text = try gpa.dupe(u8, "usage: codedb <subcommand> [args] — e.g. search <q>, symbol <name>, callers <name>, outline <path>"), .is_error = true };
        // Allowlist read-only subcommands: never run the long-lived daemons
        // (serve/mcp) — they'd block this tool forever — or the destructive
        // ones (update/nuke).
        const ok_subs = [_][]const u8{ "search", "symbol", "callers", "find", "outline", "read", "tree", "context", "word", "deps", "glob", "ls", "file", "hot" };
        var allowed = false;
        for (ok_subs) |s| if (std.mem.eql(u8, s, sub)) {
            allowed = true;
        };
        if (!allowed) return .{ .text = try std.fmt.allocPrint(gpa, "codedb subcommand '{s}' is not allowed here — use one of: search, symbol, callers, find, outline, read, tree, context, word, deps, glob, ls, file, hot", .{sub}), .is_error = true };
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        argv.append(gpa, "codedb") catch {};
        argv.append(gpa, sub) catch {};
        while (it.next()) |tok| argv.append(gpa, tok) catch {};
        var child = std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch {
            return .{ .text = try gpa.dupe(u8, "codedb isn't installed — it's open source at github.com/justrach/codedb; install it, then run `codedb` once in the repo to index it"), .is_error = true };
        };
        const out_file = child.stdout orelse return .{ .text = try gpa.dupe(u8, "codedb: no output stream"), .is_error = true };
        var rbuf: [4096]u8 = undefined;
        var fr = out_file.readerStreaming(io, &rbuf);
        const text = fr.interface.allocRemaining(gpa, .limited(512 * 1024)) catch |e| return failure(gpa, e);
        _ = child.wait(io) catch {};
        if (text.len == 0) return .{ .text = try gpa.dupe(u8, "(codedb returned nothing — try `codedb tree` to confirm the repo is indexed, or refine the query)") };
        // Context guard: an unbounded `read <big file>` once dumped 500KB into
        // a subagent's context, ballooning it to 160k tokens and minutes-long
        // API calls. Cap what reaches the model and point it at targeted reads.
        if (text.len > codedb_result_cap) {
            defer gpa.free(text);
            const head = utf8Prefix(text, codedb_result_cap);
            return .{ .text = try std.fmt.allocPrint(gpa, "{s}\n[codedb output truncated at {d} KB — prefer targeted queries: outline <path>, symbol <name> --body, or search, instead of whole-file reads]", .{ head, codedb_result_cap / 1024 }) };
        }
        return .{ .text = text };
    }
    if (std.mem.eql(u8, call.name, "edit_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        const old = strField(input, "old_string") orelse return missingArg(gpa, "old_string");
        const new = strField(input, "new_string") orelse return missingArg(gpa, "new_string");
        if (!confinedPath(path) or !noSymlinkEscape(io, path)) return outsideCwd(gpa, path);
        const all = if (input.object.get("replace_all")) |v| v == .bool and v.bool else false;
        if (old.len == 0) return .{ .text = try gpa.dupe(u8, "old_string must not be empty"), .is_error = true };

        const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
        defer gpa.free(data);
        const count = std.mem.count(u8, data, old);
        if (count == 0) return .{
            .text = try std.fmt.allocPrint(gpa, "old_string not found in {s} — read_file it and match the existing text exactly", .{path}),
            .is_error = true,
        };
        if (count > 1 and !all) return .{
            .text = try std.fmt.allocPrint(gpa, "old_string matches {d} places in {s} — include more surrounding context to make it unique, or set replace_all", .{ count, path }),
            .is_error = true,
        };

        const replaced = try gpa.alloc(u8, std.mem.replacementSize(u8, data, old, new));
        defer gpa.free(replaced);
        _ = std.mem.replace(u8, data, old, new, replaced);
        if (ctx.snapshots) |snaps| if (!ctx.from_sub) snaps.record(path, data); // pre-edit content for /rewind
        // Premium splice: when the zigrep suite is installed, zigpatch does
        // the write — an atomic tmp+rename byte-level --all splice (our count
        // checks above already enforce the uniqueness semantics). Any
        // failure, including the tool simply not being on PATH, falls back
        // to the native in-place write below.
        zp: {
            const run = runCapped(gpa, io, &.{ "zigpatch", path, "-p", old, "--all", "--content", new }, 4096, 4096, 0) catch break :zp;
            defer {
                gpa.free(run.stdout);
                gpa.free(run.stderr);
            }
            const ok = switch (run.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok and std.mem.indexOf(u8, run.stdout, "\"ok\":true") != null)
                return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s} (zigpatch)", .{ count, path }) };
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = replaced });
        return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s}", .{ count, path }) };
    }
    if (std.mem.eql(u8, call.name, "write_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        const content = strField(input, "content") orelse return missingArg(gpa, "content");
        if (!confinedPath(path) or !noSymlinkEscape(io, path)) return outsideCwd(gpa, path);
        if (ctx.snapshots) |snaps| if (!ctx.from_sub) {
            // capture the prior content (or absence) before overwriting, for /rewind
            const before = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch null;
            defer if (before) |b| gpa.free(b);
            snaps.record(path, before);
        };
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
        return .{ .text = try std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ content.len, path }) };
    }
    if (std.mem.eql(u8, call.name, "subagent")) return execSubagent(ctx, input);
    if (std.mem.eql(u8, call.name, "workflow")) return execWorkflow(ctx, input);
    return .{ .text = try std.fmt.allocPrint(gpa, "unknown tool: {s}", .{call.name}), .is_error = true };
}

/// Spawn a one-level-deep subagent: fresh arena, fresh history, same shared
/// http client and provider. Runs entirely on this pool thread; its own tool
/// calls fan out further via io.async.
fn execSubagent(ctx: ToolCtx, input: Value) !ToolOutput {
    if (ctx.from_sub) return .{
        .text = try ctx.gpa.dupe(u8, "subagents cannot spawn subagents — do this work yourself"),
        .is_error = true,
    };
    const label = if (input.object.get("description")) |d| (if (d == .string) d.string else "subagent") else "subagent";
    const prompt = if (input.object.get("prompt")) |p| (if (p == .string) p.string else "") else "";
    if (prompt.len == 0) return .{ .text = try ctx.gpa.dupe(u8, "subagent: missing required \"prompt\" (a self-contained task)"), .is_error = true };
    const sys_override = resolveOverride(input.object);
    return runSub(ctx, "subagent", label, prompt, sys_override, resolveNiche(input.object));
}

/// Surface a workflow subagent as a synthetic `tool_call` / `tool_result` on the
/// --json GUI stream so each parallel worker shows as its own live row — the
/// orchestrator's children otherwise run detached (out=null), so the GUI only
/// ever saw the single `workflow` op. Pool-thread safe: serializes on g_gui_mu
/// with Agent.emit (same json stdout writer, g_out). No-op outside --json mode.
fn guiEmit(io: Io, ev: anytype) void {
    if (!json_mode) return;
    const w = g_out orelse return;
    g_gui_mu.lockUncancelable(io);
    defer g_gui_mu.unlock(io);
    var s: std.json.Stringify = .{ .writer = w };
    s.write(ev) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

/// Run one isolated subagent to completion: fresh arena, fresh history,
/// same shared http client and provider. Runs entirely on this pool thread;
/// its own tool calls fan out further via io.async. `sys_override` swaps the
/// lean default system prompt for a per-child variant (swarm prompt
/// evolution); either way the run is recorded as a trajectory node under
/// the turn that spawned it, with the prompt's fingerprint.
fn runSub(ctx: ToolCtx, kind: []const u8, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8) !ToolOutput {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = ctx.io,
        .client = ctx.client,
        .provider = ctx.provider,
        .messages = std.json.Array.init(arena),
        .sub = true,
        .label = label,
        .out = null,
        .approvals = ctx.approvals,
        .tracer = ctx.tracer,
        .sys_override = sys_override,
    };
    const sub_start = Io.Timestamp.now(ctx.io, .awake);
    if (sys_override) |so| if (telemetry.g_telem) |t| {
        t.countVariant();
        // fleet:propose (docs §9.B) — a niche's elite was mutated into a variant.
        const child_fp = promptFingerprint(so);
        var parent_buf: [16]u8 = undefined;
        var parent_sha: []const u8 = "";
        if (niche.len > 0) if (agentTypePrompt(niche)) |ep| {
            parent_buf = promptFingerprint(ep);
            parent_sha = &parent_buf;
        };
        t.fleetEvent("propose", niche, &child_fp, parent_sha, providerClass(ctx.provider.model), "", 0, so);
    };
    // Stable id + sprite for this child's card and its inspectable detail file.
    const ordinal = cards.g_subagent_seq.fetchAdd(1, .monotonic);
    var id_buf: [40]u8 = undefined;
    const sub_id = subagentId(&id_buf, ordinal, label, prompt);
    const sprite = subagentSprite(ordinal);
    subagentLaunchCard(arena, sub_id, sprite, label, kind, prompt);
    // Live agent tree: surface workflow_task children as their own GUI rows.
    const wf_task = std.mem.eql(u8, kind, "workflow_task");
    if (wf_task) guiEmit(ctx.io, .{ .type = "tool_call", .name = "subagent", .input = .{ .description = label } });
    try agent.messages.append(try textMessage(arena, "user", prompt));
    defer agent.tools_used.deinit(gpa);
    const report = agent.runTurn();
    const run_ms: i64 = @intCast(@max(0, sub_start.untilNow(ctx.io, .awake).toMilliseconds()));
    const run_ok = if (report) |r| r.len > 0 else |_| false;
    if (wf_task) guiEmit(ctx.io, .{ .type = "tool_result", .name = "subagent", .is_error = !run_ok });
    const tools = agent.tools_used.render(arena);
    const fp = promptFingerprint(agent.systemPrompt());
    if (trace.g_traj) |tj| {
        tj.capturePrompt(fp, agent.systemPrompt());
        tj.node(.{
            .id = tj.nextId(),
            .parent = tj.currentTurn(),
            .kind = kind,
            .label = label,
            .t = tj.elapsedMs(),
            .ms = run_ms,
            .prompt_sha = &fp,
            .prompt_mutated = sys_override != null,
            .niche = niche, // MAP-Elites niche, so a local /agents promote can group scores by it
            .task = utf8Prefix(prompt, 160),
            .tools = tools,
            .ok = run_ok,
            .context_tokens = agent.last_context_tokens,
        });
    }
    if (telemetry.g_telem) |t| t.runEvent(&fp, sys_override != null, run_ok, run_ms, tools);
    const text = try report;
    const empty = text.len == 0;
    const report_body = if (empty) "subagent finished without a report" else text;
    // Persist the full report + metadata so it can be inspected from the
    // terminal, then render the completion card with the inspect: path.
    const detail = writeSubagentDetail(ctx.io, arena, sub_id, label, kind, prompt, report_body, !empty, run_ms, tools);
    subagentDoneCard(arena, sub_id, sprite, label, !empty, run_ms, tools, detail);
    if (empty) return .{ .text = try gpa.dupe(u8, report_body), .is_error = true };
    // Append the inspect: path so the orchestrator can cite the detail file.
    if (detail) |p|
        return .{ .text = try std.fmt.allocPrint(gpa, "{s}\n\n[subagent {s} · inspect: {s}]", .{ text, sub_id, p }) };
    return .{ .text = try gpa.dupe(u8, text) };
}

/// One task inside a workflow phase; never throws, suitable for io.async.
/// `niche` is the task's MAP-Elites cell, threaded through so runSub's
/// fleet:propose — and scoreVariants' submit — tag the variant's genome.
fn workflowTask(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8) ToolOutput {
    return runSub(ctx, "workflow_task", label, prompt, sys_override, niche) catch |err| failure(ctx.gpa, err);
}

/// The --judge LLM-as-judge run (see runJudge): an isolated subagent scores the
/// work against the rubric and ends with a `score:` line. Mirrors workflowTask —
/// a thin runSub wrapper — so the eval handler can io.async it on a pool thread.
fn judgeTask(ctx: ToolCtx, prompt: []const u8) ToolOutput {
    return runSub(ctx, "judge_task", "judge", prompt, null, "") catch |err| failure(ctx.gpa, err);
}

/// Build the judge prompt that scores one workflow variant's output against its
/// task on a 0-100 scale (see scoreVariants). Bounded: the task spec and output
/// tail are truncated so a fat phase can't blow up the judge's context.
fn variantJudgePrompt(arena: Allocator, title: []const u8, task: []const u8, output: []const u8) ![]const u8 {
    const spec = utf8Prefix(task, 1200);
    const work = if (output.len > 2000) output[output.len - 2000 ..] else output;
    return std.fmt.allocPrint(arena,
        \\An agent variant ran the task below as part of the "{s}" phase of a workflow.
        \\Judge how well its OUTPUT accomplishes the TASK, on a 0-100 scale. Be
        \\discriminating: reward correctness, completeness, and usefulness; penalize
        \\hand-waving, non-answers, and ignored requirements. Do not reward length.
        \\
        \\TASK:
        \\{s}
        \\
        \\VARIANT OUTPUT:
        \\{s}
        \\
        \\Inspect any files the work references if you need to, then end your reply
        \\with a single final line `score: <N>` where N is an integer from 0 to 100.
    , .{ title, spec, work });
}

/// #1 — Score this phase's persona variants and submit niche-tagged fitness to
/// the fleet, turning every ultracode tournament into a DGM scoring round. Each
/// surviving variant task is judged 0-100 against its task; the score is signed
/// and submitted under the task's niche so a MAP-Elites cell accrues real fitness
/// and the promote pass can crown a winner. Mirrors runEval's submit exactly but
/// with a NON-EMPTY niche — the gap that previously forced bootstrap seeding.
/// Best-effort and gated: no judge runs unless ≥2 variants competed and the
/// fleet (telemetry) is on, so ordinary fan-outs pay nothing.
fn scoreVariants(
    ctx: ToolCtx,
    arena: Allocator,
    title: []const u8,
    prompts: [][]const u8,
    raws: [][]const u8,
    overrides: []?[]const u8,
    niches: [][]const u8,
    outputs: []ToolOutput,
) void {
    if (!g_fleet) return;
    const t = telemetry.g_telem orelse return;

    // Variant tasks that produced a usable result; a tournament needs ≥2.
    var vidx: [max_workflow_tasks]usize = undefined;
    var vn: usize = 0;
    for (overrides, outputs, 0..) |o, out, i| {
        if (o != null and !out.is_error) {
            vidx[vn] = i;
            vn += 1;
        }
    }
    if (vn < 2) return;

    // All fallible work (prompt builds) before any future spawns, so an early
    // return can never abandon a running judge.
    const jprompts = arena.alloc([]const u8, vn) catch return;
    for (jprompts, 0..) |*jp, k| {
        const i = vidx[k];
        jp.* = variantJudgePrompt(arena, title, prompts[i], outputs[i].text) catch return;
    }
    const jfuts = arena.alloc(Io.Future(ToolOutput), vn) catch return;
    for (jfuts, jprompts) |*jf, jp| jf.* = ctx.io.async(judgeTask, .{ ctx, jp });

    const pclass = providerClass(ctx.provider.model);
    const run_id: []const u8 = &scoring.g_run_id;
    for (jfuts, 0..) |*jf, k| {
        const i = vidx[k];
        const jout = jf.await(ctx.io);
        defer ctx.gpa.free(jout.text);
        if (jout.is_error) continue;
        const s = parseEvalScore(jout.text) orelse continue;
        if (s <= 0) continue; // skip the total-failure 0 (don't pollute the cell mean), mirroring runEval
        const genome_fp = promptFingerprint(overrides[i].?);
        const esh_fp = promptFingerprint(raws[i]);
        const genome: []const u8 = &genome_fp;
        const esh: []const u8 = &esh_fp;
        const sig = signScore(genome, "", s, run_id, "", "", esh);
        const sig_s: []const u8 = if (scoring.g_score_key != null) &sig else "";
        var provbuf: [512]u8 = undefined;
        const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ "", "", esh, pclass, "" }) catch "";
        t.scoreEvent(genome, "", s, run_id, sig_s, prov);
        t.fleetEvent("submit", niches[i], genome, "", pclass, esh, 0, "");
    }
}

const max_workflow_phases = 5;
const max_workflow_tasks = 8;

// Per-task cap on each phase result fed into {{prev}} (#4): a wide or runaway
// phase would otherwise push its full output into every next-phase task, so
// phase N+1 pays N× context. Over the cap we keep the head (the substance) plus
// a short tail — which carries the `inspect:` pointer to the full detail file —
// with a truncation marker between, so nothing is actually lost. (A synthesis/
// compress pass is the heavier alternative; per-task slicing is the cheap,
// no-extra-LLM-call lever.)
const max_prev_per_task = 6000;
const prev_tail_keep = 600;

/// Bound one task's output before it enters the {{prev}} buffer (#4). Short
/// outputs pass through untouched; over the cap, head + truncation marker + tail.
fn cappedPrevBody(arena: Allocator, text: []const u8) []const u8 {
    if (text.len <= max_prev_per_task) return text;
    const head = utf8Prefix(text, max_prev_per_task - prev_tail_keep);
    const tail = text[text.len - prev_tail_keep ..];
    return std.fmt.allocPrint(arena, "{s}\n\n…[{d} chars truncated — full result in the inspect file below]…\n\n{s}", .{ head, text.len - head.len - tail.len, tail }) catch text;
}

/// #5 conditional-phase gate: a phase carrying a non-empty `when` runs only when
/// that substring appears (case-insensitively) in the previous phase's results —
/// e.g. gate a synthesis phase on a findings sentinel so it never runs when the
/// earlier phase turned up nothing. Empty `when` (or phase 1, no prev) → runs.
fn gateAllows(prev: []const u8, when: []const u8) bool {
    return when.len == 0 or std.ascii.indexOfIgnoreCase(prev, when) != null;
}

// ── Pipeline mode (#3) ──────────────────────────────────────────────────────
// Phases fan out then synthesize: a barrier between phases, since every
// next-phase task waits on ALL of the previous phase via {{prev}}. Pipeline
// instead maps each ITEM through a chain of STAGES with NO barrier — item A can
// be in stage 3 while item B is still in stage 1, so wall-clock is the slowest
// single chain, not the sum of slowest-per-stage. Use it for per-item work
// (transform/verify each file); use phases for fan-out + synthesis.
const max_pipeline_items = 8;
const max_pipeline_stages = 5;

const StageSpec = struct {
    label: []const u8,
    prompt: []const u8, // raw; may contain {{item}} / {{prev}}
    override: ?[]const u8,
    niche: []const u8,
};

/// Replace every `needle` in `hay` with `repl` (arena-allocated); returns `hay`
/// unchanged when the needle is absent.
fn replacePlaceholder(arena: Allocator, hay: []const u8, needle: []const u8, with: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, hay, needle) == null) return hay;
    const size = std.mem.replacementSize(u8, hay, needle, with);
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, hay, needle, with, buf);
    return buf;
}

/// Resolve a pipeline stage prompt for one item: substitute {{item}}, and from
/// stage 2 {{prev}} = this item's bounded previous-stage result. Either is
/// appended when its placeholder is omitted (mirrors phases-mode {{prev}}).
fn pipelinePrompt(arena: Allocator, raw: []const u8, item: []const u8, prev: []const u8, stage_no: usize) ![]const u8 {
    const cp = if (stage_no > 1) cappedPrevBody(arena, prev) else "";
    var p = raw;
    if (std.mem.indexOf(u8, p, "{{item}}") != null)
        p = try replacePlaceholder(arena, p, "{{item}}", item)
    else
        p = try std.fmt.allocPrint(arena, "{s}\n\nItem: {s}", .{ p, item });
    if (std.mem.indexOf(u8, p, "{{prev}}") != null)
        p = try replacePlaceholder(arena, p, "{{prev}}", cp)
    else if (stage_no > 1)
        p = try std.fmt.allocPrint(arena, "{s}\n\nResult from the previous stage:\n\n{s}", .{ p, cp });
    return p;
}

/// One item's journey through every stage, run on a pool thread (spawned by
/// runPipeline). Stages run SEQUENTIALLY here via DIRECT runSub calls — never a
/// nested io.async, which on a bounded pool could deadlock; different items run
/// concurrently. A failed stage is retried once (#2); a stage that still fails
/// ends the chain with a terse marker rather than feeding its error downstream.
fn pipelineChain(ctx: ToolCtx, item: []const u8, stages: []const StageSpec) ToolOutput {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prev: []const u8 = "";
    for (stages, 1..) |st, stage_no| {
        const prompt = pipelinePrompt(arena, st.prompt, item, prev, stage_no) catch |e| return failure(gpa, e);
        var out = runSub(ctx, "workflow_task", st.label, prompt, st.override, st.niche) catch |e| failure(gpa, e);
        if (out.is_error) {
            gpa.free(out.text);
            out = runSub(ctx, "workflow_task", st.label, prompt, st.override, st.niche) catch |e| failure(gpa, e);
            if (out.is_error) {
                gpa.free(out.text);
                return .{
                    .text = std.fmt.allocPrint(gpa, "(pipeline stopped at stage {d}/{d} \"{s}\": task failed)", .{ stage_no, stages.len, st.label }) catch (gpa.dupe(u8, "(pipeline stage failed)") catch ""),
                    .is_error = true,
                };
            }
        }
        const duped = arena.dupe(u8, out.text) catch {
            gpa.free(out.text);
            return failure(gpa, error.OutOfMemory);
        };
        gpa.free(out.text);
        prev = duped;
    }
    return .{ .text = gpa.dupe(u8, prev) catch "" };
}

/// Pipeline mode entry (#3): validate {items, stages}, then run one independent
/// chain per item concurrently (no barrier) and return the labeled final-stage
/// result for each item.
fn runPipeline(ctx: ToolCtx, pv: Value) !ToolOutput {
    const gpa = ctx.gpa;
    if (pv != .object) return .{ .text = try gpa.dupe(u8, "pipeline must be an object with items + stages"), .is_error = true };
    const items_val = pv.object.get("items") orelse return .{ .text = try gpa.dupe(u8, "pipeline needs an items array"), .is_error = true };
    const stages_val = pv.object.get("stages") orelse return .{ .text = try gpa.dupe(u8, "pipeline needs a stages array"), .is_error = true };
    if (items_val != .array or stages_val != .array) return .{ .text = try gpa.dupe(u8, "pipeline items and stages must both be arrays"), .is_error = true };
    const items = items_val.array.items;
    const stage_vals = stages_val.array.items;
    if (items.len == 0 or items.len > max_pipeline_items) return .{ .text = try std.fmt.allocPrint(gpa, "pipeline needs 1-{d} items", .{max_pipeline_items}), .is_error = true };
    if (stage_vals.len == 0 or stage_vals.len > max_pipeline_stages) return .{ .text = try std.fmt.allocPrint(gpa, "pipeline needs 1-{d} stages", .{max_pipeline_stages}), .is_error = true };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse stages once — shared (read-only) by every item chain.
    const stages = try arena.alloc(StageSpec, stage_vals.len);
    for (stage_vals, stages) |sv, *sp| {
        if (sv != .object) return .{ .text = try gpa.dupe(u8, "each pipeline stage must be an object"), .is_error = true };
        const so = sv.object;
        sp.label = if (so.get("description")) |d| (if (d == .string) d.string else "stage") else "stage";
        const raw = if (so.get("prompt")) |p| (if (p == .string) p.string else "") else "";
        if (raw.len == 0) return .{ .text = try gpa.dupe(u8, "each pipeline stage needs a non-empty \"prompt\""), .is_error = true };
        sp.prompt = raw;
        sp.override = resolveOverride(so);
        const an = resolveNiche(so);
        sp.niche = if (an.len > 0) an else sp.label;
    }

    const item_strs = try arena.alloc([]const u8, items.len);
    for (items, item_strs) |iv, *is| {
        if (iv != .string or iv.string.len == 0) return .{ .text = try gpa.dupe(u8, "pipeline items must be non-empty strings"), .is_error = true };
        is.* = iv.string;
    }

    const wf_start = Io.Timestamp.now(ctx.io, .awake);
    std.debug.print("  [workflow] pipeline: {d} item(s) × {d} stage(s), no barrier\n", .{ items.len, stages.len });

    // Spawn one chain per item — all joined before any fallible work so an early
    // return can never abandon a running chain.
    const futures = try arena.alloc(Io.Future(ToolOutput), items.len);
    const outputs = try arena.alloc(ToolOutput, items.len);
    for (item_strs, futures) |item, *fut| fut.* = ctx.io.async(pipelineChain, .{ ctx, item, stages });
    for (futures, outputs) |*fut, *out| out.* = fut.await(ctx.io);
    defer for (outputs) |out| gpa.free(out.text);

    var failed: usize = 0;
    for (outputs) |out| if (out.is_error) {
        failed += 1;
    };
    if (telemetry.g_telem) |t| t.workflowEvent(stages.len, items.len * stages.len, failed, @intCast(@max(0, wf_start.untilNow(ctx.io, .awake).toMilliseconds())));

    var aw: Io.Writer.Allocating = .init(arena);
    for (item_strs, outputs) |item, out| {
        try aw.writer.print("### {s}{s}\n{s}\n\n", .{ item, if (out.is_error) " (failed)" else "", out.text });
    }
    return .{ .text = try gpa.dupe(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n")) };
}

/// Dynamic workflows as data: sequential phases, parallel tasks. Each task
/// is an isolated subagent; "{{prev}}" in a task prompt is replaced with
/// the labeled results of the previous phase (appended when omitted).
/// Returns the final phase's results.
fn execWorkflow(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    if (ctx.from_sub) return .{
        .text = try gpa.dupe(u8, "subagents cannot run workflows — do this work yourself"),
        .is_error = true,
    };
    // Pipeline mode (#3): {pipeline:{items,stages}} maps each item through the
    // stages with no barrier — distinct from phases (fan-out + synthesis).
    if (input.object.get("pipeline")) |pv| return runPipeline(ctx, pv);
    const phases_val = input.object.get("phases") orelse return .{
        .text = try gpa.dupe(u8, "workflow needs a \"phases\" array (or a \"pipeline\" object)"),
        .is_error = true,
    };
    const phases = phases_val.array.items;
    if (phases.len == 0 or phases.len > max_workflow_phases) return .{
        .text = try std.fmt.allocPrint(gpa, "workflow needs 1-{d} phases", .{max_workflow_phases}),
        .is_error = true,
    };

    // All intermediate strings live in this arena; the final result is
    // duped into gpa for the caller.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Telemetry: one "workflow" record per run — phase/task/failure counts
    // and wall-clock — emitted however the run ends.
    const wf_start = Io.Timestamp.now(ctx.io, .awake);
    var wf_tasks: usize = 0;
    var wf_failed: usize = 0;
    defer if (telemetry.g_telem) |t| t.workflowEvent(
        phases.len,
        wf_tasks,
        wf_failed,
        @intCast(@max(0, wf_start.untilNow(ctx.io, .awake).toMilliseconds())),
    );

    var prev_results: []const u8 = "";
    for (phases, 1..) |phase_val, phase_no| {
        if (phase_val != .object) return .{ .text = try gpa.dupe(u8, "each phase must be an object"), .is_error = true };
        const phase = phase_val.object;
        const title = if (phase.get("title")) |t| (if (t == .string) t.string else "phase") else "phase";
        const tasks_val = phase.get("tasks") orelse return .{
            .text = try gpa.dupe(u8, "each phase needs a tasks array"),
            .is_error = true,
        };
        if (tasks_val != .array) return .{ .text = try gpa.dupe(u8, "phase tasks must be an array"), .is_error = true };
        const tasks = tasks_val.array.items;
        if (tasks.len == 0 or tasks.len > max_workflow_tasks) return .{
            .text = try std.fmt.allocPrint(gpa, "each phase needs 1-{d} tasks", .{max_workflow_tasks}),
            .is_error = true,
        };
        // #5 — conditional phase: skip when its `when` substring is absent from
        // the previous phase's results (case-insensitive). Phase 1 has no prev so
        // its `when` never gates; a skipped phase leaves {{prev}} untouched, so a
        // skipped final phase just returns the prior phase's results (early-exit).
        if (phase_no > 1) if (phase.get("when")) |wv| if (wv == .string and !gateAllows(prev_results, wv.string)) {
            std.debug.print("  [workflow] phase {d}/{d}: {s} — SKIPPED (when \"{s}\" absent)\n", .{ phase_no, phases.len, title, wv.string });
            continue;
        };
        std.debug.print("  [workflow] phase {d}/{d}: {s} ({d} task(s))\n", .{ phase_no, phases.len, title, tasks.len });

        // Resolve prompts: substitute or append the previous phase results.
        // raws keeps each task's pre-substitution spec (a stable eval-set id for
        // scoring, unlike the prev-injected prompt); niches is its MAP-Elites
        // cell — the agent type, else the phase title for an inline variant.
        const prompts = try arena.alloc([]const u8, tasks.len);
        const labels = try arena.alloc([]const u8, tasks.len);
        const overrides = try arena.alloc(?[]const u8, tasks.len);
        const raws = try arena.alloc([]const u8, tasks.len);
        const niches = try arena.alloc([]const u8, tasks.len);
        for (tasks, prompts, labels, overrides, raws, niches) |task_val, *prompt, *label, *override, *rawp, *niche| {
            if (task_val != .object) return .{ .text = try gpa.dupe(u8, "each task must be an object"), .is_error = true };
            const task = task_val.object;
            label.* = if (task.get("description")) |d| (if (d == .string) d.string else "task") else "task";
            override.* = resolveOverride(task);
            const agent_niche = resolveNiche(task);
            niche.* = if (agent_niche.len > 0) agent_niche else title;
            const raw = if (task.get("prompt")) |p| (if (p == .string) p.string else "") else "";
            if (raw.len == 0) return .{ .text = try gpa.dupe(u8, "each task needs a non-empty \"prompt\""), .is_error = true };
            rawp.* = raw;
            if (phase_no == 1) {
                prompt.* = raw;
            } else if (std.mem.indexOf(u8, raw, "{{prev}}") != null) {
                const size = std.mem.replacementSize(u8, raw, "{{prev}}", prev_results);
                const buf = try arena.alloc(u8, size);
                _ = std.mem.replace(u8, raw, "{{prev}}", prev_results, buf);
                prompt.* = buf;
            } else {
                prompt.* = try std.fmt.allocPrint(arena, "{s}\n\nResults from the previous workflow phase:\n\n{s}", .{ raw, prev_results });
            }
        }

        // Join ALL tasks before any fallible work, so an early error return
        // can never abandon running subagents or free their result slots.
        const futures = try arena.alloc(Io.Future(ToolOutput), tasks.len);
        const outputs = try arena.alloc(ToolOutput, tasks.len);
        for (labels, prompts, overrides, niches, futures) |label, prompt, override, niche, *fut| {
            fut.* = ctx.io.async(workflowTask, .{ ctx, label, prompt, override, niche });
        }
        for (futures, outputs) |*fut, *out| out.* = fut.await(ctx.io);
        defer for (outputs) |out| gpa.free(out.text);
        wf_tasks += tasks.len;

        // #2 — Retry transient failures once. A single flaky subagent (an empty
        // report, a dropped stream) shouldn't fail the phase or poison {{prev}}
        // for the next one. We can't reliably tell a transient failure from a
        // deterministic one, so we retry every failure exactly once: a permanent
        // failure just costs one more attempt and stays failed.
        var fidx: [max_workflow_tasks]usize = undefined;
        var nf: usize = 0;
        for (outputs, 0..) |out, i| if (out.is_error) {
            fidx[nf] = i;
            nf += 1;
        };
        if (nf > 0) {
            const refut = try arena.alloc(Io.Future(ToolOutput), nf);
            for (refut, 0..) |*rf, k| {
                const i = fidx[k];
                rf.* = ctx.io.async(workflowTask, .{ ctx, labels[i], prompts[i], overrides[i], niches[i] });
            }
            for (refut, 0..) |*rf, k| {
                const retry = rf.await(ctx.io);
                const i = fidx[k];
                if (!retry.is_error) {
                    gpa.free(outputs[i].text);
                    outputs[i] = retry;
                } else gpa.free(retry.text);
            }
        }
        // Tally this phase's surviving failures into the run total (post-retry,
        // so a recovered task no longer counts). Accumulates across phases, like
        // wf_tasks, for the single end-of-run workflowEvent.
        for (outputs) |out| if (out.is_error) {
            wf_failed += 1;
        };

        // #1 — Ultracode → DGM engine: when ≥2 persona variants competed this
        // phase, score each survivor and submit its niche-tagged fitness so the
        // fleet can rank and promote the winner (docs/hyperagents.md §9.B). The
        // propose half already fired in runSub; this closes the loop runEval left
        // open (it submits niche=""). Gated on the fleet — no judge cost otherwise.
        scoreVariants(ctx, arena, title, prompts, raws, overrides, niches, outputs);

        var aw: Io.Writer.Allocating = .init(arena);
        for (labels, outputs) |label, out| {
            if (out.is_error) {
                // Keep the failure visible to the next phase, but never feed its
                // raw error text into {{prev}} as if it were a real result (#2).
                try aw.writer.print("### {s} (no result — task failed)\n\n", .{label});
            } else {
                try aw.writer.print("### {s}\n{s}\n\n", .{ label, cappedPrevBody(arena, out.text) });
            }
        }
        prev_results = std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
    }
    return .{ .text = try gpa.dupe(u8, prev_results) };
}

// ── Unit tests (`zig build test`) ──────────────────────────────────────────

test "variantJudgePrompt: bounded, names the phase, keeps the score contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big_task = "T" ** 4000;
    const big_out = "O" ** 5000;
    const p = try variantJudgePrompt(a, "code-review", big_task, big_out);

    // Names the shared phase so the judge has the tournament context.
    try std.testing.expect(std.mem.indexOf(u8, p, "\"code-review\" phase") != null);
    // Task is prefix-capped and output tail-capped — neither lands verbatim.
    try std.testing.expect(std.mem.indexOf(u8, p, big_task) == null);
    try std.testing.expect(std.mem.indexOf(u8, p, big_out) == null);
    // The `score:` contract parseEvalScore depends on is spelled out…
    try std.testing.expect(std.mem.indexOf(u8, p, "score: <N>") != null);
    // …and it round-trips: a judge tail like this parses back to the score.
    try std.testing.expectEqual(@as(?f64, 87), parseEvalScore("ok\nscore: 87"));
}

test "cappedPrevBody bounds a wide phase output, keeps head + inspect tail (#4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A short result passes through untouched — most outputs never hit the cap.
    try std.testing.expectEqualStrings("hi", cappedPrevBody(a, "hi"));

    // A huge result is capped: head kept, the trailing inspect: pointer kept,
    // a truncation marker added, and the full text never lands verbatim.
    const big = ("X" ** 9000) ++ "\n[subagent sa-007-abcd · inspect: .graff/subagents/sa-007-abcd.md]";
    const capped = cappedPrevBody(a, big);
    try std.testing.expect(capped.len < big.len);
    try std.testing.expect(capped.len <= max_prev_per_task + 200); // head + tail + marker overhead
    try std.testing.expect(std.mem.indexOf(u8, capped, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "inspect: .graff/subagents/sa-007-abcd.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, big) == null);
}

test "gateAllows: empty when always runs, else case-insensitive substring (#5)" {
    try std.testing.expect(gateAllows("anything", "")); // no gate → always run
    try std.testing.expect(gateAllows("found 3 ISSUES here", "issues")); // case-insensitive hit
    try std.testing.expect(!gateAllows("all clean, no findings", "ISSUE")); // absent → skip
    try std.testing.expect(!gateAllows("", "ready")); // empty prev → skip
}

test "pipelinePrompt substitutes {{item}}/{{prev}} and appends when omitted (#3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // {{item}} substituted on stage 1; no previous-stage section.
    const s1 = try pipelinePrompt(a, "Audit {{item}} for bugs.", "src/x.zig", "", 1);
    try std.testing.expect(std.mem.indexOf(u8, s1, "Audit src/x.zig for bugs.") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1, "previous stage") == null);

    // {{item}} and {{prev}} both substituted on stage 2.
    const s2 = try pipelinePrompt(a, "Given {{prev}}, fix {{item}}.", "src/x.zig", "BUG: off-by-one", 2);
    try std.testing.expect(std.mem.indexOf(u8, s2, "Given BUG: off-by-one, fix src/x.zig.") != null);

    // Omitted placeholders are appended (item on stage 1, prev on stage 2+).
    const s3 = try pipelinePrompt(a, "Summarize the result.", "ticket-7", "DONE", 2);
    try std.testing.expect(std.mem.indexOf(u8, s3, "Item: ticket-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, s3, "Result from the previous stage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, s3, "DONE") != null);
}

test "codedbGuard.referencesSourceFile: concrete code paths, not globs/logs/configs" {
    // The exact #626 screenshot commands — every one reads a source file.
    try std.testing.expect(referencesSourceFile("grep -n \"description\" src/mcp.zig"));
    try std.testing.expect(referencesSourceFile("wc -l src/mcp.zig"));
    try std.testing.expect(referencesSourceFile("sed -n '600,700p' src/mcp.zig"));
    try std.testing.expect(referencesSourceFile("cat gui/src/hooks/types/copy.ts"));
    // Globs are discovery, not a read — codedb glob/tree cover those separately.
    try std.testing.expect(!referencesSourceFile("find . -name '*.zig'"));
    try std.testing.expect(!referencesSourceFile("grep -r foo --include=*.rs ."));
    // No concrete source path → leave it alone (logs, docs, bare commands).
    try std.testing.expect(!referencesSourceFile("grep error /var/log/app.log"));
    try std.testing.expect(!referencesSourceFile("cat README.md"));
    try std.testing.expect(!referencesSourceFile("ls -la"));
    // The command word itself ending in a code ext must not self-trigger.
    try std.testing.expect(!referencesSourceFile("./build.zig"));
}

test "fuzzySubseq matches across punctuation gaps" {
    try std.testing.expect(fuzzySubseq("gpt-5.5", "gpt5.5"));
    try std.testing.expect(fuzzySubseq("claude-opus-4-8", "opus"));
    try std.testing.expect(fuzzySubseq("anything", "")); // empty needle matches
    try std.testing.expect(!fuzzySubseq("gpt-5.5", "xyz"));
    try std.testing.expect(!fuzzySubseq("abc", "abcd")); // needle longer
}

test "fuzzyScore ranks basename prefix above substring above subsequence" {
    // "dem" → demo.py (basename prefix) must beat README.md (subsequence only).
    const demo = fuzzyScore("sdk/py/demo.py", "dem").?;
    const readme = fuzzyScore("README.md", "dem").?;
    try std.testing.expect(demo > readme);
    // substring beats subsequence
    const sub = fuzzyScore("harness.trace.jsonl", "trace").?;
    const seq = fuzzyScore("t-r-a-c-e.txt", "trace").?;
    try std.testing.expect(sub > seq);
    // basename prefix beats mid-path substring
    const base_pre = fuzzyScore("src/main.zig", "main").?;
    const mid = fuzzyScore("domain.zig", "main").?;
    try std.testing.expect(base_pre > mid);
    // whole-string prefix counts even with directories in the hay
    try std.testing.expect(fuzzyScore("sdk/ts/harness.ts", "sdk").? >= 300_000 - 200);
    // no match at all → null; empty needle → 0
    try std.testing.expect(fuzzyScore("abc", "xyz") == null);
    try std.testing.expectEqual(@as(?i32, 0), fuzzyScore("abc", ""));
}

test "pickScore prefers name matches over desc matches" {
    const by_name = pickScore(.{ .name = "/model", .desc = "switch model" }, "model").?;
    const by_desc = pickScore(.{ .name = "/quit", .desc = "model goodbye" }, "model").?;
    try std.testing.expect(by_name > by_desc);
}

test "incremental markdown streaming renders like renderMdLine" {
    // style is the empty default in tests, so styled output == de-marked text.
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &aw.writer,
    };
    defer a.md_buf.deinit(std.testing.allocator);
    defer a.md_word.deinit(std.testing.allocator);
    defer {
        for (a.md_table.items) |r| std.testing.allocator.free(r);
        a.md_table.deinit(std.testing.allocator);
    }

    // Prose is visible word-by-word, before any newline arrives (the
    // word in flight is held for wrap decisions).
    a.streamMarkdown("Hey! I'm her");
    try std.testing.expectEqualStrings("Hey! I'm ", aw.writer.buffered());
    a.streamMarkdown("e and ready\n");
    try std.testing.expectEqualStrings("Hey! I'm here and ready\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Bullets stream too: marker styled up front, text word-by-word, and a
    // split **bold** span styles eagerly (markers dropped as in renderInline).
    a.streamMarkdown("- has **bo");
    try std.testing.expectEqualStrings("• has ", aw.writer.buffered());
    a.streamMarkdown("ld** spans\n");
    try std.testing.expectEqualStrings("• has bold spans\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Numbered items, headers, inline code.
    a.streamMarkdown("12) point\n## Title\nuse `zig build` here\n");
    try std.testing.expectEqualStrings("12. point\nTitle\nuse zig build here\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Fences: open/close render as labeled dim rules, body streams unprefixed.
    a.streamMarkdown("```zig\nconst x = 1;\n```\nafter\n");
    try std.testing.expectEqualStrings("── zig " ++ ("─" ** 33) ++ "\nconst x = 1;\n" ++ ("─" ** 40) ++ "\nafter\n", aw.writer.buffered());
    try std.testing.expect(!a.md_fence);
    aw.clearRetainingCapacity();

    // Horizontal rule renders at line end.
    a.streamMarkdown("---\n");
    try std.testing.expectEqualStrings("────────────\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Tables buffer until the first non-row line, then render aligned:
    // column widths from the widest cell, header above a ─┼─ rule.
    a.streamMarkdown("| Item | Desc |\n| --- | --- |\n| 1 | Inspect files |\n");
    try std.testing.expectEqualStrings("", aw.writer.buffered()); // still buffering
    a.streamMarkdown("| 22 | Edit |\ndone\n");
    try std.testing.expectEqualStrings("Item │ Desc\n" ++
        "─────┼──────────────\n" ++
        "1    │ Inspect files\n" ++
        "22   │ Edit\n" ++
        "done\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // A table pending at stream end flushes from the tail path.
    a.streamMarkdown("| x | y |");
    a.flushStreamTail();
    try std.testing.expectEqualStrings("x │ y\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Stream tail: a partial prose line flushes whatever is pending.
    a.streamMarkdown("tail without newline");
    a.flushStreamTail();
    try std.testing.expectEqualStrings("tail without newline", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Long lines wrap at the terminal edge on word boundaries; bullet
    // continuations align under the text (hanging indent).
    a.md_width = 12; // pinned for the line — mdFinishLine re-reads after
    a.streamMarkdown("- alpha beta gamma\n");
    try std.testing.expectEqualStrings("• alpha beta\n  gamma\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Plain prose wraps at column 0; the break replaces the joining space.
    a.md_width = 10;
    a.streamMarkdown("word1 word2 word3\n");
    try std.testing.expectEqualStrings("word1 \nword2 \nword3\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // A word too wide for any line is not torn — the terminal wraps it.
    a.md_width = 6;
    a.streamMarkdown("abc defghijklm\n");
    try std.testing.expectEqualStrings("abc defghijklm\n", aw.writer.buffered());
}

test "table cell wrapping: fitWidths caps the grid, wrapCell wraps on atoms" {
    // fitWidths shaves the widest column down to the budget, floor 8.
    var widths = [_]usize{ 12, 60, 20 };
    Agent.fitWidths(&widths, 50);
    try std.testing.expectEqual(@as(usize, 50), widths[0] + widths[1] + widths[2]);
    try std.testing.expectEqual(@as(usize, 12), widths[0]); // untouched
    try std.testing.expect(widths[1] >= 8 and widths[2] >= 8);
    // Below the readable floor the widths are left alone.
    var tight = [_]usize{ 20, 20 };
    Agent.fitWidths(&tight, 10);
    try std.testing.expectEqual(@as(usize, 20), tight[0]);

    // wrapCell: greedy word wrap, styled spans atomic, oversized atoms split.
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    Agent.wrapCell(std.testing.allocator, "alpha beta **two words** gamma", 11, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("alpha beta", out.items[0]);
    try std.testing.expectEqualStrings("**two words**", out.items[1]); // 9 visible
    try std.testing.expectEqualStrings("gamma", out.items[2]);
    out.clearRetainingCapacity();
    Agent.wrapCell(std.testing.allocator, "supercalifragilistic", 7, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("superca", out.items[0]);
    out.clearRetainingCapacity();
    Agent.wrapCell(std.testing.allocator, "", 10, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("", out.items[0]);
}

test "ArgLive streams the target argument field across fragment splits" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &aw.writer,
    };
    defer a.partial_text.deinit(std.testing.allocator);

    // attempt_completion: the result value streams as it arrives, with
    // escapes (split across fragments) unescaped.
    a.arg_live.open("attempt_completion", 0);
    a.arg_live.feed(&a, 0, "{\"res");
    a.arg_live.feed(&a, 0, "ult\": \"Hello ");
    try std.testing.expectEqualStrings("Hello ", aw.writer.buffered());
    a.arg_live.feed(&a, 0, "line\\");
    a.arg_live.feed(&a, 0, "nnext \\\"q\\\"");
    try std.testing.expectEqualStrings("Hello line\nnext \"q\"", aw.writer.buffered());
    a.arg_live.feed(&a, 0, "\"}");
    try std.testing.expectEqualStrings("Hello line\nnext \"q\"", aw.writer.buffered());
    try std.testing.expect(a.streamed_args == .attempt_completion);
    // The emitted byte count matches the parsed value — re-print suppressible.
    try std.testing.expectEqual("Hello line\nnext \"q\"".len, a.streamed_args_len);
    aw.clearRetainingCapacity();

    // ask_user: a non-target field first (options array with tricky strings)
    // is skipped; the question prints. \u escapes decode, surrogate pairs too.
    a.streamed_args = .none;
    a.arg_live.open("ask_user", 2);
    a.arg_live.feed(&a, 2, "{\"options\": [\"a \\\"x\\\"\", \"b, {c}\"], ");
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    a.arg_live.feed(&a, 2, "\"question\": \"caf\\u00e9 \\ud83d\\ude00?\"}");
    try std.testing.expectEqualStrings("café 😀?", aw.writer.buffered());
    try std.testing.expect(a.streamed_args == .ask_user);
    try std.testing.expectEqual("café 😀?".len, a.streamed_args_len);
    aw.clearRetainingCapacity();

    // Wrong index and non-whitelisted tools print nothing.
    a.streamed_args = .none;
    a.arg_live.feed(&a, 5, "{\"question\": \"nope\"}");
    a.arg_live.open("bash", 3);
    a.arg_live.feed(&a, 3, "{\"result\": \"nope\"}");
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    try std.testing.expect(a.streamed_args == .none);
}

test "assembleOpenAI preserves streamed reasoning history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };

    const root = (try agent.assembleOpenAI(
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think \"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"deep\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning\":\"alt \"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning\":\"path\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n" ++
            "data: [DONE]\n",
    )).?;
    const choices = root.get("choices").?;
    const message = choices.array.items[0].object.get("message").?.object;
    try std.testing.expectEqualStrings("assistant", message.get("role").?.string);
    try std.testing.expectEqualStrings("done", message.get("content").?.string);
    try std.testing.expectEqualStrings("think deep", message.get("reasoning_content").?.string);
    try std.testing.expectEqualStrings("alt path", message.get("reasoning").?.string);
}

test "utf8Prefix truncates without splitting codepoints" {
    try std.testing.expectEqualStrings("abc", utf8Prefix("abc", 10));
    const s = [_]u8{ 'a', 'b', 0xC3, 0xA9, 'c' }; // "abéc"
    try std.testing.expectEqualStrings("ab", utf8Prefix(&s, 3)); // é would split
    try std.testing.expectEqualStrings("ab\xC3\xA9", utf8Prefix(&s, 4));
}

test "cleanDroppedPath unescapes terminal drops" {
    const gpa = std.testing.allocator;
    const p = cleanDroppedPath(gpa, "", "/tmp/My\\ File.txt ") orelse return error.TestUnexpectedResult;
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/tmp/My File.txt", p);
    const q = cleanDroppedPath(gpa, "/home/u", "'~/notes/a b.md'") orelse return error.TestUnexpectedResult;
    defer gpa.free(q);
    try std.testing.expectEqualStrings("/home/u/notes/a b.md", q);
    try std.testing.expect(cleanDroppedPath(gpa, "", "hello world") == null); // not absolute
    try std.testing.expect(cleanDroppedPath(gpa, "", "two\nlines") == null); // multi-line
}

test "resolveModelName exact aliases and miss" {
    const keys = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expect(resolveModelName(keys, "gpt-5.5") != null); // exact name
    try std.testing.expectEqualStrings("glm-5.2", resolveModelName(keys, "glm5.2").?); // natural alias
    try std.testing.expect(resolveModelName(keys, "totally-unknown-zzz") == null);
}

test "binaryFileExt flags binaries, passes text" {
    try std.testing.expect(binaryFileExt("paper.pdf"));
    try std.testing.expect(binaryFileExt("shot.PNG")); // case-insensitive
    try std.testing.expect(binaryFileExt("lib.a"));
    try std.testing.expect(!binaryFileExt("main.zig"));
    try std.testing.expect(!binaryFileExt("README.md"));
    try std.testing.expect(!binaryFileExt("Makefile")); // no extension
    try std.testing.expect(isImagePath("a.jpeg"));
    try std.testing.expect(!isImagePath("a.pdf"));
}

test "wrapAt: rows and columns across the right edge" {
    // No prompt, 10-column terminal: bytes 0..9 fill row 0.
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 10, 0).row);
    try std.testing.expectEqual(@as(usize, 5), wrapAt(0, 10, 5).col);
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 10, 9).row);
    // Byte 10 is the first cell of row 1.
    try std.testing.expectEqual(@as(usize, 1), wrapAt(0, 10, 10).row);
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 10, 10).col);
    // Byte 25 → row 2, col 5.
    try std.testing.expectEqual(@as(usize, 2), wrapAt(0, 10, 25).row);
    try std.testing.expectEqual(@as(usize, 5), wrapAt(0, 10, 25).col);
}

test "wrapAt: a prompt prefix shifts the whole line right" {
    // 4-column prompt: byte 5 sits at column 9 of row 0 (4+5).
    try std.testing.expectEqual(@as(usize, 0), wrapAt(4, 10, 5).row);
    try std.testing.expectEqual(@as(usize, 9), wrapAt(4, 10, 5).col);
    // byte 6 → 4+6 == 10 → row 1, col 0.
    try std.testing.expectEqual(@as(usize, 1), wrapAt(4, 10, 6).row);
    try std.testing.expectEqual(@as(usize, 0), wrapAt(4, 10, 6).col);
}

test "wrapAt: zero columns never divides by zero" {
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 0, 3).col);
}

test "parseDsrCol: well-formed and malformed replies" {
    try std.testing.expectEqual(@as(?usize, 34), parseDsrCol("[12;34R"));
    try std.testing.expectEqual(@as(?usize, 1), parseDsrCol("[1;1R"));
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("[12R")); // no column
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("[1;0R")); // col 0 is meaningless
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("[1;xR"));
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("12;34R")); // missing CSI intro
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol(""));
}

test "scoreSigMessage: canonical bytes are cross-language stable" {
    // The Python SDK (score_signature) and the telemetry worker recompute
    // this byte-for-byte; {d:.6} drifting would silently break every sig.
    var buf: [512]u8 = undefined;
    const msg = scoreSigMessage(&buf, "a1b2", "c3d4", 0.5, "run1", "replay-v1", "art", "evalhash").?;
    try std.testing.expectEqualStrings("v1\na1b2\nc3d4\n0.500000\nrun1\nreplay-v1\nart\nevalhash", msg);
    const empty = scoreSigMessage(&buf, "a1b2", "", 1.0, "", "", "", "").?;
    try std.testing.expectEqualStrings("v1\na1b2\n\n1.000000\n\n\n\n", empty);
}

test "blankText: webfetch empty-output heuristic" {
    try std.testing.expect(blankText(""));
    try std.testing.expect(blankText("   \n\n\t\r\n  \n")); // SPA: pages of blank lines
    try std.testing.expect(blankText("ok\n")); // a couple of stray chars is still no content
    try std.testing.expect(!blankText("# Example Domain\n\nThis domain is for use..."));
}

test "companion trust: whole suite skips the gate; plan mode only frees read-only calls" {
    try std.testing.expect(companionTrusted("mcp__codedbpro__read"));
    try std.testing.expect(companionTrusted("mcp__codedbpro__edit"));
    try std.testing.expect(companionTrusted("mcp__muonry__read")); // legacy alias
    try std.testing.expect(companionTrusted("mcp__muonry__batch"));
    try std.testing.expect(!companionTrusted("mcp__other__read"));
    try std.testing.expect(!companionTrusted("read_file"));
}

test "companionReadOnly: the plan-mode classifier mirrors readOnlyHint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    const none = Value{ .null = {} };
    try std.testing.expect(companionReadOnly("mcp__codedbpro__read", none));
    try std.testing.expect(companionReadOnly("mcp__codedbpro__search", none));
    try std.testing.expect(companionReadOnly("mcp__codedbpro__faster_search", none));
    try std.testing.expect(companionReadOnly("mcp__muonry__read", none)); // legacy alias
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__edit", none));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__patch", none));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__memo", none));
    try std.testing.expect(!companionReadOnly("mcp__other__read", none)); // only the trusted server
    try std.testing.expect(!companionReadOnly("read_file", none));
    // batch: read-only iff every op is
    try std.testing.expect(companionReadOnly("mcp__codedbpro__batch", parse(a,
        \\{"ops":[{"tool":"read","args":{}},{"tool":"search","args":{}}]}
    )));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__batch", parse(a,
        \\{"ops":[{"tool":"read","args":{}},{"tool":"edit","args":{}}]}
    )));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__batch", parse(a, "{\"ops\":[]}")));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__batch", parse(a, "{}")));
}

test "companionNativeFallback: every companion tool maps to a native equivalent" {
    try std.testing.expectEqualStrings("read_file tool", companionNativeFallback("read"));
    try std.testing.expectEqualStrings("edit_file tool", companionNativeFallback("patch"));
    try std.testing.expectEqualStrings("edit_file tool", companionNativeFallback("edit"));
    try std.testing.expectEqualStrings("write_file tool", companionNativeFallback("create"));
    try std.testing.expect(std.mem.indexOf(u8, companionNativeFallback("faster_search"), "codedb") != null);
    // an unknown/new companion tool still gets a sane native pointer
    try std.testing.expect(std.mem.indexOf(u8, companionNativeFallback("memo"), "native") != null);
}

test "companionToolName: strips either server prefix, else null" {
    try std.testing.expectEqualStrings("read", companionToolName("mcp__codedbpro__read").?);
    try std.testing.expectEqualStrings("faster_search", companionToolName("mcp__codedbpro__faster_search").?);
    try std.testing.expectEqualStrings("batch", companionToolName("mcp__muonry__batch").?); // legacy alias
    try std.testing.expect(companionToolName("mcp__other__read") == null);
    try std.testing.expect(companionToolName("read_file") == null);
    try std.testing.expect(companionToolName("codedb") == null); // free codedb is a native tool, not a companion
}

test "companion_servers: codedb-pro is the preferred target, muonry the legacy alias" {
    try std.testing.expectEqualStrings("codedbpro", companion_servers[0].server);
    try std.testing.expectEqualStrings("codedb-pro", companion_servers[0].bin);
    try std.testing.expectEqualStrings("muonry", companion_servers[1].server);
    try std.testing.expectEqualStrings("muonry", companion_servers[1].bin);
}

test "mcpServerConnected: detects codedb-pro by its qualified prefix" {
    const tools = [_]mcp.Tool{
        .{ .server_index = 0, .original_name = "search", .qualified_name = "mcp__codedbpro__search", .description = "", .input_schema = .null },
    };
    try std.testing.expect(mcpServerConnected(&tools, "codedbpro"));
    try std.testing.expect(!mcpServerConnected(&tools, "muonry"));
    try std.testing.expect(!mcpServerConnected(&tools, "codedb")); // native codedb tool isn't an MCP server
}

test "mcpServerConnected: prefix match on qualified names" {
    const tools = [_]mcp.Tool{
        .{ .server_index = 0, .original_name = "read", .qualified_name = "mcp__muonry__read", .description = "", .input_schema = .null },
        .{ .server_index = 0, .original_name = "edit", .qualified_name = "mcp__muonry__edit", .description = "", .input_schema = .null },
    };
    try std.testing.expect(mcpServerConnected(&tools, "muonry"));
    try std.testing.expect(!mcpServerConnected(&tools, "muon")); // no partial server names
    try std.testing.expect(!mcpServerConnected(&tools, "codedb"));
    try std.testing.expect(!mcpServerConnected(&.{}, "muonry"));
}

test "skillDisabled: registry lookup and toggle" {
    const i = skillIndex("kuri").?;
    const saved = g_skill_disabled[i];
    defer g_skill_disabled[i] = saved;
    g_skill_disabled[i] = false;
    try std.testing.expect(!skillDisabled("kuri"));
    g_skill_disabled[i] = true;
    try std.testing.expect(skillDisabled("kuri"));
    try std.testing.expect(!skillDisabled("not-a-skill"));
}

test "companion opt-out: {\"skills\":{\"codedbpro\":false}} disables auto-connect" {
    // applySkillSettings is the pure half of loadSkillSettings; prove the
    // settings key flips companionDisabled(), the flag the auto-connect reads.
    const saved_companion = g_companion_disabled;
    const ki = skillIndex("kuri").?;
    const saved_kuri = g_skill_disabled[ki];
    defer {
        g_companion_disabled = saved_companion;
        g_skill_disabled[ki] = saved_kuri;
    }
    g_companion_disabled = [_]bool{false} ** companion_servers.len;
    g_skill_disabled[ki] = false;

    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const json = "{\"skills\":{\"codedbpro\":false,\"kuri\":false}}";
    const v = try std.json.parseFromSliceLeaky(Value, arena_inst.allocator(), json, .{ .allocate = .alloc_always });
    applySkillSettings(v.object.get("skills").?);

    try std.testing.expect(companionDisabled("codedbpro")); // the fix: was always false before
    try std.testing.expect(skillDisabled("kuri")); // existing registry path still works
    try std.testing.expect(!companionDisabled("not-a-server"));
}

test "codedbproNote: licensed flips codedbpro to the lean-in note" {
    const cons = "CONSERVATIVE-NOTE";
    try std.testing.expectEqualStrings(cons, codedbproNote("codedbpro", false, cons)); // unlicensed -> conservative
    try std.testing.expectEqualStrings(cons, codedbproNote("muonry", true, cons)); // other servers untouched
    try std.testing.expectEqualStrings(codedbpro_note_licensed, codedbproNote("codedbpro", true, cons)); // licensed -> lean-in
    try std.testing.expect(std.mem.indexOf(u8, codedbpro_note_licensed, "mcp__codedbpro__read") != null);
    try std.testing.expect(std.mem.indexOf(u8, codedbpro_note_licensed, "/rewind") != null);
}

test "parseAnswerRequest: preserves multiline text and optional call id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"answer","text":"line 1\nline 2","cancelled":false,"call_id":"call-1"}
    , .{});
    const answer = try parseAnswerRequest(v, "call-1");
    try std.testing.expectEqualStrings("line 1\nline 2", answer.text);
    try std.testing.expectEqualStrings("call-1", answer.call_id);
    try std.testing.expect(!answer.cancelled);
}

test "parseAnswerRequest: explicit cancel and mismatched call id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cancelled = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"answer","cancelled":true,"call_id":"call-1"}
    , .{});
    const answer = try parseAnswerRequest(cancelled, "call-1");
    try std.testing.expect(answer.cancelled);
    try std.testing.expectEqualStrings("", answer.text);

    const mismatch = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"answer","text":"nope","call_id":"call-2"}
    , .{});
    try std.testing.expectError(error.AnswerCallIdMismatch, parseAnswerRequest(mismatch, "call-1"));
}

test { // pull in tests from imported modules (mcp.zig)
    _ = mcp;
}

test "Agent.firstWord: splits the command on the first whitespace" {
    try std.testing.expectEqualStrings("git", Agent.firstWord("git status -s"));
    try std.testing.expectEqualStrings("ls", Agent.firstWord("ls"));
    try std.testing.expectEqualStrings("cat", Agent.firstWord("cat\tfile")); // tab delimiter
    try std.testing.expectEqualStrings("", Agent.firstWord(""));
    try std.testing.expectEqualStrings("", Agent.firstWord(" leading"));
}

test "Provider.compactAt: auto-compacts at 80% of the context window (long-horizon trigger)" {
    const big = Provider{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "m", .context = 1_000_000 };
    try std.testing.expectEqual(@as(u64, 800_000), big.compactAt());
    const small = Provider{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "m", .context = 200_000 };
    try std.testing.expectEqual(@as(u64, 160_000), small.compactAt());
    const zero = Provider{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "m", .context = 0 };
    try std.testing.expectEqual(@as(u64, 0), zero.compactAt());
}

test "Agent.cleanUserTurn: plain user text yes; assistant/tool_result no" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(Agent.cleanUserTurn(try textMessage(a, "user", "hello")));
    try std.testing.expect(!Agent.cleanUserTurn(try textMessage(a, "assistant", "hi")));
    // an anthropic tool_result-only user message is NOT a clean conversation start
    const tr = try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}", .{});
    try std.testing.expect(!Agent.cleanUserTurn(tr));
}

test "Agent.emergencyCutIndex: cuts at a clean user turn at/after the midpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    const roles = [_][]const u8{ "user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant" };
    for (roles) |r| try items.append(try textMessage(a, r, "x"));
    try std.testing.expectEqual(@as(?usize, 4), Agent.emergencyCutIndex(items.items)); // midpoint 4 is a user turn
    try std.testing.expectEqual(@as(?usize, null), Agent.emergencyCutIndex(items.items[0..3])); // too short to trim
}

test "Agent.emergencyCutIndex: skips a tool_result user message at the midpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    try items.append(try textMessage(a, "user", "x")); // 0
    try items.append(try textMessage(a, "assistant", "x")); // 1
    try items.append(try textMessage(a, "user", "x")); // 2
    try items.append(try textMessage(a, "assistant", "x")); // 3
    // 4: an anthropic tool_result-only user message (not a valid conversation start)
    try items.append(try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"x\"}]}", .{})); // 4 (skip)
    try items.append(try textMessage(a, "assistant", "x")); // 5
    try items.append(try textMessage(a, "user", "x")); // 6 (first clean user >= midpoint)
    try items.append(try textMessage(a, "assistant", "x")); // 7
    try std.testing.expectEqual(@as(?usize, 6), Agent.emergencyCutIndex(items.items));
}

test "Keys.providerFor: known model, claude/gateway fallbacks, missing key" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const none = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expectEqualStrings("anthropic", (try all.providerFor("claude-does-not-exist")).id);
    try std.testing.expectEqualStrings("codegraff", (try all.providerFor("totally-made-up-model")).id);
    try std.testing.expectEqualStrings("gpt-5.5", (try all.providerFor("gpt-5.5")).model);
    try std.testing.expectError(error.MissingKey, none.providerFor("claude-opus-4-8"));
}

test "Keys.providerById: exact id wins, unknown id falls back to model routing" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const p = try all.providerById("anthropic", "claude-opus-4-8");
    try std.testing.expectEqualStrings("anthropic", p.id);
    try std.testing.expectEqualStrings("claude-opus-4-8", p.model);
    const fb = try all.providerById("no-such-provider", "gpt-5.5");
    try std.testing.expectEqualStrings("gpt-5.5", fb.model);
}

test "set_model control resolves explicit provider/model fields" {
    var all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const codex = try resolveProviderControlRequest(&all, arena, "codex", "gpt-5.5", "");
    try std.testing.expectEqualStrings("codex", codex.id);
    try std.testing.expectEqualStrings("gpt-5.5", codex.model);

    const legacy = try resolveProviderControlRequest(&all, arena, "", "", "codegraff gpt-5.5");
    try std.testing.expectEqualStrings("codegraff", legacy.id);
    try std.testing.expectEqualStrings("gpt-5.5", legacy.model);
}

test "Keys.defaultProvider: first keyed provider on its default model" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const p = try all.defaultProvider();
    try std.testing.expectEqualStrings("anthropic", p.id); // anthropic leads provider_specs
    try std.testing.expectEqualStrings("claude-opus-4-8", p.model);
    const none = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expectError(error.MissingKey, none.defaultProvider());
}

test "ultracode toggle choices put the opposite state first" {
    try std.testing.expectEqualStrings("on", ultracodeToggleItems(false)[0].name);
    try std.testing.expectEqualStrings("off", ultracodeToggleItems(false)[1].name);
    try std.testing.expectEqualStrings("off", ultracodeToggleItems(true)[0].name);
    try std.testing.expectEqualStrings("on", ultracodeToggleItems(true)[1].name);
}

test "applyUltracodeSteering handles explicit and persistent modes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const plain = try applyUltracodeSteering(a, "fix this", false);
    try std.testing.expect(!plain.explicit);
    try std.testing.expectEqualStrings("fix this", plain.text);

    const persistent = try applyUltracodeSteering(a, "fix this", true);
    try std.testing.expect(!persistent.explicit);
    try std.testing.expect(std.mem.indexOf(u8, persistent.text, "ultracode mode is enabled") != null);

    const explicit = try applyUltracodeSteering(a, "ultracode fix this", true);
    try std.testing.expect(explicit.explicit);
    try std.testing.expect(std.mem.indexOf(u8, explicit.text, "user invoked the \"ultracode\" codeword") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit.text, "ultracode mode is enabled") == null);
}

test "fillCompletions includes ultracode slash command" {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    _ = fillCompletions(std.testing.allocator, "/ult", &out);
    var found = false;
    for (out.items) |item| {
        if (std.mem.eql(u8, item, "/ultracode")) found = true;
    }
    try std.testing.expect(found);
}

test "strField/intField: typed JSON field extraction, null on wrong type or non-object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = std.json.parseFromSliceLeaky(Value, a, "{\"s\":\"hi\",\"n\":42,\"b\":true}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("hi", strField(v, "s").?);
    try std.testing.expect(strField(v, "n") == null); // present but not a string
    try std.testing.expect(strField(v, "missing") == null);
    try std.testing.expect(strField(Value{ .null = {} }, "s") == null); // non-object input
    try std.testing.expectEqual(@as(i64, 42), intField(v, "n").?);
    try std.testing.expect(intField(v, "s") == null); // present but not an integer
    try std.testing.expect(intField(v, "missing") == null);
}

test "missingArg: builds an is_error result naming the argument" {
    const o = try missingArg(std.testing.allocator, "path");
    defer std.testing.allocator.free(o.text);
    try std.testing.expect(o.is_error);
    try std.testing.expect(std.mem.indexOf(u8, o.text, "path") != null);
}

test "extractText: string content, joined text blocks, and empties" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plain = std.json.parseFromSliceLeaky(Value, a, "{\"content\":\"plain\"}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("plain", extractText(a, plain));
    const blocks = std.json.parseFromSliceLeaky(Value, a, "{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("a\nb", extractText(a, blocks));
    const empty = std.json.parseFromSliceLeaky(Value, a, "{}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("", extractText(a, empty));
    try std.testing.expectEqualStrings("", extractText(a, Value{ .null = {} }));
}

test "translateHistory: flattens to {role,content:string}, keeps user/assistant, drops the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mk = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    var msgs = std.json.Array.init(a);
    try msgs.append(mk(a, "{\"role\":\"system\",\"content\":\"sys\"}")); // dropped
    try msgs.append(mk(a, "{\"role\":\"user\",\"content\":\"hello\"}")); // kept
    try msgs.append(mk(a, "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}")); // flattened
    try msgs.append(mk(a, "{\"role\":\"tool\",\"content\":\"result\"}")); // dropped
    try msgs.append(mk(a, "{\"role\":\"user\",\"content\":\"   \"}")); // whitespace-only -> dropped
    translateHistory(a, &msgs, .anthropic);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("user", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("hello", msgs.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", msgs.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("hi", msgs.items[1].object.get("content").?.string);
}

test "isImagePath: known image extensions, case-insensitive" {
    try std.testing.expect(isImagePath("photo.png"));
    try std.testing.expect(isImagePath("a.JPEG"));
    try std.testing.expect(isImagePath("x.webp"));
    try std.testing.expect(isImagePath("dir/sub/pic.gif"));
    try std.testing.expect(!isImagePath("readme.md"));
    try std.testing.expect(!isImagePath("noext"));
    try std.testing.expect(!isImagePath("archive.tar.gz"));
}

test "skillIndex: registry lookup" {
    try std.testing.expect(skillIndex("graff") != null);
    try std.testing.expect(skillIndex("kuri") != null);
    try std.testing.expect(skillIndex("nonexistent-skill") == null);
}

test "Agent.codepointCount: counts UTF-8 codepoints, not bytes" {
    try std.testing.expectEqual(@as(usize, 5), Agent.codepointCount("hello"));
    try std.testing.expectEqual(@as(usize, 0), Agent.codepointCount(""));
    try std.testing.expectEqual(@as(usize, 1), Agent.codepointCount("é")); // 2 bytes, 1 codepoint
    try std.testing.expectEqual(@as(usize, 3), Agent.codepointCount("a→b")); // arrow is 3 bytes
}

test "Agent.inlineVisibleLen: matched **bold**/`code` markers drop from the visible width" {
    try std.testing.expectEqual(@as(usize, 5), Agent.inlineVisibleLen("hello"));
    try std.testing.expectEqual(@as(usize, 4), Agent.inlineVisibleLen("**bold**"));
    try std.testing.expectEqual(@as(usize, 4), Agent.inlineVisibleLen("`code`"));
    try std.testing.expectEqual(@as(usize, 1), Agent.inlineVisibleLen("é")); // wide glyph counts as one column
    try std.testing.expectEqual(@as(usize, 2), Agent.inlineVisibleLen("**")); // unmatched marker is literal
}

test "Agent.isTableSeparator: only |, -, :, space and at least one dash" {
    try std.testing.expect(Agent.isTableSeparator("|---|---|"));
    try std.testing.expect(Agent.isTableSeparator("| :--- | ---: |"));
    try std.testing.expect(Agent.isTableSeparator("---"));
    try std.testing.expect(!Agent.isTableSeparator("| a | b |")); // letters
    try std.testing.expect(!Agent.isTableSeparator("|   |   |")); // no dash
    try std.testing.expect(!Agent.isTableSeparator("")); // empty
}

test "apiErrorMessage: object-message, bare-string, and absent envelopes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mk = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    try std.testing.expectEqualStrings("bad thing", apiErrorMessage(mk(a, "{\"error\":{\"message\":\"bad thing\"}}").object).?);
    // codegraff gateway shape: error is a bare string (the grok-build case)
    try std.testing.expectEqualStrings(
        "Model grok-build-0.1 does not support parameter reasoningEffort.",
        apiErrorMessage(mk(a, "{\"code\":\"invalid-argument\",\"error\":\"Model grok-build-0.1 does not support parameter reasoningEffort.\"}").object).?,
    );
    try std.testing.expect(apiErrorMessage(mk(a, "{\"choices\":[]}").object) == null);
    try std.testing.expect(apiErrorMessage(mk(a, "{\"error\":null}").object) == null);
}

test "mentionsReasoningEffort: matches snake_case and camelCase wording" {
    try std.testing.expect(mentionsReasoningEffort("Unknown parameter: reasoning_effort"));
    try std.testing.expect(mentionsReasoningEffort("Model X does not support parameter reasoningEffort."));
    try std.testing.expect(!mentionsReasoningEffort("some other error"));
}

test "absolute path prompts are not mistaken for slash commands" {
    try std.testing.expect(isSlashCommandLine("/"));
    try std.testing.expect(isSlashCommandLine("/help"));
    try std.testing.expect(isSlashCommandLine("/bash echo hi"));
    try std.testing.expect(isSlashCommandLine("/not-a-command"));

    try std.testing.expect(!isSlashCommandLine("/System/Library/PrivateFrameworks/StorageManagement.framework/PlugIns/StorageManagementService what causes this to start"));
    try std.testing.expect(!isSlashCommandLine("/Users/blackfloofie/codedb/src/main.zig explain this"));
}

test "/bash slash command runs the bash tool and frees its gpa-allocated result" {
    // Regression guard for PR #38: the /bash slash handler routes through
    // execTool, whose result.text is gpa-owned (NOT arena-owned — every other
    // caller frees it). Forgetting `defer root.gpa.free(result.text)` in
    // handleCommand leaks on every /bash invocation; std.testing.allocator
    // catches that here.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = .{
            .id = "test",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "",
            .model = "m",
            .context = 100_000,
        },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
    var keys: Keys = .{ .values = [_]?[]const u8{null} ** provider_specs.len };

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    defer root.tools_used.deinit(gpa);
    try handleCommand(&root, &keys, arena, "/bash echo leak-guard-XYZ", &aw.writer);

    const written = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "leak-guard-XYZ") != null);
}

test "slugifyTitle makes a filesystem-safe slug from an AI title" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("fixing-the-login-bug", slugifyTitle(a, "Fixing the login bug"));
    try std.testing.expectEqualStrings("add-dark-mode", slugifyTitle(a, "Add dark mode!!"));
    try std.testing.expectEqualStrings("planning-v2", slugifyTitle(a, "  Planning — v2  ")); // trim + collapse
    try std.testing.expectEqualStrings("", slugifyTitle(a, "🎉 ✨")); // symbol-only → "" (keeps the session-<ts> name)
}
