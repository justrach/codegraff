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

// The Agent struct's method bodies are split across agent_*.zig sibling
// files (#123, 600-line goal) as free `pub fn method(self: *Agent, ...)`
// functions, member-aliased back inside `struct Agent` (`pub const method =
// @import("agent_x.zig").method;`) so both `self.method(...)` and static
// `Agent.method(...)` test calls resolve unchanged. Referenced here only to
// keep their test blocks running (see the root test{} block below).
const agent_table = @import("agent_table.zig");
const agent_argstream = @import("agent_argstream.zig");
const agent_render = @import("agent_render.zig");
const agent_steps = @import("agent_steps.zig");
const agent_compact = @import("agent_compact.zig");
const agent_tools = @import("agent_tools.zig");
const agent_request = @import("agent_request.zig");
const agent_interrupt = @import("agent_interrupt.zig");
const agent_stream = @import("agent_stream.zig");

pub const anthropic_version = "2023-06-01";
pub const max_tokens = 16000;
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
pub var show_timing = false;
var show_cost = false;
pub var json_mode = false; // --json: structured JSONL events on stdout instead of human text
pub var max_tool_calls: ?u64 = null; // --max-tool-calls: hard per-turn root tool budget
pub var dedupe_tool_calls = false; // --dedupe-tool-calls: reject duplicate root calls in a turn
pub var plan_mode = false; // /plan: read-only — mutating tools are denied, the model proposes
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
    _ = prompts;
    _ = session;
    _ = keys_cli;
    _ = repl_glue;
    _ = vision;
    _ = providers;
    _ = pickers;
    _ = skills;
    _ = input_util;
    _ = readline_mod;
    _ = tools_mod;
    _ = subagent;
    _ = workflow;
    _ = exec;
    _ = commands_session;
    _ = commands_model;
    _ = commands_misc;
    _ = agent_table;
    _ = agent_argstream;
    _ = agent_render;
    _ = agent_steps;
    _ = agent_compact;
    _ = agent_tools;
    _ = agent_request;
    _ = agent_interrupt;
    _ = agent_stream;
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

// System-prompt text (main_system_prompt, strict_note,
// main_system_prompt_strict, sub_system_prompt, compact_instruction) lives in
// prompts.zig (600-line goal, #123). All aliased back — the Agent struct's
// default field values and main()'s prompt-selection logic read unchanged.
// compact_instruction stays pub (agent_compact.zig back-imports it).
const prompts = @import("prompts.zig");
const main_system_prompt = prompts.main_system_prompt;
const strict_note = prompts.strict_note;
const main_system_prompt_strict = prompts.main_system_prompt_strict;
const sub_system_prompt = prompts.sub_system_prompt;
pub const compact_instruction = prompts.compact_instruction;

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
pub const Keys = struct {
    values: [provider_specs.len]?[]const u8,
    codex_account: []const u8 = "", // ChatGPT account id for the codex provider

    pub fn get(keys: Keys, provider_id: []const u8) ?[]const u8 {
        for (provider_specs, keys.values) |spec, value| {
            if (std.mem.eql(u8, spec.id, provider_id)) return value;
        }
        return null;
    }

    pub fn build(keys: Keys, spec: ProviderSpec, key: []const u8, model: []const u8) Provider {
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
    pub fn providerFor(keys: Keys, model: []const u8) error{MissingKey}!Provider {
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
    pub fn providerById(keys: Keys, id: []const u8, model: []const u8) error{MissingKey}!Provider {
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
pub const ReasoningEffort = enum { low, medium, high };

pub const repl_commands = [_][]const u8{ "/model", "/models", "/clear", "/new", "/rename", "/goal", "/loop", "/bash", "/plan", "/key", "/keepcontext", "/effort", "/fast", "/ultracode", "/thinking", "/title", "/reasoning", "/strict", "/yolo", "/trace", "/fleet", "/trajectory", "/agents", "/skills", "/hooks", "/compact", "/rewind", "/image", "/paste", "/save", "/resume", "/sessions", "/todo", "/jobs", "/cost", "/animation", "/theme", "/mcp", "/help" };

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

pub var g_hooks: hooks.Hooks = .{};

/// Built-in codedb guard (issue #626): when a repo is codedb-indexed, agents
/// reflexively grep/sed/cat source files and never touch the structural tools,
/// so codedb degrades to "ripgrep with smaller output." When on, a bash command
/// that scans/reads a concrete source file is blocked with a redirect to the
/// codedb tool. Off when GRAFF_NO_CODEDB_GUARD is set; the tri-state cache
/// records whether `codedb` is actually on PATH (no redirect if it isn't).
pub var g_codedb_guard = true;
pub var g_codedb_present: ?bool = null;

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
pub fn codedbFileIndexed(io: Io, gpa: Allocator, path: []const u8) bool {
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

// Codex-style optional skills / companion-server subsystem (skills_registry,
// companion_servers, mcp_notes, install-status + opt-out helpers, the
// companion tool-name classifiers, and the codedbpro license probe + note
// picker) lives in skills.zig (600-line goal). companionRoute and
// companionNativeFallback moved to tools.zig (they take ToolCtx/ToolCall —
// the tools/exec region). g_path_env/g_skill_disabled/g_companion_disabled
// stay `pub var` here (main's own /skills command handler + startup code
// read/write them directly too); skills.zig reads/writes them live via
// main_mod.g_x, never by-value.
const skills = @import("skills.zig");
const skills_registry = skills.skills_registry;
const mcp_notes = skills.mcp_notes;
pub const companion_servers = skills.companion_servers;
const companionToolName = skills.companionToolName;
const companionTrusted = skills.companionTrusted;
const companionReadOnly = skills.companionReadOnly;
const mcpServerConnected = skills.mcpServerConnected;
const binOnPath = skills.binOnPath;
const skillInstalled = skills.skillInstalled;
const skillIndex = skills.skillIndex;
const skillDisabled = skills.skillDisabled;
const companionDisabled = skills.companionDisabled;
const probeCodedbproLicensed = skills.probeCodedbproLicensed;
const codedbproNote = skills.codedbproNote;
const skillActive = skills.skillActive;
const loadSkillSettings = skills.loadSkillSettings;
const saveSkillSetting = skills.saveSkillSetting;

/// PATH captured at startup for skill detection (PATH won't change mid-run).
pub var g_path_env: []const u8 = "";
/// Human-facing current workspace folder shown in the REPL prompt.
pub var g_cwd_display: []const u8 = ".";
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
// The `graff repl` bridge (ReplCtx/ReplStreamSink + replTurnCb/ModelCb/
// CancelCb), the goal/eval steering-note assembly, the Codex-style steering
// queue drain (popSteer/resetSteerPartial/steerEcho), and the /effort /fast
// /ultracode persistence (save/loadThinkingSettings) live in repl_glue.zig
// (600-line goal, #123). parseEvalScore/steerEcho/saveThinkingSettings stay
// pub — subagent.zig, agent_compact.zig, agent_interrupt.zig, and
// commands_model.zig already back-import them as `main_mod.X`. The mutable
// steer/thinking globals below (g_steer_buf, g_steer_queue, g_steer_echoed,
// g_steer_visible, g_out) stay here and are read/written live via
// `main_mod.g_x` from repl_glue.zig (never aliased — they're `var`s).
const repl_glue = @import("repl_glue.zig");
const ReplCtx = repl_glue.ReplCtx;
const ReplStreamSink = repl_glue.ReplStreamSink;
const goalSteeringNote = repl_glue.goalSteeringNote;
pub const parseEvalScore = repl_glue.parseEvalScore;
const evalSteeringNote = repl_glue.evalSteeringNote;
const replTurnCb = repl_glue.replTurnCb;
const replModelCb = repl_glue.replModelCb;
const replCancelCb = repl_glue.replCancelCb;
const popSteer = repl_glue.popSteer;
const resetSteerPartial = repl_glue.resetSteerPartial;
pub const steerEcho = repl_glue.steerEcho;
pub const saveThinkingSettings = repl_glue.saveThinkingSettings;
const loadThinkingSettings = repl_glue.loadThinkingSettings;

/// Per-skill user opt-out, persisted as {"skills": {"kuri": false}} in
/// .harness/settings.json. A disabled skill is treated as not installed
/// everywhere — no system-prompt note, /skills shows it disabled, and
/// webfetch never shells out to it — even when its binaries are on PATH.
pub var g_skill_disabled = [_]bool{false} ** skills_registry.len;

/// Same opt-out, for the metered companion MCP servers (codedb-pro). They live
/// in companion_servers, NOT skills_registry, so they need their own flags —
/// this is the bug fix: {"skills": {"codedbpro": false}} now actually disables
/// the auto-connect (skillDisabled() never matched a companion server name).
pub var g_companion_disabled = [_]bool{false} ** companion_servers.len;

/// True when `codedb-pro probe` exits 0 (paid + usable). Set once at startup
/// after the companion connects; selects the licensed vs conservative note.
var g_codedbpro_licensed: bool = false;

// ── thinking animations ──────────────────────────────────────────────────
// Spinner animations + color themes (and their settings persistence) live in
// anim.zig (#123); it imports ansi and back-imports main for Approvals paths.
// The spinner consumers (Agent.spinnerTask, /animation, /theme) stay here.
const anim = @import("anim.zig");

// Steering (Codex-style): bytes typed while a turn streams are captured
// instead of discarded, echoed live in dim cyan, and on Enter queued to
// run as the next turn — so you can line up follow-ups one after the
// other without waiting for the current turn to finish. TTY-only (the
// raw-stdin esc-watch path is gated off in --json/GUI mode), so the queue
// stays empty there. Watchdog/select arms may drain and echo stdin while the
// stream reader is blocked; g_steer_visible pauses spinner redraws so the live
// steering row is not cleared out from under the user.
pub var g_steer_buf: std.ArrayList(u8) = .empty; // in-progress line (page-alloc)
const SteerEntry = repl_glue.SteerEntry; // struct { text: []const u8, force: bool }; moved to repl_glue.zig
pub var g_steer_queue: std.ArrayList(SteerEntry) = .empty; // completed lines
pub var g_steer_echoed = false; // "↳ steer ›" prefix shown for the current line
pub var g_steer_visible: std.atomic.Value(bool) = .init(false); // visible live steering row; pauses spinner redraws
pub var g_out: ?*Io.Writer = null; // stdout writer for steer echo (set in main)
pub var g_gui_mu: Io.Mutex = .init; // serializes --json stdout across pool-thread subagent emits (guiEmit + printDelta)
pub var g_force_interrupt = false; // Force-prompt path caused the last interrupt (Ctrl-F/double-enter).
pub var g_thinking_fold_request: bool = false; // Ctrl-T in escPressed → fold/unfold the live Thinking block (#92)
pub var g_thinking_open: bool = false; // a live Thinking block is on screen (gates the mouse-click fold, #92)
pub var g_5xx_body_buf: [600]u8 = undefined; // snippet of the last 5xx/429 error body
pub var g_5xx_body_len: usize = 0; // 0 = no body captured
// fillCompletions/wrapAt/LineRender/parseDsrCol moved to input_util.zig
// (see the breadcrumb below the term.zig import block for the aliases
// this file still needs).

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

// The rest of the line editor's input helpers (ultracode wave palette, the
// `@` picker's binary/dir filters + file collection, drag-and-drop path
// cleanup, and the redraw/setLine/delRange/prevWord/nextWord/addMark buffer
// helpers hoisted out of readLine) live in input_util.zig; readLine() itself
// (+ HistoryNav, #101) lives in readline.zig — both split out of main.zig
// (600-line goal). isImagePath is re-exported (vision.zig back-imports it)
// and binaryFileExt is aliased back (a read_file guard below calls it).
const input_util = @import("input_util.zig");
pub const isImagePath = input_util.isImagePath;
const binaryFileExt = input_util.binaryFileExt;
const readline_mod = @import("readline.zig");
const readLine = readline_mod.readLine;

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

/// OTLP endpoint baked into release builds (-Dtelemetry-endpoint); "" in dev
/// builds → telemetry stays off unless an env var configures it. Used as the
/// lowest-precedence telemetry endpoint, below env overrides and opt-out.
const default_telemetry_endpoint: []const u8 = @import("build_options").telemetry_endpoint;

/// A parsed `MAJOR.MINOR.PATCH` (no pre-release/build suffix). Used to compare
/// the running version against a GitHub release tag without the exact-string
/// mismatch that `git describe` suffixes ("-3-gabc", "-dirty", "-dev") cause.
// `graff update` (latest-release check + SemVer compare + install.sh delegation)
// + the changelog_text/usage_text (--version/--help) blocks live in cli.zig
// (600-line goal, #123). All three aliased back.
const cli = @import("cli.zig");
const updateCommand = cli.updateCommand;
const changelog_text = cli.changelog_text;
const usage_text = cli.usage_text;

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

// Provider-switch core (translateHistory, applyProvider, resolveProvider*,
// setModelRequestLabel, switchProvider) lives in providers.zig; the
// interactive pickers, ultracode steering, and login/auth flow live in
// pickers.zig — both split out of main.zig (600-line goal, #123).
const providers = @import("providers.zig");
const applyProvider = providers.applyProvider;
const resolveProviderControlRequest = providers.resolveProviderControlRequest;
const setModelRequestLabel = providers.setModelRequestLabel;
const switchProvider = providers.switchProvider;

const pickers = @import("pickers.zig");
const modelPicker = pickers.modelPicker;
const PickItem = pickers.PickItem;
const listPicker = pickers.listPicker;
const applyUltracodeSteering = pickers.applyUltracodeSteering;
const pickUltracodeMode = pickers.pickUltracodeMode;
const command_menu = pickers.command_menu;
const reloadLoginKey = pickers.reloadLoginKey;
const offerProviderAuth = pickers.offerProviderAuth;

// The ~1,200-line body of handleCommand (one if-block per slash command) is
// split into 3 sibling tryHandle() modules by theme (600-line goal, #123):
// commands_session.zig (session/env: /clear /new /rename /goal /loop /bash
// /agents /animation /theme /hooks /skills /trajectory /plan), commands_model.zig
// (model/provider/thinking: /model /compact /rewind /fast /thinking /title
// /ultracode /effort /keepcontext /key /login /image /paste /strict), and
// commands_misc.zig (/todo /jobs /cost /mcp /models /yolo /trace /fleet
// /save /resume /sessions + the unknown-command/help terminal fallback).
const commands_session = @import("commands_session.zig");
const commands_model = @import("commands_model.zig");
const commands_misc = @import("commands_misc.zig");

fn handleCommand(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !void {
    if (try commands_session.tryHandle(root, keys, arena, line, out)) return;
    if (try commands_model.tryHandle(root, keys, arena, line, out)) return;
    if (try commands_misc.tryHandle(root, keys, arena, line, out)) return;
    try commands_misc.handleRest(line, out);
}

// Session persistence (save/load/list/rename/age + the .graff/sessions path
// helpers) lives in session.zig (600-line goal, #123). session_ext/
// saveSession/loadSession/listSavedSessions/sessionAge stay pub —
// commands_session.zig, commands_misc.zig, and readline.zig already
// back-import them as `main_mod.saveSession` etc.
const session = @import("session.zig");
pub const session_ext = session.session_ext;
const sessionPath = session.sessionPath;
const SessionMeta = session.SessionMeta;
const sessionMetaFromBytes = session.sessionMetaFromBytes;
const sessionMeta = session.sessionMeta;
pub const sessionAge = session.sessionAge;
const SessionEntry = session.SessionEntry;
pub const listSavedSessions = session.listSavedSessions;
const slugifyTitle = session.slugifyTitle;
const renameSession = session.renameSession;
const sessionTitle = session.sessionTitle;
pub const saveSession = session.saveSession;
pub const loadSession = session.loadSession;

// Provider login/credential flows (Codex PKCE, Kimi + Codegraff device-code)
// live in oauth.zig (#123); it imports ansi + util and back-imports main for
// unixMs/kimi_user_agent/the codegraff base.
const oauth = @import("oauth.zig");
const CodexAuth = oauth.CodexAuth;

// API-key storage + the `graff key` CLI + OpenAI-compatible model listing
// live in keys_cli.zig (600-line goal, #123). isLocalUrl/openAiModelsUrl/
// fetchOpenAIModels/storeKey stay pub (commands_model.zig + pickers.zig
// back-import them as `main_mod.X`); homeEnv/loadStoredKey/keyCommand are
// used only from within main() here, so their aliases stay bare.
const keys_cli = @import("keys_cli.zig");
pub const isLocalUrl = keys_cli.isLocalUrl;
pub const openAiModelsUrl = keys_cli.openAiModelsUrl;
pub const fetchOpenAIModels = keys_cli.fetchOpenAIModels;
const homeEnv = keys_cli.homeEnv;
pub const storeKey = keys_cli.storeKey;
const loadStoredKey = keys_cli.loadStoredKey;
const keyCommand = keys_cli.keyCommand;

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

/// A normalized tool invocation — same shape for both providers.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    input: Value,
};

/// A tool's outcome, arena-owned, ready to wire into either format.
pub const ExecResult = struct {
    text: []const u8,
    is_error: bool,
    ms: i64 = 0, // wall-clock of the tool exec (external tools only; --timing)
};

pub const AnswerRequest = struct {
    text: []const u8,
    cancelled: bool,
    call_id: []const u8,
};

pub fn answerParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.AnswerNotObject => "answer must be a JSON object",
        error.AnswerWrongType => "expected answer request for ask_user",
        error.AnswerCallIdMismatch => "answer call_id did not match active ask_user prompt",
        else => "invalid answer JSON for ask_user",
    };
}

pub fn parseAnswerRequest(parsed: Value, expected_call_id: []const u8) !AnswerRequest {
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

pub const TodoItem = struct {
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

    pub fn prompt(self: *Agent) !void {
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

    pub fn say(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
        if (self.out) |w| {
            try w.print(fmt, args);
            try w.flush();
        } else {
            std.debug.print("  [{s}] " ++ fmt, .{self.label} ++ args);
        }
    }

    /// Report an API error: remember the formatted message so the --json
    /// `error` event can carry the detail, then print it like say().
    pub fn sayApiError(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
        self.last_api_error = std.fmt.allocPrint(self.arena, fmt, args) catch null;
        try self.say(fmt ++ "\n", args);
    }

    /// Emit one structured JSONL event to stdout (--json mode). `ev` is any
    /// struct/anonymous struct; field names become JSON keys (a std.json.Value
    /// field, e.g. tool input, serializes correctly). Best-effort.
    pub fn emit(self: *Agent, ev: anytype) void {
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
    pub fn systemPrompt(self: *const Agent) []const u8 {
        if (self.sub) return self.sys_override orelse sub_system_prompt;
        return if (self.strict) self.sys_strict else self.sys_normal;
    }

    /// Whether the active provider honors a reasoning-effort hint: the
    /// Responses API (codex) via reasoning.effort, and the OpenAI-compatible
    /// providers we know normalize a top-level reasoning_effort — the
    /// codegraff gateway and deepseek. Everything else ignores it.
    pub fn effortApplies(self: *const Agent) bool {
        return providerTakesEffort(self.provider.kind, self.provider.id, self.provider.model);
    }

    pub fn toolsJson(self: *const Agent) []const u8 {
        return switch (self.provider.kind) {
            .anthropic => if (self.sub) tools_anthropic_sub else self.tools_anthropic,
            .openai => if (self.sub) tools_openai_sub else self.tools_openai,
            .responses => if (self.sub) tools_responses_sub else self.tools_responses,
        };
    }

    /// Run until the model stops (or, in strict mode, calls
    /// attempt_completion). Returns the final assistant text (arena-owned).
    pub fn runTurn(self: *Agent) anyerror![]const u8 {
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

    // The provider round trip (request/buildBody + usage/cost recording +
    // Codex/Responses SSE reassembly) lives in agent_request.zig (#123,
    // 600-line goal). Member-aliased so self.request(...)/etc. resolve
    // unchanged.
    pub const request = @import("agent_request.zig").request;
    pub const recordUsage = @import("agent_request.zig").recordUsage;
    pub const usageInt = @import("agent_request.zig").usageInt;
    pub const recordCost = @import("agent_request.zig").recordCost;
    pub const ResponsesResult = @import("agent_request.zig").ResponsesResult;
    pub const parseResponses = @import("agent_request.zig").parseResponses;
    pub const errorMessage = @import("agent_request.zig").errorMessage;
    pub const recordUsageResponses = @import("agent_request.zig").recordUsageResponses;
    pub const buildBody = @import("agent_request.zig").buildBody;
    // Non-streaming response parsing (step*) + SSE-stream reassembly
    // (assemble*) live in agent_steps.zig (#123, 600-line goal).
    // Member-aliased so self.stepAnthropic(...)/etc. resolve unchanged.
    pub const stepResponses = @import("agent_steps.zig").stepResponses;
    pub const stepAnthropic = @import("agent_steps.zig").stepAnthropic;
    pub const stepOpenAI = @import("agent_steps.zig").stepOpenAI;
    pub const assembleStream = @import("agent_steps.zig").assembleStream;
    pub const assembleAnthropic = @import("agent_steps.zig").assembleAnthropic;
    pub const assembleOpenAI = @import("agent_steps.zig").assembleOpenAI;

    // Tool-call dispatch (runTools, the human-approval gate, meta-tool
    // handling, tool-call/result UX lines) lives in agent_tools.zig (#123,
    // 600-line goal). Member-aliased so self.runTools(...)/etc. resolve
    // unchanged.
    pub const runTools = @import("agent_tools.zig").runTools;
    pub const rejectToolCall = @import("agent_tools.zig").rejectToolCall;
    pub const toolDedupeKey = @import("agent_tools.zig").toolDedupeKey;
    pub const emitToolRejected = @import("agent_tools.zig").emitToolRejected;
    pub const gateTool = @import("agent_tools.zig").gateTool;
    pub const firstWord = @import("agent_tools.zig").firstWord;
    pub const handleMeta = @import("agent_tools.zig").handleMeta;
    pub const askUser = @import("agent_tools.zig").askUser;
    pub const emitAskUser = @import("agent_tools.zig").emitAskUser;
    pub const sayToolUse = @import("agent_tools.zig").sayToolUse;
    pub const sayToolResult = @import("agent_tools.zig").sayToolResult;
    pub fn renderTodos(self: *Agent) []const u8 {
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

    // Context management (compaction/emergency-trim) and the --eval/--until
    // eval-driven loop (+ optional LLM-as-judge) live in agent_compact.zig
    // (#123, 600-line goal). Member-aliased so self.compact(...)/etc.
    // resolve unchanged.
    pub const runEval = @import("agent_compact.zig").runEval;
    pub const appendEvalLog = @import("agent_compact.zig").appendEvalLog;
    pub const runJudge = @import("agent_compact.zig").runJudge;
    pub const compact = @import("agent_compact.zig").compact;
    pub const cleanUserTurn = @import("agent_compact.zig").cleanUserTurn;
    pub const emergencyCutIndex = @import("agent_compact.zig").emergencyCutIndex;
    pub const emergencyTrim = @import("agent_compact.zig").emergencyTrim;
    pub const compactOrRecover = @import("agent_compact.zig").compactOrRecover;

    // The live streaming path (thinking spinner, live "Thinking" reasoning
    // block, and postStream itself — the root agent's streaming POST) lives
    // in agent_stream.zig (#123, 600-line goal). Member-aliased so
    // self.postStream(...)/etc. resolve unchanged. g_spin_stop/g_spin_future
    // below stay here (never alias a `var`).
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
    pub var g_spin_stop: std.atomic.Value(bool) = .init(true);
    pub var g_spin_future: ?Io.Future(void) = null;
    pub const spinnerTask = @import("agent_stream.zig").spinnerTask;
    pub const spinnerStart = @import("agent_stream.zig").spinnerStart;
    pub const spinnerStop = @import("agent_stream.zig").spinnerStop;
    pub const streamThinking = @import("agent_stream.zig").streamThinking;
    pub const closeThinkingBlock = @import("agent_stream.zig").closeThinkingBlock;
    pub const toggleThinkingFold = @import("agent_stream.zig").toggleThinkingFold;
    pub const postStream = @import("agent_stream.zig").postStream;
    pub const printDelta = @import("agent_stream.zig").printDelta;
    /// Esc-during-tools cancellation. postStream only watches stdin while an
    /// HTTP stream is live, so a long tool join (bash, a subagent fan-out, a
    /// whole workflow) used to be Esc-deaf — exactly when turns feel longest.
    /// While the root awaits tool futures, escWatchTask polls stdin from the
    /// pool; Esc sets esc_cancel, which subagents poll between SSE lines and
    /// turn iterations, and the root consumes at its next loop head as
    /// error.Interrupted.
    pub var esc_cancel: std.atomic.Value(bool) = .init(false);
    pub var esc_watch_done: std.atomic.Value(bool) = .init(true);

    // Esc-cancel handling (the stdin scanner + steering-buffer capture +
    // interruptible sleep) lives in agent_interrupt.zig (#123, 600-line
    // goal). Member-aliased so self.sleepInterruptible(...)/etc. resolve
    // unchanged. esc_cancel/esc_watch_done above stay here (never alias a
    // `var`); ssePayload/sseIndex live there too since they're only
    // consumed alongside the interrupt-watch plumbing in postStream.
    pub const escWatchTask = @import("agent_interrupt.zig").escWatchTask;
    pub const escPressed = @import("agent_interrupt.zig").escPressed;
    pub const drainSteerStdin = @import("agent_interrupt.zig").drainSteerStdin;
    pub const drainStdin = @import("agent_interrupt.zig").drainStdin;
    pub const rawNonblockStdin = @import("agent_interrupt.zig").rawNonblockStdin;
    pub const sleepInterruptible = @import("agent_interrupt.zig").sleepInterruptible;
    pub const ssePayload = @import("agent_interrupt.zig").ssePayload;
    pub const sseIndex = @import("agent_interrupt.zig").sseIndex;

    // Live streaming of attempt_completion/ask_user tool-argument prose (the
    // ArgLive byte-scanner) lives in agent_argstream.zig (#123, 600-line
    // goal). Member-aliased so self.arg_live's type + the streaming callbacks
    // resolve unchanged regardless of physical file.
    pub const ArgTool = @import("agent_argstream.zig").ArgTool;
    pub const ArgLive = @import("agent_argstream.zig").ArgLive;
    pub const argToolFor = @import("agent_argstream.zig").argToolFor;
    pub const argField = @import("agent_argstream.zig").argField;
    pub const outputIndex = @import("agent_argstream.zig").outputIndex;
    pub const argLiveDelta = @import("agent_argstream.zig").argLiveDelta;
    pub const emitArgText = @import("agent_argstream.zig").emitArgText;
    pub const argStreamedFully = @import("agent_argstream.zig").argStreamedFully;

    // The incremental streaming markdown renderer (byte-at-a-time line
    // classifier + non-streaming renderMdLine) lives in agent_render.zig
    // (#123, 600-line goal). Member-aliased so `self.streamMarkdown(...)`
    // and the field types below resolve unchanged regardless of physical
    // file.
    pub const MdKind = @import("agent_render.zig").MdKind;
    pub const MdSpan = @import("agent_render.zig").MdSpan;
    pub const streamMarkdown = @import("agent_render.zig").streamMarkdown;
    pub const inlineVisibleLen = @import("agent_render.zig").inlineVisibleLen;
    pub const codepointCount = @import("agent_render.zig").codepointCount;
    pub const flushStreamTail = @import("agent_render.zig").flushStreamTail;
    pub const renderMdLine = @import("agent_render.zig").renderMdLine;
    pub const renderInline = @import("agent_render.zig").renderInline;
    pub const mdByte = @import("agent_render.zig").mdByte;
    pub const mdTryClassify = @import("agent_render.zig").mdTryClassify;
    pub const mdStartProse = @import("agent_render.zig").mdStartProse;
    pub const mdSpanByte = @import("agent_render.zig").mdSpanByte;
    pub const mdWrapByte = @import("agent_render.zig").mdWrapByte;
    pub const mdStyle = @import("agent_render.zig").mdStyle;
    pub const mdFlushWord = @import("agent_render.zig").mdFlushWord;
    pub const mdWrapBreak = @import("agent_render.zig").mdWrapBreak;
    pub const mdWidth = @import("agent_render.zig").mdWidth;
    pub const mdSpanEnd = @import("agent_render.zig").mdSpanEnd;
    pub const mdFinishLine = @import("agent_render.zig").mdFinishLine;
    // Streamed-markdown table rendering (buffered rows -> aligned columns,
    // word-wrapped to termCols()) lives in agent_table.zig (#123, 600-line
    // goal). Member-aliased so `self.flushTable(...)`/`Agent.isTableSeparator(...)`
    // resolve unchanged regardless of physical file.
    pub const flushTable = @import("agent_table.zig").flushTable;
    pub const fitWidths = @import("agent_table.zig").fitWidths;
    pub const atomEnd = @import("agent_table.zig").atomEnd;
    pub const wrapCell = @import("agent_table.zig").wrapCell;
    pub const isTableSeparator = @import("agent_table.zig").isTableSeparator;
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
// Tool execution: the tool-call context (ToolCtx), file-edit snapshots for
// /rewind, pre/post-tool lifecycle-hook dispatch, the codedb-guard (#626)
// and metered-companion router, and small per-tool helpers live in tools.zig
// (600-line goal; imported as tools_mod — Agent.request/buildBody already
// have a `tools` parameter, which a bare `tools` import would shadow).
// Subagent/workflow-task spawning (execSubagent/runSub/workflowTask/
// judgeTask + the ultracode/DGM variant judge) lives in subagent.zig —
// judgeTask is aliased back (Agent.runJudge, above, spawns it directly via
// io.async). Dynamic workflows-as-data (phases + pipeline mode) live in
// workflow.zig. The tool dispatcher itself (execTool/execToolInner) lives in
// exec.zig, importing the three as siblings; execTool is aliased back
// (Agent.runTools' io.async spawn + the /bash slash-command handler above).
const tools_mod = @import("tools.zig");
pub const ToolOutput = tools_mod.ToolOutput;
pub const ToolCtx = tools_mod.ToolCtx;
pub const Snapshots = tools_mod.Snapshots;
pub const bash_stdout_cap = tools_mod.bash_stdout_cap; // input_util.zig back-imports this for its file-collection caps
const apiErrorMessage = tools_mod.apiErrorMessage;
const mentionsReasoningEffort = tools_mod.mentionsReasoningEffort;

const subagent = @import("subagent.zig");
const judgeTask = subagent.judgeTask;

const workflow = @import("workflow.zig");

const exec = @import("exec.zig");
const execTool = exec.execTool;
// ── Unit tests (`zig build test`) ──────────────────────────────────────────

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

test "resolveModelName exact aliases and miss" {
    const keys = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expect(resolveModelName(keys, "gpt-5.5") != null); // exact name
    try std.testing.expectEqualStrings("glm-5.2", resolveModelName(keys, "glm5.2").?); // natural alias
    try std.testing.expect(resolveModelName(keys, "totally-unknown-zzz") == null);
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

test "Keys.defaultProvider: first keyed provider on its default model" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const p = try all.defaultProvider();
    try std.testing.expectEqualStrings("anthropic", p.id); // anthropic leads provider_specs
    try std.testing.expectEqualStrings("claude-opus-4-8", p.model);
    const none = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expectError(error.MissingKey, none.defaultProvider());
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
