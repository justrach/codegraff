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

const builtin = @import("builtin");

const anthropic_version = "2023-06-01";
const max_tokens = 16000;
const mcp_config_path = ".mcp.json";

/// ANSI styling for the REPL. All fields are empty strings by default (no
/// color), and swapped for escape codes at startup only when stdout is a TTY
/// and NO_COLOR is unset — so piped/redirected output stays clean.
const Style = struct {
    reset: []const u8 = "",
    dim: []const u8 = "",
    bold: []const u8 = "",
    red: []const u8 = "",
    green: []const u8 = "",
    yellow: []const u8 = "",
    cyan: []const u8 = "",

    const ansi: Style = .{
        .reset = "\x1b[0m",
        .dim = "\x1b[2m",
        .bold = "\x1b[1m",
        .red = "\x1b[31m",
        .green = "\x1b[32m",
        .yellow = "\x1b[33m",
        .cyan = "\x1b[36m",
    };
};
var style: Style = .{};
var use_color = false; // stdout is a TTY and NO_COLOR unset → enables color + markdown

// Optional displays toggled by CLI flags (--timing, --cost).
var show_timing = false;
var show_cost = false;
var json_mode = false; // --json: structured JSONL events on stdout instead of human text
var plan_mode = false; // /plan: read-only — mutating tools are denied, the model proposes
var unattended = false; // -p one-shot: no human to prompt; unapproved tool calls are denied

/// Documentation of the `--json` stdio protocol, embedded verbatim in
/// `--schema` output so SDK generators/users know the request/event contract.
const schema_protocol_json =
    \\{
    \\  "transport": "newline-delimited JSON over stdin/stdout (--json)",
    \\  "request": "one JSON object per line: {\"type\":\"user\",\"text\":\"...\"} sends a user turn; {\"type\":\"set_system_prompt\",\"text\":\"...\",\"append\":false} replaces (or with append=true extends) the system prompt between turns and acks with a system_prompt event. NOTE: the system prompt heads the KV-cached prefix, so any mutation invalidates the cache for the whole conversation (per Manus context-engineering lessons) — set it at spawn when possible and mutate only at task boundaries",
    \\  "score_request": "{\"type\":\"score\",\"prompt_sha\":\"<16 hex>\",\"score\":0.7,\"notes\":\"...\",\"parent_sha\":\"<16 hex, optional>\"} appends an evaluation record for an agent/prompt variant to harness.trajectory.jsonl (the append-only DGM-style archive; prompt_sha = first 8 bytes of SHA-256 of the system prompt, hex; parent_sha records which prompt this variant was mutated from — the lineage edge DGM parent selection counts children with) and acks with a score event",
    \\  "events": [
    \\    {"type": "text", "text": "assistant text delta"},
    \\    {"type": "tool_call", "name": "tool", "input": {}},
    \\    {"type": "tool_result", "name": "tool", "is_error": false, "text": "..."},
    \\    {"type": "turn", "text": "final assistant text", "context_tokens": 0, "cost_usd": 0.0},
    \\    {"type": "system_prompt", "ok": true, "append": false, "chars": 0},
    \\    {"type": "score", "ok": true, "prompt_sha": "..."},
    \\    {"type": "error", "message": "..."}
    \\  ]
    \\}
;

/// Documentation of the `harness serve` HTTP bridge, embedded verbatim in
/// `--schema` output. Same request/event contract as the stdio protocol —
/// one POST = one protocol request, streamed back as NDJSON until that
/// request's terminal event (turn/error for user turns; the ack for others).
const schema_serve_json =
    \\{
    \\  "transport": "HTTP/1.1 (graff serve, default 127.0.0.1:8787); auth via Authorization: Bearer <token> when --token/HARNESS_SERVE_TOKEN is set (required on non-loopback binds)",
    \\  "endpoints": [
    \\    {"method": "GET", "path": "/healthz", "description": "liveness + version, no auth"},
    \\    {"method": "GET", "path": "/v1/schema", "description": "this schema document"},
    \\    {"method": "POST", "path": "/v1/sessions", "description": "create a session (a graff --json child); optional JSON body {\"model\",\"yolo\",\"system_prompt\",\"append_system_prompt\"} overrides serve-level defaults; responds {\"session_id\":\"<16 hex>\"}"},
    \\    {"method": "POST", "path": "/v1/sessions/{id}", "description": "body is ONE stdio-protocol request object (user / set_system_prompt / score); response streams application/x-ndjson events until the request's terminal event (turn/error, or the system_prompt/score ack); one request in flight per session at a time"},
    \\    {"method": "DELETE", "path": "/v1/sessions/{id}", "description": "graceful close: waits for any in-flight request, then EOFs the child's stdin"}
    \\  ]
    \\}
;

/// Launch flags relevant to SDK clients, embedded verbatim in `--schema`
/// output so generated clients can surface them as first-class options.
const schema_flags_json =
    \\[
    \\  {"flag": "--model", "arg": "name", "description": "start on this model (same fuzzy resolution as /model)"},
    \\  {"flag": "--yolo", "arg": null, "description": "skip all permission prompts for the session"},
    \\  {"flag": "--system-prompt", "arg": "text", "description": "replace the built-in system prompt (cwd project-instructions file is still appended)"},
    \\  {"flag": "--append-system-prompt", "arg": "text", "description": "append extra text to the end of the system prompt"},
    \\  {"flag": "--json", "arg": null, "description": "structured stdio protocol (JSON in, JSONL events out)"},
    \\  {"flag": "--no-telemetry", "arg": null, "description": "disable anonymous OTEL usage telemetry for this run"}
    \\]
;

/// Per-model token pricing in USD per 1M tokens (from models.dev, snapshot
/// 2026-06-10). Keyed by model name, provider-agnostic. Login providers
/// (codex, claude) bill via subscription, not per token — recordCost treats
/// them as $0 ("sub") regardless of this table. Models absent here have no
/// known price and contribute 0 to the running cost (shown as ~).
const ModelPrice = struct { name: []const u8, in: f64, out: f64, cache: f64 };
const price_table = [_]ModelPrice{
    .{ .name = "deepseek-v4-pro", .in = 1.1, .out = 2.2, .cache = 0.11 },
    .{ .name = "deepseek-v4-flash", .in = 0.14, .out = 0.28, .cache = 0.028 },
    .{ .name = "gpt-5.5", .in = 5, .out = 30, .cache = 0.5 },
    .{ .name = "gpt-5.5-codex", .in = 1.25, .out = 10, .cache = 0.125 },
    .{ .name = "gpt-5-codex", .in = 1.25, .out = 10, .cache = 0.125 },
    .{ .name = "claude-opus-4-8", .in = 15, .out = 75, .cache = 1.5 },
    .{ .name = "claude-opus-4.8", .in = 15, .out = 75, .cache = 1.5 },
    .{ .name = "claude-sonnet-4-6", .in = 3, .out = 15, .cache = 0.3 },
    .{ .name = "claude-sonnet-4.6", .in = 3, .out = 15, .cache = 0.3 },
    .{ .name = "claude-haiku-4-5", .in = 1, .out = 5, .cache = 0.1 },
    .{ .name = "MiniMax-M3", .in = 0.3, .out = 1.2, .cache = 0.06 },
    .{ .name = "minimax-m3", .in = 0.3, .out = 1.2, .cache = 0.06 },
    .{ .name = "mimo-v2.5-pro", .in = 0.435, .out = 0.87, .cache = 0.0036 },
    .{ .name = "mimo-v2.5", .in = 0.14, .out = 0.28, .cache = 0.0028 },
    .{ .name = "kimi-k2.6", .in = 0.95, .out = 4, .cache = 0.1 },
    .{ .name = "kimi-k2-thinking", .in = 0.6, .out = 2.5, .cache = 0.06 },
    .{ .name = "kimi-k2.5", .in = 0.6, .out = 3, .cache = 0.06 },
    .{ .name = "grok-4.3", .in = 1.25, .out = 2.5, .cache = 0.3 },
    .{ .name = "grok-build", .in = 1, .out = 2, .cache = 0.1 },
    .{ .name = "glm-5", .in = 1, .out = 3.2, .cache = 0.1 },
    .{ .name = "glm-4.7", .in = 0.6, .out = 2.2, .cache = 0.06 },
    .{ .name = "glm-4.5", .in = 0.6, .out = 2.2, .cache = 0.06 },
};

fn priceFor(model: []const u8) ?ModelPrice {
    for (price_table) |p| if (std.mem.eql(u8, p.name, model)) return p;
    return null;
}

/// Billing class of one API call: the codex subscription login bills
/// flat-rate, price_table rows bill per token, anything else is unpriced.
const Billing = enum { sub, priced, unpriced };

fn billingFor(provider_id: []const u8, model: []const u8) Billing {
    if (std.mem.eql(u8, provider_id, "codex")) return .sub;
    return if (priceFor(model) != null) .priced else .unpriced;
}

/// USD for one request at price `p` (negative token counts clamp to 0).
fn usdFor(p: ModelPrice, uncached_in: i64, cache_in: i64, out: i64) f64 {
    const fi: f64 = @floatFromInt(@max(uncached_in, 0));
    const fc: f64 = @floatFromInt(@max(cache_in, 0));
    const fo: f64 = @floatFromInt(@max(out, 0));
    return (fi * p.in + fc * p.cache + fo * p.out) / 1_000_000.0;
}

/// Session-wide usage/cost tally. Every API response lands here — the root
/// agent AND subagents/workflow tasks (which run on pool threads, hence the
/// mutex; their per-agent numbers used to vanish with their arenas). Always
/// on: /cost reads it, one-shot mode prints it to stderr, the --cost prompt
/// suffix and --json turn events render the running USD, and the telemetry
/// session summary ships it.
const CostTally = struct {
    mutex: Io.Mutex = .init,
    usd: f64 = 0,
    in_tokens: u64 = 0, // uncached input
    cache_tokens: u64 = 0, // cache-read input
    out_tokens: u64 = 0,
    api_calls: u64 = 0,
    sub_calls: u64 = 0, // subscription-billed (flat-rate; contribute $0)
    unpriced_calls: u64 = 0, // no price_table row

    fn add(self: *CostTally, io: Io, provider_id: []const u8, model: []const u8, uncached_in: i64, cache_in: i64, out: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.api_calls += 1;
        self.in_tokens += @intCast(@max(uncached_in, 0));
        self.cache_tokens += @intCast(@max(cache_in, 0));
        self.out_tokens += @intCast(@max(out, 0));
        switch (billingFor(provider_id, model)) {
            .sub => self.sub_calls += 1,
            .unpriced => self.unpriced_calls += 1,
            .priced => self.usd += usdFor(priceFor(model).?, uncached_in, cache_in, out),
        }
    }

    /// Consistent copy for rendering (taken under the lock).
    fn snap(self: *CostTally, io: Io) CostTally {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var c = self.*;
        c.mutex = .init;
        return c;
    }

    /// One-line summary shared by /cost and the one-shot stderr report.
    fn render(c: CostTally, w: *Io.Writer) !void {
        try w.print("{d} api call(s) · {d} in ({d} cached) + {d} out tokens · ${d:.4}", .{
            c.api_calls, c.in_tokens + c.cache_tokens, c.cache_tokens, c.out_tokens, c.usd,
        });
        if (c.sub_calls > 0) try w.print(" · {d} subscription call(s), flat-rate (not in $)", .{c.sub_calls});
        if (c.unpriced_calls > 0) try w.print(" · {d} call(s) on unpriced models", .{c.unpriced_calls});
    }
};

var g_cost: CostTally = .{};

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

const provider_specs = [_]ProviderSpec{
    .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "https://api.anthropic.com/v1/messages", .env_key = "ANTHROPIC_API_KEY", .default_model = "claude-opus-4-8" },
    .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "https://gateway.codegraff.com/v1/chat/completions", .env_key = "CODEGRAFF_API_KEY", .default_model = "deepseek-v4-pro" },
    .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "https://api.deepseek.com/chat/completions", .env_key = "DEEPSEEK_API_KEY", .default_model = "deepseek-v4-pro" },
    .{ .id = "openai", .kind = .openai, .auth = .bearer, .url = "https://api.openai.com/v1/chat/completions", .env_key = "OPENAI_API_KEY", .default_model = "gpt-5.5" },
    .{ .id = "minimax", .kind = .anthropic, .auth = .bearer, .url = "https://api.minimax.io/anthropic/v1/messages", .env_key = "MINIMAX_API_KEY", .default_model = "MiniMax-M3" },
    .{ .id = "xiaomi", .kind = .openai, .auth = .bearer, .url = "https://api.xiaomimimo.com/v1/chat/completions", .env_key = "XIAOMI_API_KEY", .default_model = "mimo-v2.5-pro" },
    // OpenAI-format direct providers (matched to graff's provider.json).
    .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "https://api.kimi.com/coding/v1/chat/completions", .env_key = "KIMI_API_KEY", .default_model = "kimi-k2.6" },
    .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "https://api.x.ai/v1/chat/completions", .env_key = "XAI_API_KEY", .default_model = "grok-4.3" },
    .{ .id = "zai", .kind = .openai, .auth = .bearer, .url = "https://api.z.ai/api/paas/v4/chat/completions", .env_key = "ZAI_API_KEY", .default_model = "glm-5" },
    // codex: ChatGPT login via the Responses API. Its "key" isn't an env var
    // — it's the OAuth access token read from ~/.codex/auth.json at startup
    // (see loadCodexAuth), the same on-disk-credential trick used for the
    // codegraff gateway key in ~/forge/.credentials.json.
    .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://chatgpt.com/backend-api/codex/responses", .env_key = "CODEX_DISABLED", .default_model = "gpt-5.5" },
};

// Known models per provider: context window in tokens. Direct-provider
// numbers from models.dev/api.json, codegraff numbers from the gateway's
// /v1/models endpoint (both snapshot 2026-06-10). The same model name can
// appear under several providers with different limits — routing picks the
// first row whose provider has an API key. Compaction triggers at 80% of
// the context; unknown models fall back to a conservative 200k.
const ModelInfo = struct {
    provider: []const u8,
    name: []const u8,
    context: u64,
};

const model_table = [_]ModelInfo{
    .{ .provider = "anthropic", .name = "claude-fable-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-8", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-7", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-6", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-4-6", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-haiku-4-5", .context = 200_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-5", .context = 200_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-4-5", .context = 200_000 },
    .{ .provider = "deepseek", .name = "deepseek-v4-pro", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-v4-flash", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-chat", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-reasoner", .context = 1_000_000 },
    .{ .provider = "openai", .name = "gpt-5.5", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.4", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.4-pro", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.2", .context = 400_000 },
    .{ .provider = "openai", .name = "gpt-5-codex", .context = 400_000 },
    .{ .provider = "minimax", .name = "MiniMax-M3", .context = 512_000 },
    .{ .provider = "minimax", .name = "MiniMax-M2.7", .context = 204_800 },
    .{ .provider = "minimax", .name = "MiniMax-M2.5", .context = 204_800 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5-pro", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5-pro-ultraspeed", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2-flash", .context = 262_144 },
    .{ .provider = "codex", .name = "gpt-5.5", .context = 400_000 },
    .{ .provider = "codex", .name = "gpt-5.5-codex", .context = 400_000 },
    .{ .provider = "codex", .name = "gpt-5-codex", .context = 400_000 },
    // codegraff gateway (its claude aliases use dots, so they don't collide
    // with the anthropic rows above)
    .{ .provider = "codegraff", .name = "claude-opus-4.8", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "claude-sonnet-4.6", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "deepseek-v4-pro", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "minimax-m3", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "gpt-5.5", .context = 400_000 },
    .{ .provider = "codegraff", .name = "kimi-k2.6", .context = 262_144 },
    .{ .provider = "codegraff", .name = "grok-build", .context = 256_000 },
    .{ .provider = "codegraff", .name = "mimo-v2.5", .context = 128_000 },
    .{ .provider = "codegraff", .name = "mimo-v2.5-pro", .context = 128_000 },
    // kimi / xai / zai direct providers (contexts from models.dev 2026-06-10)
    .{ .provider = "kimi", .name = "kimi-k2.6", .context = 262_144 },
    .{ .provider = "kimi", .name = "kimi-k2-thinking", .context = 262_144 },
    .{ .provider = "kimi", .name = "kimi-k2.5", .context = 262_144 },
    .{ .provider = "xai", .name = "grok-4.3", .context = 1_000_000 },
    .{ .provider = "xai", .name = "grok-build", .context = 256_000 },
    .{ .provider = "zai", .name = "glm-5", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.7", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.5", .context = 131_072 },
};

const default_context = 200_000;

/// Context window for a model as served by a specific provider; falls back
/// to any provider's row for the name, then to the conservative default.
fn contextFor(provider_id: []const u8, model: []const u8) u64 {
    for (model_table) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model)) return m.context;
    }
    for (model_table) |m| {
        if (std.mem.eql(u8, m.name, model)) return m.context;
    }
    return default_context;
}

/// Fuzzy model selection for `/model <query>` (graff-style). Exact name wins;
/// otherwise case-insensitive substring, preferring a model whose provider has
/// a key/login available so `/model sonnet` lands on a usable provider. Returns
/// null when nothing matches (caller falls back to the query verbatim so the
/// providerFor claude*/gateway fallback still applies).
fn resolveModelName(keys: Keys, query: []const u8) ?[]const u8 {
    for (model_table) |m| if (std.mem.eql(u8, m.name, query)) return m.name;
    var fallback: ?[]const u8 = null;
    for (model_table) |m| {
        if (std.ascii.indexOfIgnoreCase(m.name, query) == null) continue;
        if (keys.get(m.provider) != null) return m.name;
        if (fallback == null) fallback = m.name;
    }
    return fallback;
}

/// Exact membership test against the comptime model table — used to ignore a
/// remembered startup model that no provider actually serves.
fn modelInTable(name: []const u8) bool {
    for (model_table) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}
const main_system_prompt =
    \\You are a coding agent running in a minimal terminal harness on the
    \\user's machine. Use the provided tools to inspect and modify the current
    \\working directory and to run commands. read_file before editing; prefer
    \\edit_file for changes to existing files and write_file only for new
    \\files or full rewrites. Some bash commands need user approval — if one
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

// ---------------------------------------------------------------------------
// Tool definitions. Built-in + meta tools are static specs; MCP tools are
// discovered at runtime and merged into the root agent's tool list.

const ToolSpec = struct {
    name: []const u8,
    desc: []const u8, // no characters needing JSON escapes
    schema: []const u8, // raw JSON Schema string
};

const empty_schema =
    \\{"type": "object", "properties": {}}
;

const base_specs = [_]ToolSpec{
    .{
        .name = "bash",
        .desc = "Run a shell command via /bin/sh -c in the current working directory. Returns stdout, stderr, and the exit code. For long-running commands (dev servers, watchers) set run_in_background true: it returns a job id immediately; poll output with bash_output and stop it with bash_kill.",
        .schema =
        \\{"type": "object", "properties": {"command": {"type": "string", "description": "Shell command to execute"}, "run_in_background": {"type": "boolean", "description": "Start as a background job and return its id immediately instead of waiting (default false)"}}, "required": ["command"]}
        ,
    },
    .{
        .name = "bash_output",
        .desc = "Read new output from a background bash job (everything since the last bash_output call) plus its status: running, exited with code, or killed. Set wait_ms to block until new output or exit.",
        .schema =
        \\{"type": "object", "properties": {"id": {"type": "integer", "description": "Job id returned by bash with run_in_background"}, "wait_ms": {"type": "integer", "description": "Max milliseconds to wait for new output or exit (0-30000, default 0)"}}, "required": ["id"]}
        ,
    },
    .{
        .name = "bash_kill",
        .desc = "Terminate a background bash job. Unread output stays readable via bash_output afterwards.",
        .schema =
        \\{"type": "object", "properties": {"id": {"type": "integer", "description": "Job id to terminate"}}, "required": ["id"]}
        ,
    },
    .{
        .name = "read_file",
        .desc = "Read a UTF-8 text file. Call this before editing any file.",
        .schema =
        \\{"type": "object", "properties": {"path": {"type": "string", "description": "File path, relative to the working directory"}}, "required": ["path"]}
        ,
    },
    .{
        .name = "edit_file",
        .desc = "Replace an exact string in a file. old_string must match exactly one spot unless replace_all is set. Prefer this over write_file when changing an existing file.",
        .schema =
        \\{"type": "object", "properties": {"path": {"type": "string"}, "old_string": {"type": "string", "description": "Exact existing text to find"}, "new_string": {"type": "string", "description": "Replacement text"}, "replace_all": {"type": "boolean", "description": "Replace every occurrence (default: require a unique match)"}}, "required": ["path", "old_string", "new_string"]}
        ,
    },
    .{
        .name = "write_file",
        .desc = "Create or overwrite a file with the given contents.",
        .schema =
        \\{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}
        ,
    },
    .{
        .name = "webfetch",
        .desc = "Fetch an http(s) URL and return the page content. When the kuri fetcher is installed (and not disabled) the page arrives as markdown; otherwise — or whenever kuri fails or returns nothing — a plain HTTP GET returns the raw HTML/text. Output is size-capped.",
        .schema =
        \\{"type": "object", "properties": {"url": {"type": "string", "description": "Absolute http:// or https:// URL to fetch"}}, "required": ["url"]}
        ,
    },
    .{
        .name = "codedb",
        .desc = "Query codedb (github.com/justrach/codedb) — the code-intelligence index for this repo (fast & structural; prefer over grep/bash for navigating code). `command` is a codedb subcommand line: search <query> | symbol <name> [--body] | callers <name> | outline <path> | find <name> | deps <path> | tree | context <task...> | read <path>.",
        .schema =
        \\{"type": "object", "properties": {"command": {"type": "string", "description": "codedb subcommand + args, e.g. \"search parseHeader\", \"symbol buildBody --body\", \"callers switchProvider\""}}, "required": ["command"]}
        ,
    },
};

// Meta tools act on the agent's own state, not the outside world; the
// orchestrator handles them inline (never on a pool thread).
const meta_specs = [_]ToolSpec{
    .{
        .name = "todo_write",
        .desc = "Replace your task list. Use to plan and track multi-step work. Each item has content and status (pending|in_progress|completed).",
        .schema =
        \\{"type": "object", "properties": {"todos": {"type": "array", "items": {"type": "object", "properties": {"content": {"type": "string"}, "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}}, "required": ["content", "status"]}}}, "required": ["todos"]}
        ,
    },
    .{
        .name = "todo_read",
        .desc = "Read your current task list.",
        .schema = empty_schema,
    },
    .{
        .name = "ask_user",
        .desc = "Ask the human a question and wait for their typed reply, which is returned as this tool's result. Use when you need a decision, clarification, or missing information. This routes the human turn through the tool channel — the user is just another tool you can call.",
        .schema =
        \\{"type": "object", "properties": {"question": {"type": "string", "description": "The question to ask the user"}, "options": {"type": "array", "items": {"type": "string"}, "description": "Optional suggested answers, shown numbered"}}, "required": ["question"]}
        ,
    },
    .{
        .name = "attempt_completion",
        .desc = "Signal that the task is complete. Put your final answer to the user in the result field. In strict mode this is the only way to end a turn.",
        .schema =
        \\{"type": "object", "properties": {"result": {"type": "string", "description": "Final answer to present to the user"}}, "required": ["result"]}
        ,
    },
};

const subagent_spec = ToolSpec{
    .name = "subagent",
    .desc = "Delegate a self-contained task to a subagent. It has bash, read_file, edit_file, write_file, and codedb (code search); it cannot spawn further subagents and does NOT share your context — the prompt must be self-contained. Returns the subagent final report. Call several times in one response to run tasks in parallel. Pick a persona with agent (builtins: reviewer, researcher, implementer, skeptic — plus any in .harness/agents/), or give the child a custom system_prompt; the trajectory log records the lineage either way.",
    .schema =
    \\{"type": "object", "properties": {"description": {"type": "string", "description": "Short label for logs, 3-5 words"}, "prompt": {"type": "string", "description": "Complete, self-contained task description"}, "agent": {"type": "string", "description": "Optional: a named agent type (reviewer, researcher, implementer, skeptic, or a .harness/agents/ name) whose persona the child runs with"}, "system_prompt": {"type": "string", "description": "Optional: replace the child's system prompt with a custom one (overrides agent)"}}, "required": ["description", "prompt"]}
    ,
};

const workflow_spec = ToolSpec{
    .name = "workflow",
    .desc = "Run a multi-phase workflow of parallel subagents (dynamic workflows as data). Phases run sequentially; the tasks inside a phase run in parallel, each as an isolated subagent with no shared context, so every prompt must be self-contained. From phase 2 on, the placeholder {{prev}} in a task prompt is replaced with the labeled results of the previous phase (appended automatically if omitted). Returns the final phase results. Use for fan-out work with a synthesis step: audits, multi-perspective review, parallel research. Tasks may carry their own system_prompt to run prompt variants side by side.",
    .schema =
    \\{"type": "object", "properties": {"phases": {"type": "array", "items": {"type": "object", "properties": {"title": {"type": "string", "description": "Short phase label for logs"}, "tasks": {"type": "array", "items": {"type": "object", "properties": {"description": {"type": "string", "description": "Short label, 3-5 words"}, "prompt": {"type": "string", "description": "Complete, self-contained task; may contain {{prev}}"}, "agent": {"type": "string", "description": "Optional: a named agent type (reviewer, researcher, implementer, skeptic, or a .harness/agents/ name)"}, "system_prompt": {"type": "string", "description": "Optional: replace this task's system prompt (overrides agent)"}}, "required": ["description", "prompt"]}}}, "required": ["tasks"]}}}, "required": ["phases"]}
    ,
};

const root_specs = base_specs ++ meta_specs ++ [_]ToolSpec{ subagent_spec, workflow_spec };

fn isMetaName(name: []const u8) bool {
    return std.mem.eql(u8, name, "todo_write") or
        std.mem.eql(u8, name, "todo_read") or
        std.mem.eql(u8, name, "ask_user") or
        std.mem.eql(u8, name, "attempt_completion");
}

// Comptime-rendered tool lists for subagents (base only, both formats).
const tools_anthropic_sub = anthropicToolsJson(&base_specs);
const tools_openai_sub = openaiToolsJson(&base_specs);
const tools_responses_sub = responsesToolsJson(&base_specs);

fn anthropicToolsJson(comptime specs: []const ToolSpec) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"name\":\"" ++ t.name ++ "\",\"description\":\"" ++ t.desc ++
                "\",\"input_schema\":" ++ t.schema ++ "}";
        }
        return out ++ "]";
    }
}

fn openaiToolsJson(comptime specs: []const ToolSpec) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"type\":\"function\",\"function\":{\"name\":\"" ++ t.name ++
                "\",\"description\":\"" ++ t.desc ++ "\",\"parameters\":" ++ t.schema ++ "}}";
        }
        return out ++ "]";
    }
}

fn responsesToolsJson(comptime specs: []const ToolSpec) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"type\":\"function\",\"name\":\"" ++ t.name ++
                "\",\"description\":\"" ++ t.desc ++ "\",\"parameters\":" ++ t.schema ++
                ",\"strict\":false}";
        }
        return out ++ "]";
    }
}

/// Render built-in specs + discovered MCP tools into one provider-specific
/// tools array (allocated with `out`). Used for the root agent at startup.
fn renderRootTools(
    out: Allocator,
    kind: Provider.Kind,
    specs: []const ToolSpec,
    mcp_tools: []const mcp.Tool,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(out);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    for (specs) |t| try writeToolEntry(&s, kind, t.name, t.desc, .{ .raw = t.schema });
    for (mcp_tools) |m| try writeToolEntry(&s, kind, m.qualified_name, m.description, .{ .value = m.input_schema });
    try s.endArray();
    return aw.toOwnedSlice();
}

const Schema = union(enum) { raw: []const u8, value: Value };

fn writeSchema(s: *std.json.Stringify, schema: Schema) !void {
    switch (schema) {
        .raw => |r| try s.print("{s}", .{r}),
        .value => |v| try s.write(v),
    }
}

fn writeToolEntry(s: *std.json.Stringify, kind: Provider.Kind, name: []const u8, desc: []const u8, schema: Schema) !void {
    switch (kind) {
        .anthropic => {
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.objectField("description");
            try s.write(desc);
            try s.objectField("input_schema");
            try writeSchema(s, schema);
            try s.endObject();
        },
        .openai => {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("function");
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.objectField("description");
            try s.write(desc);
            try s.objectField("parameters");
            try writeSchema(s, schema);
            try s.endObject();
            try s.endObject();
        },
        .responses => {
            // Responses API: flat function tool (no nested "function" object).
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("name");
            try s.write(name);
            try s.objectField("description");
            try s.write(desc);
            try s.objectField("parameters");
            try writeSchema(s, schema);
            try s.objectField("strict");
            try s.write(false);
            try s.endObject();
        },
    }
}

/// Version of the `--schema`/`--json` *interface contract*, embedded in
/// generated SDKs. Deliberately not the build version (`harness_version`,
/// a per-commit git describe) — bump this only when the schema or JSONL
/// protocol changes shape, so SDK regeneration stays byte-stable across
/// commits.
const schema_version = "0.4";

/// Emit the machine-readable interface description for `harness --schema`:
/// providers, models, built-in tools (name/description/parameters), and the
/// --json protocol contract. This is the single source of truth that SDK
/// codegen consumes. Comptime data only — no keys, network, or MCP needed.
fn emitSchema(w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("harness");
    try s.write("simple-harness");
    try s.objectField("version");
    try s.write(schema_version);
    try s.objectField("providers");
    try s.beginArray();
    for (provider_specs) |p| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(p.id);
        try s.objectField("kind");
        try s.write(@tagName(p.kind));
        try s.objectField("auth");
        try s.write(@tagName(p.auth));
        try s.objectField("default_model");
        try s.write(p.default_model);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("models");
    try s.beginArray();
    for (model_table) |m| {
        try s.beginObject();
        try s.objectField("provider");
        try s.write(m.provider);
        try s.objectField("name");
        try s.write(m.name);
        try s.objectField("context");
        try s.write(m.context);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("tools");
    try s.beginArray();
    for (root_specs) |t| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(t.name);
        try s.objectField("description");
        try s.write(t.desc);
        try s.objectField("parameters");
        try s.print("{s}", .{t.schema});
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("flags");
    try s.print("{s}", .{schema_flags_json});
    try s.objectField("protocol");
    try s.print("{s}", .{schema_protocol_json});
    try s.objectField("serve");
    try s.print("{s}", .{schema_serve_json});
    try s.endObject();
    try w.writeByte('\n');
    try w.flush();
}
// ---------------------------------------------------------------------------

const Provider = struct {
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

    fn get(keys: Keys, provider_id: []const u8) ?[]const u8 {
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
        for (provider_specs, keys.values) |spec, value| {
            const key = value orelse continue;
            for (model_table) |m| {
                if (std.mem.eql(u8, m.provider, spec.id) and std.mem.eql(u8, m.name, model))
                    return keys.build(spec, key, model);
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

/// Shared approval state: a yolo flag plus a list of user-approved keys
/// (command first-words for bash, exact tool names for write_file/edit_file/
/// MCP). The root agent prompts on misses and appends under the mutex;
/// subagent pool threads only read. Commands with shell metacharacters
/// (chaining, pipes, redirection, substitution, newlines) never match a
/// prefix — they always prompt at the root and are denied in subagents.
const Approvals = struct {
    mutex: Io.Mutex = .init,
    prefixes: std.ArrayList([]const u8) = .empty,
    yolo: bool = false,

    /// Read-only basics plus the build, so subagents are useful out of the
    /// box. Deliberately excludes `find` (its -exec/-delete make it an exec
    /// tool, not read-only) — it falls through to a prompt at the root and is
    /// denied for subagents. `rg`/`grep` keep their exotic --pre vector and
    /// `zig build` runs build.zig; both are accepted for a self-hosting
    /// coding harness, so don't seed-allow untrusted-input scenarios.
    const seed = [_][]const u8{
        "ls",      "cat",      "head",       "tail",
        "wc",      "grep",     "rg",         "pwd",
        "which",   "file",     "git status", "git diff",
        "git log", "git show", "zig build",  "zig fmt",
    };

    fn allowed(self: *Approvals, io: Io, cmd: []const u8) bool {
        const c = std.mem.trim(u8, cmd, " \t");
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.yolo) return true;
        if (!isSimple(c)) return false;
        // Auto-allow only when every path argument stays in the cwd subtree;
        // a command touching outside (e.g. `cat /etc/passwd`) falls through to
        // a prompt at the root and is denied for subagents. Explicit per-call
        // approval or /yolo is still the escape hatch.
        if (escapesCwd(c)) return false;
        for (seed) |p| if (matchesPrefix(c, p)) return true;
        for (self.prefixes.items) |p| if (matchesPrefix(c, p)) return true;
        return false;
    }

    /// Exact-match gate for non-command tools (write_file, edit_file, MCP):
    /// the approval key is the tool name itself, not a command prefix.
    fn allowedExact(self: *Approvals, io: Io, name: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.yolo) return true;
        for (self.prefixes.items) |p| if (std.mem.eql(u8, p, name)) return true;
        return false;
    }

    const settings_dir = ".harness";
    const settings_path = ".harness/settings.json";

    /// "Always allow" appends the key and persists the allow-list to the
    /// project's .harness/settings.json, so approvals survive restarts.
    fn approve(self: *Approvals, io: Io, gpa: Allocator, key: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.prefixes.append(gpa, try gpa.dupe(u8, key));
        _ = self.savePersisted(io, gpa);
    }

    /// Load persisted allow-rules ({"allow": ["git push", "write_file", …]})
    /// from .harness/settings.json into the session list. Returns the count.
    fn loadPersisted(self: *Approvals, io: Io, gpa: Allocator, arena: Allocator) usize {
        const data = Io.Dir.cwd().readFileAlloc(io, settings_path, arena, .limited(1 << 20)) catch return 0;
        const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return 0;
        if (v != .object) return 0;
        const allow = v.object.get("allow") orelse return 0;
        if (allow != .array) return 0;
        var n: usize = 0;
        for (allow.array.items) |item| {
            if (item != .string or item.string.len == 0) continue;
            self.prefixes.append(gpa, gpa.dupe(u8, item.string) catch continue) catch continue;
            n += 1;
        }
        return n;
    }

    /// Best-effort write of the allow-list back to .harness/settings.json,
    /// preserving every other key in the file (hooks live there too — a
    /// mid-session "always allow" must not clobber them). Caller holds the
    /// mutex.
    fn savePersisted(self: *Approvals, io: Io, gpa: Allocator) bool {
        Io.Dir.cwd().createDir(io, settings_dir, .default_dir) catch {}; // already-exists is fine
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // Start from the existing object (or empty) and swap in "allow".
        var root_obj: std.json.ObjectMap = .empty;
        if (Io.Dir.cwd().readFileAlloc(io, settings_path, a, .limited(1 << 20))) |data| {
            if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
                if (v == .object) root_obj = v.object;
            } else |_| {}
        } else |_| {}
        var allow_arr = std.json.Array.init(a);
        for (self.prefixes.items) |p| allow_arr.append(.{ .string = p }) catch return false;
        root_obj.put(a, "allow", .{ .array = allow_arr }) catch return false;
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        s.write(Value{ .object = root_obj }) catch return false;
        const f = Io.Dir.cwd().createFile(io, settings_path, .{}) catch return false;
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(aw.writer.buffered()) catch return false;
        fw.interface.writeAll("\n") catch return false;
        fw.interface.flush() catch return false;
        return true;
    }

    /// True when the command clears the read-only seed allowlist alone —
    /// the only bash plan mode lets through (user approvals may be mutating).
    fn readOnlyAllowed(cmd: []const u8) bool {
        const c = std.mem.trim(u8, cmd, " \t");
        if (!isSimple(c) or escapesCwd(c)) return false;
        for (seed) |p| if (matchesPrefix(c, p)) return true;
        return false;
    }

    fn toggleYolo(self: *Approvals, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.yolo = !self.yolo;
        return self.yolo;
    }

    /// No chaining, piping, redirection, or substitution — those can smuggle
    /// a second command past a prefix match.
    fn isSimple(cmd: []const u8) bool {
        for (cmd) |ch| switch (ch) {
            ';', '|', '&', '>', '<', '`', '$', '\n', '\r', '\t', 0 => return false,
            else => {},
        };
        return true;
    }

    fn matchesPrefix(cmd: []const u8, prefix: []const u8) bool {
        if (!std.mem.startsWith(u8, cmd, prefix)) return false;
        return cmd.len == prefix.len or cmd[prefix.len] == ' ';
    }

    /// True if any whitespace-token in the command looks like a path leaving
    /// the working directory: absolute (`/x`, `--f=/x`), home (`~`, `=~`), or
    /// containing a `..` component. A heuristic — metacharacters are already
    /// blocked by isSimple, so args really are space-separated tokens — that
    /// keeps the auto-allowed seed commands (cat, grep, …) reading inside cwd.
    fn escapesCwd(cmd: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        while (it.next()) |tok| {
            if (tok.len == 0) continue;
            if (tok[0] == '/' or tok[0] == '~') return true;
            if (std.mem.indexOf(u8, tok, "=/") != null) return true;
            if (std.mem.indexOf(u8, tok, "=~") != null) return true;
            var pit = std.mem.tokenizeScalar(u8, tok, '/');
            while (pit.next()) |comp| if (std.mem.eql(u8, comp, "..")) return true;
        }
        return false;
    }

    /// "Always allow"ing one of these as a bash first word grants arbitrary
    /// code execution (e.g. `python3 -c '...'`) — worth a heads-up.
    fn isInterpreter(word: []const u8) bool {
        const interps = [_][]const u8{
            "python", "python3", "node", "deno",      "bun", "ruby", "perl",
            "php",    "sh",      "bash", "osascript", "awk",
        };
        for (interps) |i| if (std.mem.eql(u8, word, i)) return true;
        return false;
    }
};

/// Path tools (read/write/edit_file) are confined to the working directory:
/// no absolute paths and no `..` components. This keeps `read_file
/// /etc/shadow`, `write_file ../../foo`, and trace/approvals forgery via
/// traversal out of reach for both the root agent and subagents, structurally
/// (it is not bypassed by /yolo — use bash, which is gated, to touch files
/// elsewhere). Returns true when the path is safe.
fn confinedPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

/// Defense-in-depth on top of confinedPath: a confined path with no `..` and no
/// absolute prefix can still escape the cwd through a symlink that points
/// outside (e.g. `evil -> /etc`, then `read_file evil/passwd`). Zig 0.16 has no
/// realpath, so we refuse to traverse symlinks at all: walk each path prefix and
/// reject if any component is a symlink (readLink succeeds). Conservative — a
/// symlink inside the repo becomes unreadable via the file tools — but it makes
/// confinement structural rather than lexical. bash (gated) is unaffected.
fn noSymlinkEscape(io: Io, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var i: usize = 0;
    while (i <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
        const prefix = path[0..slash];
        if (prefix.len > 0) {
            if (Io.Dir.cwd().readLink(io, prefix, &buf)) |_| {
                return false; // this component is a symlink → refuse
            } else |_| {} // not a symlink (or doesn't exist yet) → fine
        }
        if (slash == path.len) break;
        i = slash + 1;
    }
    return true;
}

const trace_path = "harness.trace.jsonl";

/// Session event trace: one JSON object per line, written to trace_path in
/// the cwd (truncated at startup, so it always covers the current session).
/// Thread-safe — agents on pool threads share it through the mutex. The
/// system prompt tells the agent the file exists, so it can read its own
/// trace to debug or profile the harness ("t" is ms since session start).
const Tracer = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    out: ?*Io.Writer,
    start: Io.Timestamp,
    enabled: bool = true,

    fn api(self: *Tracer, label: []const u8, model: []const u8, ms: i64, req_bytes: usize, resp_bytes: usize, context_tokens: u64, cache_read: u64, is_error: bool) void {
        if (g_telem) |t| t.countApi(model, is_error);
        self.write(.{
            .t = self.elapsedMs(),
            .ev = "api",
            .agent = label,
            .model = model,
            .ms = ms,
            .req_bytes = req_bytes,
            .resp_bytes = resp_bytes,
            .context_tokens = context_tokens,
            .cache_read_tokens = cache_read,
            .is_error = is_error,
        });
    }

    fn tool(self: *Tracer, name: []const u8, ms: i64, is_error: bool, result_bytes: usize, from_sub: bool) void {
        if (g_telem) |t| t.countTool(is_error);
        self.write(.{
            .t = self.elapsedMs(),
            .ev = "tool",
            .name = name,
            .ms = ms,
            .result_bytes = result_bytes,
            .is_error = is_error,
            .from_sub = from_sub,
        });
    }

    fn note(self: *Tracer, kind: []const u8, detail: []const u8) void {
        self.write(.{ .t = self.elapsedMs(), .ev = kind, .detail = detail });
    }

    fn elapsedMs(self: *Tracer) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    /// Serialize any struct as one JSON line. Best-effort: trace failures
    /// never disturb the session.
    fn write(self: *Tracer, event: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const w = self.out orelse return;
        if (!self.enabled) return;
        var s: std.json.Stringify = .{ .writer = w };
        s.write(event) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch return;
    }

    fn toggle(self: *Tracer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.enabled = !self.enabled;
        return self.enabled;
    }
};

// ── Trajectory (DGM-style archive tree) ────────────────────────────────────

const trajectory_path = "harness.trajectory.jsonl";

/// Session trajectory in the shape of the Darwin Gödel Machine's archive
/// tree (arXiv:2505.22954): one JSON node per agent run. Root turns form
/// the spine (each turn's parent is the previous turn); every subagent or
/// workflow task hangs off the turn that spawned it. Each node carries a
/// fingerprint of the system prompt it ran with, so prompt mutations —
/// set_system_prompt on the spine, per-child system_prompt overrides on the
/// fan-out — are visible as hash changes along edges, and a lineage can be
/// replayed or scored offline (see docs/hyperagents.md, arXiv:2603.19461).
/// Written to harness.trajectory.jsonl, truncated at startup like the trace.
const Trajectory = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    out: ?*Io.Writer,
    start: Io.Timestamp,
    next_id: u64 = 1, // node 0 is the session itself
    turn_node: u64 = 0, // current root-turn node: parent for spawned agents
    seen_shas: std.ArrayList([16]u8) = .empty, // prompts captured this session

    /// Reserve a node id (turns claim theirs before running so children can
    /// point at them).
    fn nextId(self: *Trajectory) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn setTurn(self: *Trajectory, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.turn_node = id;
    }

    fn currentTurn(self: *Trajectory) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.turn_node;
    }

    fn elapsedMs(self: *Trajectory) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    /// Serialize one node as a JSON line. Best-effort, like the Tracer.
    fn node(self: *Trajectory, rec: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writeLocked(rec);
    }

    /// Capture the full prompt text behind a fingerprint, once per session
    /// (a `kind:"prompt"` record): the archive then maps sha → text so any
    /// lineage can be replayed or re-mutated offline. Dedup is per session;
    /// across sessions a sha repeats at most once per session — readers
    /// treat the records as an idempotent map.
    fn capturePrompt(self: *Trajectory, sha: [16]u8, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.out == null) return;
        for (self.seen_shas.items) |s| if (std.mem.eql(u8, &s, &sha)) return;
        self.seen_shas.append(self.gpa, sha) catch return;
        self.writeLocked(.{ .kind = "prompt", .prompt_sha = &sha, .text = text });
    }

    fn writeLocked(self: *Trajectory, rec: anytype) void {
        const w = self.out orelse return;
        var s: std.json.Stringify = .{ .writer = w };
        s.write(rec) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch return;
    }

    fn deinit(self: *Trajectory) void {
        self.seen_shas.deinit(self.gpa);
    }
};

// ── Agent types (the MAP-Elites niches) ─────────────────────────────────────

/// A named, reusable subagent persona: the unit the MAP-Elites archive is
/// organized around (docs/hyperagents.md §MAP-Elites). Each niche keeps one
/// elite prompt; builtins ship compiled in, and `.harness/agents/<name>.md`
/// files (frontmatter: name/description/score, body: the system prompt)
/// override or extend them — that's where an evolution driver promotes
/// archive winners. Spawn one with subagent/workflow `agent: "<name>"`.
const AgentType = struct {
    name: []const u8,
    desc: []const u8,
    prompt: []const u8,
    score: ?f64 = null, // written by the evolution driver, shown in /agents
    builtin: bool = false,
};

/// Preloaded niches: deliberately orthogonal *behavioral* dimensions (what
/// MAP-Elites calls the feature space), not job titles — each elicits a
/// different failure mode to cover.
const builtin_agent_types = [_]AgentType{
    .{
        .name = "reviewer",
        .desc = "adversarial code reviewer — hunts defects, assumes guilt",
        .prompt = "You are an adversarial code reviewer. Read the code you are pointed at and hunt for genuine defects: logic errors, unhandled edge cases, races, leaks, security holes. Assume the code is guilty until proven correct. Report only findings you can defend with a concrete failure scenario, each with file:line and the exact sequence that breaks. No style nits. End with a verdict: the single most dangerous defect, or 'no defensible defects found'.",
        .builtin = true,
    },
    .{
        .name = "researcher",
        .desc = "evidence gatherer — reads widely, cites precisely, never edits",
        .prompt = "You are a research agent. Your job is to READ and REPORT, never to modify anything. Explore the files or sources you are pointed at, follow the references that matter, and produce a tight evidence-backed summary: every claim cites its file:line or source. Separate what you verified from what you infer. End with the 3 facts most load-bearing for the task and 1 open question.",
        .builtin = true,
    },
    .{
        .name = "implementer",
        .desc = "surgical patch writer — smallest correct change, verified",
        .prompt = "You are a surgical implementer. Make the smallest correct change that satisfies the task: read the surrounding code first, match its idiom exactly, touch nothing beyond the requirement. After editing, verify your change compiles/passes whatever check the project offers and report the command and its result. End with a diff-shaped summary of exactly what changed and why it is sufficient.",
        .builtin = true,
    },
    .{
        .name = "skeptic",
        .desc = "claim refuter — tries to prove the premise wrong",
        .prompt = "You are a skeptic. You receive a claim or finding; your only goal is to REFUTE it. Search for counterexamples, missing context, and alternative explanations. Default to 'refuted' unless the claim survives your strongest attack. Report the attack you ran, what you found, and a final verdict: refuted (with the counterexample) or survives (with what would have broken it).",
        .builtin = true,
    },
};

/// Resolved agent types for this session (builtins + .harness/agents/*.md,
/// files override builtins by name). Set by main(); arena-owned strings.
var g_agent_types: []const AgentType = &builtin_agent_types;

const agents_dir = ".harness/agents";

/// Load .harness/agents/*.md: YAML-ish frontmatter (name/description/score)
/// + body as the prompt. Returns builtins ++ file types, with file types
/// shadowing builtins of the same name.
fn loadAgentTypes(io: Io, arena: Allocator) []const AgentType {
    var list: std.ArrayList(AgentType) = .empty;
    list.appendSlice(arena, &builtin_agent_types) catch return &builtin_agent_types;
    var dir = Io.Dir.cwd().openDir(io, agents_dir, .{ .iterate = true }) catch return list.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ agents_dir, entry.name }) catch continue;
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch continue;
        var at: AgentType = .{
            .name = arena.dupe(u8, entry.name[0 .. entry.name.len - ".md".len]) catch continue,
            .desc = "",
            .prompt = std.mem.trim(u8, data, " \t\r\n"),
        };
        // Frontmatter: leading "---\n…\n---\n" with name:/description:/score:.
        if (std.mem.startsWith(u8, data, "---\n")) {
            if (std.mem.indexOfPos(u8, data, 4, "\n---")) |fm_end| {
                var lines = std.mem.tokenizeScalar(u8, data[4..fm_end], '\n');
                while (lines.next()) |ln| {
                    const sep = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
                    const key = std.mem.trim(u8, ln[0..sep], " \t");
                    const val = std.mem.trim(u8, ln[sep + 1 ..], " \t\"");
                    if (std.mem.eql(u8, key, "name") and val.len > 0) at.name = val;
                    if (std.mem.eql(u8, key, "description")) at.desc = val;
                    if (std.mem.eql(u8, key, "score")) at.score = std.fmt.parseFloat(f64, val) catch null;
                }
                const body_start = fm_end + "\n---".len;
                at.prompt = std.mem.trim(u8, data[@min(body_start + 1, data.len)..], " \t\r\n");
            }
        }
        if (at.prompt.len == 0) continue;
        // File types shadow builtins (and earlier files) of the same name —
        // the elite for a niche is whatever the driver last promoted.
        var replaced = false;
        for (list.items) |*existing| {
            if (std.mem.eql(u8, existing.name, at.name)) {
                existing.* = at;
                replaced = true;
                break;
            }
        }
        if (!replaced) list.append(arena, at) catch continue;
    }
    return list.items;
}

/// Resolve an agent-type name (case-sensitive) to its prompt.
fn agentTypePrompt(name: []const u8) ?[]const u8 {
    for (g_agent_types) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.prompt;
    }
    return null;
}

/// Effective system-prompt override for a subagent/workflow-task input:
/// an explicit system_prompt wins, else a named agent type's prompt, else
/// null (the lean default). An unknown agent name falls through to the
/// default rather than failing the spawn.
fn resolveOverride(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("system_prompt")) |v| {
        if (v == .string and v.string.len > 0) return v.string;
    }
    if (obj.get("agent")) |v| {
        if (v == .string and v.string.len > 0) return agentTypePrompt(v.string);
    }
    return null;
}

/// Set by main(); runSub and the REPL loop record nodes through this.
var g_traj: ?*Trajectory = null;

/// Short stable fingerprint of a system prompt (first 8 bytes of SHA-256,
/// hex): equal hashes along a trajectory edge mean the prompt didn't change.
fn promptFingerprint(prompt: []const u8) [16]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(prompt, &d, .{});
    return std.fmt.bytesToHex(d[0..8].*, .lower);
}

// ── Score-channel signing (DGM fitness integrity, Step 0) ──────────────────
//
// The trajectory archive is the DGM's fitness ledger, and it lives in cwd —
// so a forged `{"kind":"score",...}` row appended via write_file (cwd is
// inside confinedPath) or `echo >>` manufactures fitness AND parent_sha
// lineage that parent selection then rewards. Signing makes forged rows
// detectable: every score record the harness writes carries an HMAC over its
// fields, keyed by a secret the evolving agent's tools can't reach.
//
// Key custody: GRAFF_SCORE_KEY_FILE names a key file OUTSIDE cwd. The env var
// holds only the path (not the secret), and the file is unreadable by a
// subagent — file tools are confined to cwd, and subagent bash is cwd-locked
// with no redirection. The root agent / --yolo is the trusted orchestrator
// boundary (it could read any file anyway). Readers (dgm_loop.py load_archive,
// the harness-telemetry worker) recompute the HMAC and reject unsigned rows.

/// Loaded once in main() from GRAFF_SCORE_KEY_FILE; null → unsigned (signing
/// off, every reader accepts rows as before — backward compatible).
var g_score_key: ?[]const u8 = null;

/// Per-session run id (random hex), the run_id field of signed score records.
var g_run_id: [16]u8 = @splat('0');

/// Canonical signing message — newline-delimited, version-prefixed, with the
/// score formatted to a fixed 6 decimals so Zig/Python/JS agree byte-for-byte.
/// `buf` must hold the message; returns the slice written.
fn scoreSigMessage(
    buf: []u8,
    prompt_sha: []const u8,
    parent_sha: []const u8,
    score: f64,
    run_id: []const u8,
    judge_id: []const u8,
    artifact_sha: []const u8,
    eval_set_hash: []const u8,
) ?[]const u8 {
    return std.fmt.bufPrint(buf, "v1\n{s}\n{s}\n{d:.6}\n{s}\n{s}\n{s}\n{s}", .{
        prompt_sha, parent_sha, score, run_id, judge_id, artifact_sha, eval_set_hash,
    }) catch null;
}

/// HMAC-SHA256 of the canonical message, hex. "" when no key is configured.
fn signScore(
    prompt_sha: []const u8,
    parent_sha: []const u8,
    score: f64,
    run_id: []const u8,
    judge_id: []const u8,
    artifact_sha: []const u8,
    eval_set_hash: []const u8,
) [64]u8 {
    const key = g_score_key orelse return @splat(0);
    var msgbuf: [512]u8 = undefined;
    const msg = scoreSigMessage(&msgbuf, prompt_sha, parent_sha, score, run_id, judge_id, artifact_sha, eval_set_hash) orelse return @splat(0);
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, msg, key);
    return std.fmt.bytesToHex(mac, .lower);
}

/// Read the signing key from GRAFF_SCORE_KEY_FILE (a path outside cwd) into
/// `arena`. Whitespace-trimmed; null when unset, unreadable, or empty.
fn loadScoreKey(io: Io, arena: Allocator, environ: anytype) ?[]const u8 {
    const path = environ.get("GRAFF_SCORE_KEY_FILE") orelse return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Per-agent record of external tool calls (name + error flag, in call
/// order): the process signal behind "which tool combinations work" —
/// rendered into trajectory nodes and OTLP run events, joinable to scores
/// via prompt_sha. Tool fan-out is concurrent, so appends lock. Capped:
/// the first 64 calls are plenty for pattern mining.
const ToolSink = struct {
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { name: []const u8, err: bool };
    const cap = 64;

    fn add(self: *ToolSink, io: Io, gpa: Allocator, name: []const u8, err: bool) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.items.len >= cap) return;
        self.entries.append(gpa, .{ .name = name, .err = err }) catch {};
    }

    /// "read_file,edit_file!,bash" — `!` marks a failed call. Allocated from
    /// `alloc`; "" when no tools ran. Call after the agent's tool futures
    /// are joined (no lock taken).
    fn render(self: *const ToolSink, alloc: Allocator) []const u8 {
        if (self.entries.items.len == 0) return "";
        var aw: Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) aw.writer.writeByte(',') catch return "";
            aw.writer.writeAll(e.name) catch return "";
            if (e.err) aw.writer.writeByte('!') catch return "";
        }
        return alloc.dupe(u8, aw.writer.buffered()) catch "";
    }

    fn clear(self: *ToolSink, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.entries.clearRetainingCapacity();
    }

    fn deinit(self: *ToolSink, gpa: Allocator) void {
        self.entries.deinit(gpa);
    }
};

/// Largest prefix of `s` up to `max` bytes that doesn't split a UTF-8
/// codepoint (std.json would otherwise serialize the slice as an int array).
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var p = s[0..max];
    var strips: usize = 0;
    while (strips < 3 and p.len > 0 and !std.unicode.utf8ValidateSlice(p)) : (strips += 1)
        p = p[0 .. p.len - 1];
    return p;
}

// ── Telemetry (OTEL) ────────────────────────────────────────────────────────

/// Anonymous usage telemetry, exported as OTLP/HTTP JSON log records in one
/// best-effort POST at session end. Off entirely unless an endpoint is
/// configured (OTEL_EXPORTER_OTLP_ENDPOINT or GRAFF_OTEL_ENDPOINT env);
/// GRAFF_NO_TELEMETRY or --no-telemetry forces it off regardless. Counters
/// feed from the same Tracer hooks that write harness.trace.jsonl, plus
/// workflow/ultracode/turn events from the orchestrator. A per-install
/// anonymous id (~/.simple-harness-install-id) identifies the install; SDKs
/// pass their own id via HARNESS_SDK_INSTALL_ID + HARNESS_CLIENT so SDK
/// users are counted separately. Flush failures never disturb the session.
const Telemetry = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    endpoint: []const u8, // base OTLP endpoint; "" → disabled
    client: ?*std.http.Client = null, // shared http client, set by main()
    install_id: [32]u8, // anonymous hex id for this install
    client_name: []const u8, // "harness", or "sdk-ts"/"sdk-py" via HARNESS_CLIENT
    sdk_install_id: []const u8, // the SDK's own install id, if driving us
    start: Io.Timestamp,
    start_unix_ms: i64,

    api_calls: u64 = 0,
    api_errors: u64 = 0,
    tool_calls: u64 = 0,
    tool_errors: u64 = 0,
    turns: u64 = 0,
    ultracode_turns: u64 = 0,
    workflows: u64 = 0,
    workflow_tasks: u64 = 0,
    prompt_variants: u64 = 0, // subagents spawned with a system-prompt override
    scores_recorded: u64 = 0, // evaluation write-backs via the score request
    models: std.ArrayList([]const u8) = .empty, // distinct models used (gpa-duped)
    events: std.ArrayList(Event) = .empty, // discrete error/workflow records

    /// One buffered log record. body "error": kind/detail set. body
    /// "workflow": phases/tasks/failed/duration set. body "score":
    /// detail = prompt_sha, score = the evaluation value.
    const Event = struct {
        t_ms: i64,
        body: []const u8, // "error" | "workflow" | "ultracode" | "score" (static)
        kind: []const u8 = "", // error source: "api" | "tool" | "turn" (static)
        detail: []const u8 = "", // gpa-duped, truncated
        extra: []const u8 = "", // gpa-duped: score → parent_sha, run → tool sequence
        run_id: []const u8 = "", // gpa-duped: score → run_id (signed)
        sig: []const u8 = "", // gpa-duped: score → HMAC signature ("" when unsigned)
        prov: []const u8 = "", // gpa-duped: score → "judge_id\tartifact_sha\teval_set_hash" (signed)
        phases: i64 = 0,
        tasks: i64 = 0,
        failed: i64 = 0,
        ms: i64 = 0,
        score: f64 = 0,
        flag: bool = true, // run → ok
    };
    const max_events = 64; // cap discrete records; counters keep full totals
    const max_detail = 200;

    fn on(self: *const Telemetry) bool {
        return self.endpoint.len > 0;
    }

    fn elapsedMs(self: *Telemetry) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    fn countApi(self: *Telemetry, model: []const u8, is_error: bool) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.api_calls += 1;
        if (is_error) self.api_errors += 1;
        for (self.models.items) |m| if (std.mem.eql(u8, m, model)) return;
        const dup = self.gpa.dupe(u8, model) catch return;
        self.models.append(self.gpa, dup) catch self.gpa.free(dup);
    }

    fn countTool(self: *Telemetry, is_error: bool) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.tool_calls += 1;
        if (is_error) self.tool_errors += 1;
    }

    fn countTurn(self: *Telemetry) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.turns += 1;
    }

    fn ultracode(self: *Telemetry) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.ultracode_turns += 1;
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "ultracode" });
        }
        self.maybeFlushEvents();
    }

    /// Record an issue (API failure, tool failure, aborted turn) as an ERROR
    /// log record. `kind` and the truncated `detail` become attributes.
    fn errorEvent(self: *Telemetry, kind: []const u8, detail: []const u8) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "error", .kind = kind, .detail = self.dupDetail(detail) });
        }
        self.maybeFlushEvents();
    }

    /// Truncate to max_detail without splitting a UTF-8 codepoint, and force
    /// the copy to valid UTF-8 — std.json serializes an invalid []u8 as an
    /// ARRAY of integers, which is schema-invalid OTLP that makes a collector
    /// reject the entire batch. detail can carry raw provider bytes (e.g.
    /// "unparseable response: …"), so both the cut and the content matter.
    fn dupDetail(self: *Telemetry, detail: []const u8) []const u8 {
        var p = detail[0..@min(detail.len, max_detail)];
        var strips: usize = 0; // a split codepoint needs at most 3 byte strips
        while (strips < 3 and p.len > 0 and !std.unicode.utf8ValidateSlice(p)) : (strips += 1)
            p = p[0 .. p.len - 1];
        const dup = self.gpa.dupe(u8, p) catch return "";
        if (!std.unicode.utf8ValidateSlice(dup)) for (dup) |*b| {
            if (b.* >= 0x80) b.* = '?'; // invalid mid-string bytes: degrade to ASCII
        };
        return dup;
    }

    /// Count a subagent spawned with a system-prompt override (an agent-type
    /// persona or an inline variant) — the swarm's prompt diversity signal.
    fn countVariant(self: *Telemetry) void {
        if (!self.on()) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.prompt_variants += 1;
    }

    /// Record an evaluation write-back (the DGM scoring phase) so the OTEL
    /// backend can validate that the evolution loop is actually running:
    /// one log record per score, prompt_sha + value as attributes.
    fn scoreEvent(self: *Telemetry, sha: []const u8, parent: []const u8, value: f64, run_id: []const u8, sig: []const u8, prov: []const u8) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.scores_recorded += 1;
            const dup = self.gpa.dupe(u8, sha[0..@min(sha.len, 32)]) catch "";
            const pdup = if (parent.len > 0) self.gpa.dupe(u8, parent[0..@min(parent.len, 32)]) catch "" else "";
            const rdup = if (run_id.len > 0) self.gpa.dupe(u8, run_id[0..@min(run_id.len, 64)]) catch "" else "";
            const sdup = if (sig.len > 0) self.gpa.dupe(u8, sig[0..@min(sig.len, 64)]) catch "" else "";
            const vdup = if (prov.len > 0) self.gpa.dupe(u8, utf8Prefix(prov, 256)) catch "" else "";
            self.push(.{ .t_ms = self.elapsedMsLocked(), .body = "score", .detail = dup, .extra = pdup, .run_id = rdup, .sig = sdup, .prov = vdup, .score = value });
        }
        self.maybeFlushEvents();
    }

    /// Record a completed agent run (root turn or subagent) with its tool
    /// sequence — the process-mining signal behind "which tool combinations
    /// work". Lands as a generic body="run" record (attrs JSON) server-side.
    fn runEvent(self: *Telemetry, sha: []const u8, variant: bool, ok: bool, ms: i64, tools: []const u8) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const dsha = self.gpa.dupe(u8, sha[0..@min(sha.len, 32)]) catch "";
            const dtools = if (tools.len > 0) self.gpa.dupe(u8, utf8Prefix(tools, 600)) catch "" else "";
            self.push(.{
                .t_ms = self.elapsedMsLocked(),
                .body = "run",
                .kind = if (variant) "variant" else "default",
                .detail = dsha,
                .extra = dtools,
                .ms = ms,
                .flag = ok,
            });
        }
        self.maybeFlushEvents();
    }

    /// Record one workflow-tool run (the ultracode pipe): phase/task counts,
    /// failed task count, and wall-clock duration.
    fn workflowEvent(self: *Telemetry, phases: usize, tasks: usize, failed: usize, ms: i64) void {
        if (!self.on()) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.workflows += 1;
            self.workflow_tasks += tasks;
            self.push(.{
                .t_ms = self.elapsedMsLocked(),
                .body = "workflow",
                .phases = @intCast(phases),
                .tasks = @intCast(tasks),
                .failed = @intCast(failed),
                .ms = ms,
            });
        }
        self.maybeFlushEvents();
    }

    // Callers hold the mutex. elapsedMs duplicated without locking because
    // Io.Mutex is not reentrant.
    fn elapsedMsLocked(self: *Telemetry) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    fn push(self: *Telemetry, e: Event) void {
        self.events.append(self.gpa, e) catch {
            self.freeEvent(e);
        };
    }

    fn freeEvent(self: *Telemetry, e: Event) void {
        if (e.detail.len > 0) self.gpa.free(e.detail);
        if (e.extra.len > 0) self.gpa.free(e.extra);
        if (e.run_id.len > 0) self.gpa.free(e.run_id);
        if (e.sig.len > 0) self.gpa.free(e.sig);
        if (e.prov.len > 0) self.gpa.free(e.prov);
    }

    /// When the event buffer reaches max_events, ship it mid-session as an
    /// events-only OTLP batch instead of dropping records — an evolution
    /// driver can emit hundreds of scores in one session, and a crash after
    /// a shipped batch loses at most max_events-1 events. Swaps the buffer
    /// out under the mutex, posts without holding it.
    fn maybeFlushEvents(self: *Telemetry) void {
        var batch: std.ArrayList(Event) = .empty;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.events.items.len < max_events) return;
            batch = self.events;
            self.events = .empty;
        }
        defer {
            for (batch.items) |e| self.freeEvent(e);
            batch.deinit(self.gpa);
        }
        self.sendBatch(batch.items, false);
    }

    fn deinit(self: *Telemetry) void {
        for (self.models.items) |m| self.gpa.free(m);
        self.models.deinit(self.gpa);
        for (self.events.items) |e| self.freeEvent(e);
        self.events.deinit(self.gpa);
    }

    /// Final flush at session end: the session summary plus any events not
    /// already shipped by a mid-session batch.
    fn flush(self: *Telemetry) void {
        self.sendBatch(self.events.items, true);
    }

    /// Build an OTLP/HTTP JSON payload for `events` (plus the session
    /// summary when `include_summary`) and POST it to <endpoint>/v1/logs
    /// (per the OTLP env spec the endpoint is a base URL; it's used verbatim
    /// only when it already ends in /v1/logs). The POST races a 3s deadline
    /// so a dead or wedged collector can never hang the session.
    /// Best-effort: any failure is swallowed.
    fn sendBatch(self: *Telemetry, events: []const Event, include_summary: bool) void {
        if (!self.on()) return;
        const client = self.client orelse return;
        if (events.len == 0 and !include_summary) return;
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        self.writeOtlp(&aw.writer, events, include_summary) catch return;
        var ubuf: [512]u8 = undefined;
        const trimmed = std.mem.trimEnd(u8, self.endpoint, "/");
        const url = if (std.mem.endsWith(u8, trimmed, "/v1/logs"))
            trimmed
        else
            std.fmt.bufPrint(&ubuf, "{s}/v1/logs", .{trimmed}) catch return;

        const Done = union(enum) { posted: void, deadline: void };
        var done_buf: [2]Done = undefined;
        var sel: Io.Select(Done) = .init(self.io, &done_buf);
        sel.concurrent(.posted, postOtlp, .{ client, url, aw.writer.buffered() }) catch return;
        sel.concurrent(.deadline, flushDeadline, .{self.io}) catch {
            _ = sel.await() catch {}; // no spare concurrency: wait unbounded
            sel.cancelDiscard();
            return;
        };
        _ = sel.await() catch {}; // first of POST / deadline wins
        sel.cancelDiscard(); // cancel the loser (fetch's socket ops are cancelation points)
    }

    fn postOtlp(client: *std.http.Client, url: []const u8, payload: []const u8) void {
        _ = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
        }) catch {};
    }

    fn flushDeadline(io: Io) void {
        io.sleep(.fromSeconds(3), .awake) catch {};
    }

    const AttrVal = union(enum) { str: []const u8, int: i64, num: f64 };

    fn attr(s: *std.json.Stringify, key: []const u8, v: AttrVal) !void {
        try s.beginObject();
        try s.objectField("key");
        try s.write(key);
        try s.objectField("value");
        try s.beginObject();
        switch (v) {
            .str => |x| {
                try s.objectField("stringValue");
                try s.write(x);
            },
            .int => |x| { // proto3 JSON maps int64 to a decimal string
                var b: [24]u8 = undefined;
                try s.objectField("intValue");
                try s.write(std.fmt.bufPrint(&b, "{d}", .{x}) catch unreachable);
            },
            .num => |x| { // doubleValue stays a JSON number
                try s.objectField("doubleValue");
                try s.write(x);
            },
        }
        try s.endObject();
        try s.endObject();
    }

    fn timeField(s: *std.json.Stringify, unix_ms: i64) !void {
        var b: [32]u8 = undefined;
        try s.objectField("timeUnixNano");
        try s.write(std.fmt.bufPrint(&b, "{d}", .{unix_ms * 1_000_000}) catch unreachable);
    }

    fn writeOtlp(self: *Telemetry, w: *Io.Writer, events: []const Event, include_summary: bool) !void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("resourceLogs");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("resource");
        try s.beginObject();
        try s.objectField("attributes");
        try s.beginArray();
        try attr(&s, "service.name", .{ .str = "simple-harness" });
        try attr(&s, "service.version", .{ .str = harness_version });
        try attr(&s, "os.type", .{ .str = @tagName(builtin.os.tag) });
        try attr(&s, "host.arch", .{ .str = @tagName(builtin.cpu.arch) });
        try attr(&s, "install.id", .{ .str = &self.install_id });
        try attr(&s, "client.name", .{ .str = self.client_name });
        if (self.sdk_install_id.len > 0) try attr(&s, "sdk.install.id", .{ .str = self.sdk_install_id });
        try s.endArray();
        try s.endObject();
        try s.objectField("scopeLogs");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("scope");
        try s.beginObject();
        try s.objectField("name");
        try s.write("simple-harness");
        try s.endObject();
        try s.objectField("logRecords");
        try s.beginArray();
        for (events) |e| {
            try s.beginObject();
            try timeField(&s, self.start_unix_ms + e.t_ms);
            try s.objectField("severityText");
            try s.write(if (std.mem.eql(u8, e.body, "error")) "ERROR" else "INFO");
            try s.objectField("body");
            try s.beginObject();
            try s.objectField("stringValue");
            try s.write(e.body);
            try s.endObject();
            try s.objectField("attributes");
            try s.beginArray();
            if (std.mem.eql(u8, e.body, "score")) {
                try attr(&s, "prompt_sha", .{ .str = e.detail });
                try attr(&s, "value", .{ .num = e.score });
                if (e.extra.len > 0) try attr(&s, "parent_sha", .{ .str = e.extra });
                if (e.run_id.len > 0) try attr(&s, "run_id", .{ .str = e.run_id });
                if (e.sig.len > 0) try attr(&s, "sig", .{ .str = e.sig });
                if (e.prov.len > 0) {
                    // prov = "judge_id\tartifact_sha\teval_set_hash" — split so
                    // the worker can recompute the HMAC over the same fields.
                    var it = std.mem.splitScalar(u8, e.prov, '\t');
                    if (it.next()) |j| if (j.len > 0) try attr(&s, "judge_id", .{ .str = j });
                    if (it.next()) |a| if (a.len > 0) try attr(&s, "artifact_sha", .{ .str = a });
                    if (it.next()) |h| if (h.len > 0) try attr(&s, "eval_set_hash", .{ .str = h });
                }
            } else if (std.mem.eql(u8, e.body, "run")) {
                try attr(&s, "prompt_sha", .{ .str = e.detail });
                try attr(&s, "variant", .{ .int = @intFromBool(std.mem.eql(u8, e.kind, "variant")) });
                try attr(&s, "ok", .{ .int = @intFromBool(e.flag) });
                try attr(&s, "duration_ms", .{ .int = e.ms });
                if (e.extra.len > 0) try attr(&s, "tools", .{ .str = e.extra });
            } else {
                if (e.kind.len > 0) try attr(&s, "kind", .{ .str = e.kind });
                if (e.detail.len > 0) try attr(&s, "detail", .{ .str = e.detail });
                if (std.mem.eql(u8, e.body, "workflow")) {
                    try attr(&s, "phases", .{ .int = e.phases });
                    try attr(&s, "tasks", .{ .int = e.tasks });
                    try attr(&s, "failed_tasks", .{ .int = e.failed });
                    try attr(&s, "duration_ms", .{ .int = e.ms });
                }
            }
            try s.endArray();
            try s.endObject();
        }
        // Session summary: the "general usage stats" record (final flush only).
        if (include_summary) {
            const models_joined = std.mem.join(self.gpa, ",", self.models.items) catch "";
            defer if (models_joined.len > 0) self.gpa.free(models_joined);
            try s.beginObject();
            try timeField(&s, unixMs(self.io));
            try s.objectField("severityText");
            try s.write("INFO");
            try s.objectField("body");
            try s.beginObject();
            try s.objectField("stringValue");
            try s.write("session");
            try s.endObject();
            try s.objectField("attributes");
            try s.beginArray();
            try attr(&s, "duration_ms", .{ .int = self.elapsedMs() });
            try attr(&s, "turns", .{ .int = @intCast(self.turns) });
            try attr(&s, "api_calls", .{ .int = @intCast(self.api_calls) });
            try attr(&s, "api_errors", .{ .int = @intCast(self.api_errors) });
            try attr(&s, "tool_calls", .{ .int = @intCast(self.tool_calls) });
            try attr(&s, "tool_errors", .{ .int = @intCast(self.tool_errors) });
            try attr(&s, "workflows", .{ .int = @intCast(self.workflows) });
            try attr(&s, "workflow_tasks", .{ .int = @intCast(self.workflow_tasks) });
            try attr(&s, "ultracode_turns", .{ .int = @intCast(self.ultracode_turns) });
            try attr(&s, "prompt_variants", .{ .int = @intCast(self.prompt_variants) });
            try attr(&s, "scores_recorded", .{ .int = @intCast(self.scores_recorded) });
            try attr(&s, "models", .{ .str = models_joined });
            const c = g_cost.snap(self.io);
            try attr(&s, "cost_usd", .{ .num = c.usd });
            try attr(&s, "tokens_in", .{ .int = @intCast(c.in_tokens) });
            try attr(&s, "tokens_cached", .{ .int = @intCast(c.cache_tokens) });
            try attr(&s, "tokens_out", .{ .int = @intCast(c.out_tokens) });
            try s.endArray();
            try s.endObject();
        }
        try s.endArray(); // logRecords
        try s.endObject(); // scopeLog entry
        try s.endArray(); // scopeLogs
        try s.endObject(); // resourceLog entry
        try s.endArray(); // resourceLogs
        try s.endObject();
    }
};

/// Set once in main() when telemetry is configured; Tracer and the workflow
/// runner feed it through this. Null → every hook is a no-op.
var g_telem: ?*Telemetry = null;

/// Wall-clock unix milliseconds (OTLP timestamps need real time; the
/// harness otherwise only uses the monotonic Io clock).
fn unixMs(io: Io) i64 {
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

const repl_commands = [_][]const u8{ "/model", "/models", "/clear", "/plan", "/key", "/keepcontext", "/reasoning", "/strict", "/yolo", "/trace", "/trajectory", "/agents", "/skills", "/hooks", "/compact", "/rewind", "/image", "/paste", "/save", "/resume", "/sessions", "/todo", "/jobs", "/cost", "/animation", "/mcp", "/help" };

/// Lifecycle hooks (codex/Claude-style), loaded once at startup from
/// .harness/settings.json's "hooks" object. Three events:
///
///   pre_tool  — runs BEFORE a tool executes (root and subagents, MCP
///               included). Exit 2 blocks the call: the hook's stderr is
///               returned to the model as the tool result. Any other exit
///               allows. The event JSON arrives on the hook's stdin.
///   post_tool — runs after a tool executed (formatters, notifications);
///               best-effort, exit code ignored.
///   turn_end  — runs after each root turn completes; best-effort.
///
/// Shape: {"hooks": {"pre_tool": [{"match": "bash|edit_file",
/// "command": "./guard.sh", "timeout_ms": 10000}], ...}}. `match` is "*"
/// (default) or pipe-separated tool names. A hung hook is killed at its
/// timeout and treated as allow — hooks must never brick the loop.
const Hook = struct {
    match: []const u8,
    command: []const u8,
    timeout_ms: u64,

    fn matches(self: Hook, tool: []const u8) bool {
        if (std.mem.eql(u8, self.match, "*")) return true;
        var it = std.mem.splitScalar(u8, self.match, '|');
        while (it.next()) |m| {
            if (std.mem.eql(u8, std.mem.trim(u8, m, " "), tool)) return true;
        }
        return false;
    }
};

const Hooks = struct {
    pre_tool: []const Hook = &.{},
    post_tool: []const Hook = &.{},
    turn_end: []const Hook = &.{},

    fn total(self: Hooks) usize {
        return self.pre_tool.len + self.post_tool.len + self.turn_end.len;
    }
};

var g_hooks: Hooks = .{};

fn parseHookList(arena: Allocator, v: ?Value) []const Hook {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var list: std.ArrayList(Hook) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const cmd = item.object.get("command") orelse continue;
        if (cmd != .string or cmd.string.len == 0) continue;
        const match: []const u8 = if (item.object.get("match")) |m|
            (if (m == .string and m.string.len > 0) m.string else "*")
        else
            "*";
        const timeout: u64 = if (item.object.get("timeout_ms")) |t|
            (if (t == .integer and t.integer > 0) @intCast(t.integer) else 10_000)
        else
            10_000;
        list.append(arena, .{ .match = match, .command = cmd.string, .timeout_ms = timeout }) catch continue;
    }
    return list.items;
}

/// Parse the "hooks" section of .harness/settings.json (arena-owned slices;
/// call once at startup with the session arena).
fn loadHooks(io: Io, arena: Allocator) Hooks {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return .{};
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return .{};
    if (v != .object) return .{};
    const hooks = v.object.get("hooks") orelse return .{};
    if (hooks != .object) return .{};
    return .{
        .pre_tool = parseHookList(arena, hooks.object.get("pre_tool")),
        .post_tool = parseHookList(arena, hooks.object.get("post_tool")),
        .turn_end = parseHookList(arena, hooks.object.get("turn_end")),
    };
}

const HookRun = struct { code: ?u8, stderr: []u8 };

/// Run one hook command: /bin/sh -c, event JSON on stdin, stderr captured
/// (capped), killed at its timeout. Returns the exit code (null on timeout
/// or spawn failure) and the trimmed stderr (gpa-owned).
fn runHookCmd(gpa: Allocator, io: Io, command: []const u8, payload: []const u8, timeout_ms: u64) HookRun {
    const none: HookRun = .{ .code = null, .stderr = &.{} };
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch return none;
    {
        var wbuf: [4096]u8 = undefined;
        var w = child.stdin.?.writerStreaming(io, &wbuf);
        w.interface.writeAll(payload) catch {};
        w.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var rbuf: [16 * 1024]u8 = undefined;
    var r = child.stderr.?.readerStreaming(io, &rbuf);
    var err_text: std.ArrayList(u8) = .empty;
    defer err_text.deinit(gpa);
    const t0: Io.Timestamp = .now(io, .awake);
    var timed_out = false;
    while (true) {
        // Bounded read pump: stderr is tiny in practice; the deadline is the
        // real guard. takeDelimiter would block, so poll the fd instead.
        if (t0.untilNow(io, .awake).toMilliseconds() >= timeout_ms) {
            timed_out = true;
            child.kill(io);
            break;
        }
        if (r.interface.buffered().len == 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;
            if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0 and fds[0].revents & std.posix.POLL.IN == 0) break;
        }
        const b = r.interface.takeByte() catch break; // EOF: hook exited
        if (err_text.items.len < 4096) err_text.append(gpa, b) catch break;
    }
    const code: ?u8 = if (timed_out) null else switch (child.wait(io) catch return none) {
        .exited => |c| c,
        else => null,
    };
    const trimmed = std.mem.trim(u8, err_text.items, " \t\r\n");
    return .{ .code = code, .stderr = gpa.dupe(u8, trimmed) catch &.{} };
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
        .desc = "code-intelligence suite — muonry edits, zigrep search, codedb index; edit_file upgrades to atomic zigpatch splices",
        .bins = &.{ "zigpatch", "muonry" },
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
const McpNote = struct { server: []const u8, note: []const u8 };
const mcp_notes = [_]McpNote{
    .{
        .server = "muonry",
        .note = "The muonry MCP server is connected (mcp__muonry__* tools). SEARCH ORDER: the native codedb tool is free and indexed — always try it first for code search (search/symbol/callers/outline/find); use mcp__muonry__search or faster_search only when codedb can't answer (raw literal/regex content matches, non-code or non-indexed files) — muonry is metered. Prefer mcp__muonry__read (mode=outline first, then symbol) over read_file for navigating large code files, and mcp__muonry__batch to run several independent reads/searches in one round-trip. Keep edits on the native edit_file/write_file tools (they are snapshot-tracked for /rewind). These tools are accelerators, not requirements: whenever an mcp__muonry__ call fails or is unavailable, fall back to read_file/codedb/bash and continue.",
    },
};

/// Read-only tool names on the trusted muonry server, mirroring the
/// server's own readOnlyHint annotations.
const muonry_readonly_tools = [_][]const u8{ "read", "search", "faster_search", "meta_search", "diff", "lint" };

fn muonryToolReadOnly(t: []const u8) bool {
    for (muonry_readonly_tools) |ok| if (std.mem.eql(u8, t, ok)) return true;
    return false;
}

/// Every mcp__muonry__* call skips the approval gate — the suite (muonry,
/// zigpatch, zigrep, codedb) is a user-installed trusted companion, same
/// standing as the native read_file/edit_file tools, which never prompt.
fn muonryTrusted(tool: []const u8) bool {
    return std.mem.startsWith(u8, tool, "mcp__muonry__");
}

/// Is this muonry call read-only? Decides what muonry may do in PLAN MODE
/// (read-only by mode semantics — native edit_file is blocked there too,
/// trust notwithstanding). Mirrors the server's readOnlyHint annotations;
/// batch is read-only iff every op inside it is.
fn muonryReadOnly(tool: []const u8, input: Value) bool {
    const prefix = "mcp__muonry__";
    if (!std.mem.startsWith(u8, tool, prefix)) return false;
    const t = tool[prefix.len..];
    if (muonryToolReadOnly(t)) return true;
    if (!std.mem.eql(u8, t, "batch")) return false;
    if (input != .object) return false;
    const ops = input.object.get("ops") orelse return false;
    if (ops != .array or ops.array.items.len == 0) return false;
    for (ops.array.items) |op| {
        if (op != .object) return false;
        const name = op.object.get("tool") orelse return false;
        if (name != .string or !muonryToolReadOnly(name.string)) return false;
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

fn skillIndex(name: []const u8) ?usize {
    for (skills_registry, 0..) |sk, i| if (std.mem.eql(u8, sk.name, name)) return i;
    return null;
}

fn skillDisabled(name: []const u8) bool {
    const i = skillIndex(name) orelse return false;
    return g_skill_disabled[i];
}

/// Installed AND not user-disabled — the only check callers should use.
fn skillActive(io: Io, sk: SkillDef) bool {
    return !skillDisabled(sk.name) and skillInstalled(io, sk);
}

/// Parse the "skills" section of .harness/settings.json into
/// g_skill_disabled (call once at startup): {"skills": {"<name>": false}}
/// disables; anything else leaves the skill enabled.
fn loadSkillSettings(io: Io, arena: Allocator) void {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const skills = v.object.get("skills") orelse return;
    if (skills != .object) return;
    for (skills_registry, 0..) |sk, i| {
        const entry = skills.object.get(sk.name) orelse continue;
        if (entry == .bool and !entry.bool) g_skill_disabled[i] = true;
    }
}

// ── thinking animations ──────────────────────────────────────────────────
// Named single-line indicators for the model-wait spinner, ported in spirit
// from arpagon/pi-animations (MIT). Plain Unicode + ANSI 256-color only (no
// Nerd Fonts), each frame ≤ ~30 columns. Selected via /animation, persisted
// as {"animation": "<name>"} in .harness/settings.json.

const Anim = struct {
    name: []const u8,
    desc: []const u8,
    frame: *const fn (w: *Io.Writer, i: usize) Io.Writer.Error!void,
};

const anims = [_]Anim{
    .{ .name = "braille", .desc = "classic braille spinner (default)", .frame = animBraille },
    .{ .name = "pulse", .desc = "pulsing star", .frame = animPulse },
    .{ .name = "orbit-dots", .desc = "dot orbiting a ring", .frame = animOrbit },
    .{ .name = "block-wave", .desc = "unicode block wave", .frame = animBlockWave },
    .{ .name = "shimmer", .desc = "highlight sweeping the word", .frame = animShimmer },
    .{ .name = "matrix", .desc = "matrix rain strip", .frame = animMatrix },
    .{ .name = "pacman", .desc = "pac-man eating dots", .frame = animPacman },
    .{ .name = "starfield", .desc = "parallax stars", .frame = animStarfield },
};

var g_anim_index: usize = 0; // /animation selection (index into anims)
var g_anim_random = false; // pick a fresh one per request
var g_anim_off = false; // /animation off
var g_anim_current: usize = 0; // what spinnerTask draws right now

fn animIndex(name: []const u8) ?usize {
    for (anims, 0..) |a, i| if (std.mem.eql(u8, a.name, name)) return i;
    return null;
}

fn animThinking(w: *Io.Writer) Io.Writer.Error!void {
    try w.print(" {s}thinking…{s}", .{ style.dim, style.reset });
}

fn animBraille(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    try w.print("{s}{s} thinking…{s}", .{ style.dim, frames[i % frames.len], style.reset });
}

fn animPulse(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const glyphs = [_][]const u8{ "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" };
    const g = glyphs[i % glyphs.len];
    const bright = (i % glyphs.len) >= 3 and (i % glyphs.len) <= 6;
    try w.print("{s}{s}{s}", .{ if (bright) style.cyan else style.dim, g, style.reset });
    try animThinking(w);
}

fn animOrbit(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const slots = 6;
    const pos = i % slots;
    var j: usize = 0;
    while (j < slots) : (j += 1) {
        if (j == pos) {
            try w.print("{s}●{s}", .{ style.cyan, style.reset });
        } else {
            try w.print("{s}·{s}", .{ style.dim, style.reset });
        }
        if (j + 1 < slots) try w.writeAll(" ");
    }
    try animThinking(w);
}

fn animBlockWave(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const lvls = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    try w.writeAll(style.cyan);
    var j: usize = 0;
    while (j < 10) : (j += 1) {
        const tri = @abs(@as(i64, @intCast((i + j) % 14)) - 7); // 0..7 triangle wave
        try w.writeAll(lvls[@intCast(7 - tri)]);
    }
    try w.writeAll(style.reset);
    try animThinking(w);
}

fn animShimmer(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const chs = [_][]const u8{ "t", "h", "i", "n", "k", "i", "n", "g", "…" };
    const pos = i % (chs.len + 4); // a little off-screen pause each sweep
    for (chs, 0..) |c, j| {
        if (j == pos) {
            try w.print("{s}{s}{s}{s}", .{ style.bold, style.cyan, c, style.reset });
        } else {
            try w.print("{s}{s}{s}", .{ style.dim, c, style.reset });
        }
    }
}

fn animMatrix(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const glyphs = [_][]const u8{ "ｱ", "ｼ", "ﾂ", "ｴ", "ｵ", "ｶ", "ｷ", "ﾒ", "ｹ", "ｺ", "ﾅ", "ﾈ", "ｽ", "ﾎ", "ﾜ", "ﾀ" };
    var j: usize = 0;
    while (j < 8) : (j += 1) {
        const g = glyphs[(i / 2 +% j *% 7 +% j * j) % glyphs.len];
        const head = (i + j) % 5 == 0;
        try w.print("{s}{s}{s}", .{ if (head) style.green else style.dim, g, style.reset });
    }
    try animThinking(w);
}

fn animPacman(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const track = 10;
    const pos = (i / 2) % (track + 2); // 2 spare ticks off the right edge
    var j: usize = 0;
    while (j < track) : (j += 1) {
        if (j < pos) {
            try w.writeAll("  ");
        } else if (j == pos) {
            try w.print("{s}{s}{s} ", .{ style.yellow, if (i % 2 == 0) "ᗧ" else "○", style.reset });
        } else {
            try w.print("{s}·{s} ", .{ style.dim, style.reset });
        }
    }
    try animThinking(w);
}

fn animStarfield(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    var j: usize = 0;
    while (j < 14) : (j += 1) {
        if ((j + i) % 7 == 0) {
            try w.print("{s}✦{s}", .{ style.cyan, style.reset });
        } else if ((j + i * 2) % 11 == 0) {
            try w.print("{s}·{s}", .{ style.dim, style.reset });
        } else {
            try w.writeAll(" ");
        }
    }
    try animThinking(w);
}

/// Load {"animation": "<name>|random|off"} from settings at startup.
fn loadAnimationSetting(io: Io, arena: Allocator) void {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const a = v.object.get("animation") orelse return;
    if (a != .string) return;
    if (std.mem.eql(u8, a.string, "off")) {
        g_anim_off = true;
    } else if (std.mem.eql(u8, a.string, "random")) {
        g_anim_random = true;
    } else if (animIndex(a.string)) |i| {
        g_anim_index = i;
    }
}

/// Persist the /animation choice, preserving every other settings key.
/// The default ("braille") removes the key. Best-effort.
fn saveAnimationSetting(io: Io, gpa: Allocator, value: []const u8) bool {
    Io.Dir.cwd().createDir(io, Approvals.settings_dir, .default_dir) catch {};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (std.mem.eql(u8, value, anims[0].name)) {
        _ = root_obj.orderedRemove("animation");
    } else {
        root_obj.put(a, "animation", .{ .string = value }) catch return false;
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

/// Terminal column count (TIOCGWINSZ); 80 on any failure.
fn termCols() usize {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0 or ws.col == 0) return 80;
    return ws.col;
}

fn inputPending(fd: std.posix.fd_t) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, 50) catch return false;
    return n > 0;
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
fn isImagePath(name: []const u8) bool {
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
    const run = runCapped(gpa, io, &.{ "codedb", "glob", "**/*" }, bash_stdout_cap, 4096) catch return false;
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
    const fd = std.posix.STDIN_FILENO;
    const orig = std.posix.tcgetattr(fd) catch return in.takeDelimiter('\n');
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false; // so Ctrl-V (0x16) reaches us instead of the tty's lnext "quote next char"
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(fd, .NOW, raw) catch return in.takeDelimiter('\n');
    defer std.posix.tcsetattr(fd, .NOW, orig) catch {};

    buf.clearRetainingCapacity();
    var cur: usize = 0; // cursor index within buf
    var hist_idx: usize = history.items.len; // == len → editing a fresh line
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
            if (in.buffered().len == 0 and !inputPending(fd)) { // 50ms poll
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
                        o.writeAll("\x1b[7;36m") catch {};
                        mark_end = i + best;
                        mark_open = true;
                    }
                }
                o.writeByte(items[i]) catch {};
                vcol += 1;
                i += 1;
                if (mark_open and i == mark_end) {
                    o.writeAll("\x1b[0m") catch {};
                    mark_open = false;
                }
            }
            if (mark_open) o.writeAll("\x1b[0m") catch {};

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
        } else in.takeByte() catch return null;
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
                if (in.buffered().len == 0 and !inputPending(fd)) {
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
                    'A' => if (hist_idx > 0) { // up → history back
                        hist_idx -= 1;
                        setLine(gpa, buf, history.items[hist_idx]);
                        cur = buf.items.len;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'B' => if (hist_idx < history.items.len) { // down → history forward
                        hist_idx += 1;
                        if (hist_idx == history.items.len) buf.clearRetainingCapacity() else setLine(gpa, buf, history.items[hist_idx]);
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

const history_file = ".simple-harness-history";
const model_file = ".simple-harness-model"; // remembers the last-selected provider+model

/// Persist the active provider+model so the next launch starts on it.
fn saveModel(io: Io, home: []const u8, pid: []const u8, model: []const u8) void {
    if (home.len == 0) return;
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ home, model_file }) catch return;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    var wbuf: [256]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.print("{s}\n{s}\n", .{ pid, model }) catch return;
    fw.interface.flush() catch return;
}

/// Load the remembered provider+model (pid on line 1, model on line 2).
fn loadModel(io: Io, arena: Allocator, home: []const u8) ?struct { pid: []const u8, model: []const u8 } {
    if (home.len == 0) return null;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, model_file }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;
    var it = std.mem.splitScalar(u8, data, '\n');
    const pid = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    const model = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    if (pid.len == 0 or model.len == 0) return null;
    return .{ .pid = pid, .model = model };
}
const history_cap = 1000; // keep the most recent N input lines

/// Load persisted ↑/↓ input history from ~/.simple-harness-history into the
/// in-memory list (gpa-owned entries; freed with the list at exit). Capped to
/// the last `history_cap` lines.
fn loadHistory(io: Io, gpa: Allocator, home: []const u8, history: *std.ArrayList([]const u8)) void {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, history_file }) catch return;
    defer gpa.free(path);
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const l = std.mem.trim(u8, ln, " \t\r");
        if (l.len == 0) continue;
        const dup = gpa.dupe(u8, l) catch continue;
        history.append(gpa, dup) catch gpa.free(dup);
    }
    if (history.items.len > history_cap) {
        const drop = history.items.len - history_cap;
        for (history.items[0..drop]) |h| gpa.free(h);
        std.mem.copyForwards([]const u8, history.items[0..], history.items[drop..]);
        history.shrinkRetainingCapacity(history_cap);
    }
}

/// Write the (last `history_cap`) input lines back to ~/.simple-harness-history.
fn saveHistory(io: Io, arena: Allocator, home: []const u8, history: []const []const u8) void {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, history_file }) catch return;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    var wbuf: [8 * 1024]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    const start = if (history.len > history_cap) history.len - history_cap else 0;
    for (history[start..]) |h| {
        fw.interface.writeAll(h) catch return;
        fw.interface.writeByte('\n') catch return;
    }
    fw.interface.flush() catch return;
}

/// Serialize the Anthropic `messages` array. When `cache` is set and the final
/// message is a plain-string user turn (the common case at request time, and
/// the largest re-sent prefix), wrap it as a text block with a cache_control
/// ephemeral breakpoint — so the whole conversation prefix is cached, not just
/// the system block. Combined with the system breakpoint that's ≤2 of
/// Anthropic's 4 allowed. Other messages are written verbatim.
fn writeAnthropicMessages(s: *std.json.Stringify, messages: std.json.Array, cache: bool) !void {
    const items = messages.items;
    try s.beginArray();
    for (items, 0..) |m, i| {
        const cache_this = cache and i + 1 == items.len and m == .object and
            (if (m.object.get("content")) |c| c == .string else false);
        if (!cache_this) {
            try s.write(m);
            continue;
        }
        try s.beginObject();
        var it = m.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "content")) continue;
            try s.objectField(kv.key_ptr.*);
            try s.write(kv.value_ptr.*);
        }
        try s.objectField("content");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("type");
        try s.write("text");
        try s.objectField("text");
        try s.write(m.object.get("content").?.string);
        try s.objectField("cache_control");
        try s.print("{s}", .{"{\"type\":\"ephemeral\"}"});
        try s.endObject();
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
}

const harness_version: []const u8 = @import("build_options").version;

/// OTLP endpoint baked into release builds (-Dtelemetry-endpoint); "" in dev
/// builds → telemetry stays off unless an env var configures it. Used as the
/// lowest-precedence telemetry endpoint, below env overrides and opt-out.
const default_telemetry_endpoint: []const u8 = @import("build_options").telemetry_endpoint;

const usage_text =
    \\simple-harness — a minimal agentic coding harness in Zig (zero deps)
    \\
    \\usage:
    \\  graff [flags]                    start the REPL
    \\  graff [-p] "prompt"              one-shot: run the prompt, print the answer, exit
    \\  graff login                      get a codegraff key (device-code OAuth)
    \\  graff login codex [--refresh]    ChatGPT/Codex OAuth login (PKCE)
    \\  graff key set <provider> <key>   store a key (macOS Keychain, else 0600 file)
    \\  graff key list                   show which providers have keys
    \\  graff --schema                   print the machine-readable interface (SDK codegen)
    \\  graff serve                      HTTP/NDJSON bridge over the --json protocol
    \\                                   (--host/--port/--token; sessions are --json children)
    \\
    \\flags:
    \\  --model <name>   start on this model (same fuzzy resolution as /model)
    \\  --system-prompt <text>          replace the built-in system prompt
    \\  --append-system-prompt <text>   append extra text to the system prompt
    \\  --yolo           skip all permission prompts for the session
    \\  -p, --print      one-shot print mode (answer on stdout, progress on stderr)
    \\  --timing         show per-tool wall-clock on result lines
    \\  --cost           show running session spend in the prompt
    \\  --json           structured stdio protocol (JSON in, JSONL events out)
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // CLI flags. --yolo starts with the permission gate fully open (same as
    // typing /yolo once you're in) — skips every bash/tool/MCP approval prompt.
    var yolo_flag = false;
    var no_telemetry_flag = false;
    var schema_flag = false;
    var login_flag = false;
    var refresh_flag = false;
    var codex_login = false;
    var help_flag = false;
    var version_flag = false;
    var print_flag = false;
    var model_flag: ?[]const u8 = null;
    var system_prompt_flag: ?[]const u8 = null;
    var append_system_flag: ?[]const u8 = null;
    var host_flag: []const u8 = "127.0.0.1"; // harness serve
    var port_flag: u16 = 8787; // harness serve
    var token_flag: ?[]const u8 = null; // harness serve
    var positionals: std.ArrayList([]const u8) = .empty;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
        defer it.deinit();
        _ = it.next(); // argv[0]
        while (it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "--yolo")) {
                    yolo_flag = true;
                } else if (std.mem.eql(u8, arg, "--no-telemetry")) {
                    no_telemetry_flag = true;
                } else if (std.mem.eql(u8, arg, "--timing")) {
                    show_timing = true;
                } else if (std.mem.eql(u8, arg, "--cost")) {
                    show_cost = true;
                } else if (std.mem.eql(u8, arg, "--json")) {
                    json_mode = true;
                } else if (std.mem.eql(u8, arg, "--schema")) {
                    schema_flag = true;
                } else if (std.mem.eql(u8, arg, "--refresh")) {
                    refresh_flag = true;
                } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    help_flag = true;
                } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                    version_flag = true;
                } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
                    print_flag = true;
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
    }

    // One-shot print mode: `harness -p "prompt"` or a bare positional prompt
    // (`harness "say hi"`). Subcommands (login/key) are not prompts.
    const is_subcommand = positionals.items.len > 0 and
        (std.mem.eql(u8, positionals.items[0], "login") or std.mem.eql(u8, positionals.items[0], "key") or
            std.mem.eql(u8, positionals.items[0], "serve"));
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
        if (help_flag) try hw.interface.writeAll(usage_text) else try hw.interface.print("simple-harness {s}\n", .{harness_version});
        try hw.interface.flush();
        return;
    }

    // `harness key set <provider> <key>` / `harness key list`: safe key store
    // (macOS Keychain, else a 0600 file). Exits after.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "key")) {
        const home = init.environ_map.get("HOME") orelse std.process.fatal("no HOME", .{});
        try keyCommand(io, gpa, arena, home, positionals.items[1..]);
        return;
    }

    // `harness login [codex] [--refresh]`: OAuth login. Default target is
    // codegraff (device-code flow, writes ~/.simple-harness-codegraff.json);
    // `codex` (or --refresh) runs the ChatGPT PKCE/refresh flow → ~/.codex/auth.json.
    if (login_flag) {
        const home = init.environ_map.get("HOME") orelse std.process.fatal("no HOME", .{});
        if (codex_login or refresh_flag) try codexLogin(io, gpa, arena, home, refresh_flag) else try codegraffLogin(io, gpa, arena, home);
        return;
    }

    // `harness serve`: HTTP/NDJSON bridge over the --json protocol — each
    // session is a `harness --json` child of this same binary. Keys are
    // loaded by the children, not here.
    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "serve")) {
        const token = token_flag orelse init.environ_map.get("HARNESS_SERVE_TOKEN") orelse init.environ_map.get("GRAFF_SERVE_TOKEN");
        const exe = std.process.executablePathAlloc(io, arena) catch
            std.process.fatal("serve: cannot resolve own executable path", .{});
        try serveMain(gpa, io, .{
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
    if (init.environ_map.get("HOME")) |home| {
        for (provider_specs, &keys.values) |spec, *value| {
            if (std.mem.eql(u8, spec.id, "codegraff") and value.* == null)
                value.* = loadCodegraffKey(io, arena, home);
        }
    }
    // Codex "login": read the ChatGPT OAuth token from ~/.codex/auth.json
    // (written by the Codex CLI) instead of an env var — same on-disk
    // credential pattern as the codegraff key in ~/forge/.credentials.json.
    var codex_account: ?[]const u8 = null;
    if (init.environ_map.get("HOME")) |home| {
        if (loadCodexAuth(io, arena, home)) |auth| {
            for (provider_specs, &keys.values) |spec, *value| {
                if (std.mem.eql(u8, spec.id, "codex")) value.* = auth.token;
            }
            keys.codex_account = auth.account;
            codex_account = auth.account;
        }
    }
    // Stored keys (macOS Keychain / 0600 file via `harness key set`): fill any
    // provider slot still empty after env + the login loaders. env always wins.
    if (init.environ_map.get("HOME")) |home| {
        for (provider_specs, &keys.values) |spec, *value| {
            if (value.* == null) value.* = loadStoredKey(io, arena, home, spec.id);
        }
    }
    var default_provider = keys.defaultProvider() catch {
        std.process.fatal(
            \\no API key found. quickest fixes:
            \\  graff login                         free codegraff key (device-code OAuth)
            \\  graff key set <provider> <key>      store a key (macOS Keychain, else 0600 file)
            \\  export ANTHROPIC_API_KEY=sk-ant-…   or CODEGRAFF/DEEPSEEK/OPENAI/MINIMAX/XIAOMI/KIMI/XAI/ZAI _API_KEY
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
    } else if (loadModel(io, arena, init.environ_map.get("HOME") orelse "")) |saved| {
        // No --model flag: resume the model chosen last session — but only if
        // it's still in the model table; a typo'd /model would otherwise
        // poison every later launch with a name no API serves.
        if (modelInTable(saved.model)) {
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

    // Color only on an interactive terminal, and honor NO_COLOR.
    if (init.environ_map.get("NO_COLOR") == null and (Io.File.stdout().isTty(io) catch false)) {
        style = Style.ansi;
        use_color = true;
    }

    if (!json_mode and oneshot_prompt == null) {
        try out.print("{s}simple-harness{s} · / for commands · @ picks a file · esc interrupts · ↑/↓ history · tab completes · ctrl-d quits · trace → {s}\n", .{ style.bold, style.reset, trace_path });
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
    g_traj = &traj;
    defer {
        g_traj = null;
        traj.deinit();
    }
    traj.node(.{ .kind = "session", .version = harness_version, .unix_ms = unixMs(io) });

    // Score-channel signing (Step 0): a per-session run_id and, if
    // GRAFF_SCORE_KEY_FILE is set, the HMAC key — so score records written
    // this session are signed and forged trajectory rows are detectable.
    {
        var raw: [8]u8 = undefined;
        io.random(&raw);
        g_run_id = std.fmt.bytesToHex(raw, .lower);
    }
    g_score_key = loadScoreKey(io, arena, init.environ_map);

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
    const telem_home = init.environ_map.get("HOME") orelse "";
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
    g_telem = &telem;
    defer {
        g_telem = null;
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
        if (g_telem) |t| t.errorEvent("mcp", @errorName(err));
        break :inner null;
    }) orelse mcp.Registry.empty(gpa, io)) else outer: {
        if (mcp_count > 0) try out.print("{s}skipped {d} workspace MCP server(s) — re-run with --yolo to trust this workspace{s}\n", .{ style.dim, mcp_count, style.reset });
        break :outer mcp.Registry.empty(gpa, io);
    };
    defer registry_storage.deinit();
    const registry: ?*mcp.Registry = &registry_storage;
    // muonry auto-activation: if the muonry binary is installed but nothing
    // connected it (no workspace .mcp.json entry, or consent declined for the
    // workspace's servers), spawn it directly — it's a user-installed
    // companion (the fast code-intelligence suite), the same trust level as
    // the skills auto-detection above it, NOT arbitrary workspace config.
    // Failure just means native tools: the mcp_notes usage line below only
    // enters the context when the connect actually succeeded. Opt out the
    // same way as a skill: {"skills": {"muonry": false}} in settings.
    g_path_env = try arena.dupe(u8, init.environ_map.get("PATH") orelse "");
    loadSkillSettings(io, arena); // per-skill opt-outs, also gates the auto-connect
    loadAnimationSetting(io, arena); // {"animation": "..."} → thinking spinner choice
    if (!mcpServerConnected(registry_storage.tools, "muonry") and
        !skillDisabled("muonry") and binOnPath(io, "muonry"))
    {
        _ = registry_storage.addServer("muonry", "muonry", &.{"--mcp"}) catch |err| {
            if (!json_mode and oneshot_prompt == null) {
                try out.print("{s}[mcp:muonry] auto-connect failed ({t}) — native tools only{s}\n", .{ style.dim, err, style.reset });
                try out.flush();
            }
        };
    }
    const mcp_tools: []const mcp.Tool = registry_storage.tools;

    var approvals: Approvals = .{ .yolo = yolo_flag };
    defer {
        for (approvals.prefixes.items) |p| gpa.free(p);
        approvals.prefixes.deinit(gpa);
    }
    const persisted_approvals = approvals.loadPersisted(io, gpa, arena);

    // Agent types: builtins + .harness/agents/*.md (the MAP-Elites niches).
    g_agent_types = loadAgentTypes(io, arena);
    if (persisted_approvals > 0 and !json_mode and oneshot_prompt == null) {
        try out.print("{s}loaded {d} saved approval(s) from {s}{s}\n", .{ style.dim, persisted_approvals, Approvals.settings_path, style.reset });
        try out.flush();
    }
    // Lifecycle hooks (pre_tool/post_tool/turn_end) from the same file.
    // (Per-skill opt-outs were loaded earlier, before the muonry auto-connect.)
    g_hooks = loadHooks(io, arena);
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
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, mn.note });
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
        .home = init.environ_map.get("HOME") orelse "",
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
    tracer.note("session", root.provider.model);

    // One-shot print mode: run the single prompt to completion, print the
    // final text to stdout, exit. Tool progress goes to stderr (say() with no
    // out writer), streaming stays quiet, and the gate denies anything not
    // pre-approved instead of prompting (there's no one to ask).
    if (oneshot_prompt) |prompt_text| {
        unattended = true;
        root.in = null; // gate: deny instead of prompt; ask_user: self-decide
        root.out = null; // tool progress → stderr; stdout carries only the answer
        root.stream_quiet = true;
        try root.messages.append(try textMessage(arena, "user", prompt_text));
        if (g_telem) |t| t.countTurn();
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
        return;
    }

    // Input-line history (persisted to ~/.simple-harness-history) + editor buffer.
    var history: std.ArrayList([]const u8) = .empty;
    var linebuf: std.ArrayList(u8) = .empty;
    if (init.environ_map.get("HOME")) |home| loadHistory(io, gpa, home, &history);
    defer {
        if (init.environ_map.get("HOME")) |home| saveHistory(io, arena, home, history.items);
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

    while (true) {
        try root.prompt();
        const raw_line = if (interactive)
            (try readLine(&root, in, out, gpa, &history, &linebuf)) orelse break
        else
            (try in.takeDelimiter('\n')) orelse break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!json_mode) {
            const l = if (line.len > 0 and line[0] == '/') line[1..] else line;
            if (std.mem.eql(u8, l, "exit") or std.mem.eql(u8, l, "quit") or std.mem.eql(u8, l, "q")) break;
        }

        if (!json_mode and line[0] == '/') {
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
        const base_msg: []const u8 = if (json_mode) blk: {
            const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{ .allocate = .alloc_always }) catch {
                root.emit(.{ .type = "error", .message = "invalid JSON (expect {\"type\":\"user\",\"text\":\"...\"})" });
                continue;
            };
            const rtype = if (parsed == .object)
                (if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "")
            else
                "";
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
                const eval_set_hash = utf8Prefix(reqStr.s(parsed.object, "eval_set_hash"), 64);
                const req_run = reqStr.s(parsed.object, "run_id");
                const run_id: []const u8 = if (req_run.len > 0) utf8Prefix(req_run, 64) else &g_run_id;
                const sig = signScore(sha, parent, sc, run_id, judge_id, artifact_sha, eval_set_hash);
                const signed = g_score_key != null;
                if (g_traj) |tj| tj.node(.{
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
                var provbuf: [256]u8 = undefined;
                const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}", .{ judge_id, artifact_sha, eval_set_hash }) catch "";
                if (g_telem) |t| t.scoreEvent(sha, parent, sc, run_id, if (signed) @as([]const u8, &sig) else "", prov);
                root.emit(.{ .type = "score", .ok = true, .prompt_sha = sha, .signed = signed });
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
            break :blk text;
        } else line;

        // Plan mode: steer the model to explore read-only and present a plan
        // (the gate enforces the read-only part regardless).
        const msg: []const u8 = if (!plan_mode) base_msg else try std.fmt.allocPrint(arena,
            \\{s}
            \\
            \\[harness note: plan mode is ON — read-only. Explore with read-only
            \\tools as needed, then present a concrete plan (files to change,
            \\the changes themselves, sequence, risks) and ask the user to
            \\approve it. Do not write files or run mutating commands — the
            \\gate will deny them. The user toggles execution back on with /plan.]
        , .{base_msg});

        // "ultracode" codeword: opt this turn into multi-agent workflow mode.
        if (std.ascii.indexOfIgnoreCase(msg, "ultracode") != null) {
            if (!json_mode) {
                try out.writeAll("⚡ ultracode — multi-agent workflow mode engaged\n");
                try out.flush();
            }
            tracer.note("ultracode", msg[0..@min(msg.len, 120)]);
            if (g_telem) |t| t.ultracode();
            const augmented = try std.fmt.allocPrint(arena,
                \\{s}
                \\
                \\[harness note: the user invoked the "ultracode" codeword, opting
                \\this turn into multi-agent orchestration. Fulfill the request with
                \\the workflow tool: decompose it into sequential phases of parallel
                \\subagents — fan out for coverage first, then a synthesis phase.
                \\Tell code-exploration subagents to go through the repo with the
                \\codedb tool (search / symbol / callers / outline / context) before
                \\reaching for bash grep — it is indexed and structural.
                \\Use the workflow even if you could do the work solo; skip it only
                \\if the message needs a purely conversational reply.]
            , .{msg});
            if (root.pending_image) |img| {
                try root.messages.append(try imageMessage(arena, root.provider.kind, augmented, img));
                root.pending_image = null;
            } else try root.messages.append(try textMessage(arena, "user", augmented));
        } else {
            if (root.pending_image) |img| {
                try root.messages.append(try imageMessage(arena, root.provider.kind, msg, img));
                root.pending_image = null;
            } else try root.messages.append(try textMessage(arena, "user", msg));
        }
        snaps.turn += 1; // tag file edits in this turn (matches /rewind numbering)
        if (g_telem) |t| t.countTurn();
        // Trajectory: claim this turn's node id up front so subagents spawned
        // during the turn can attach to it as their parent.
        const turn_id: u64 = if (g_traj) |tj| blk: {
            const id = tj.nextId();
            tj.setTurn(id);
            break :blk id;
        } else 0;
        root.tools_used.clear(io); // per-turn tool log for the turn's node
        const turn_started = Io.Timestamp.now(io, .awake);
        // A failed turn must never kill the session: ApiError is already
        // reported inside request(); anything else is surfaced here. Either
        // way we drop back to the prompt (or emit a JSON error/turn event).
        const turn_result = root.runTurn();
        if (g_traj) |tj| {
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
            if (g_telem) |t| t.runEvent(&fp, !std.mem.eql(u8, &fp, &prev_prompt_fp), turn_ok, turn_ms, turn_tools);
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
                try out.print("{s}✗ interrupted (esc){s}\n", .{ style.yellow, style.reset });
                try out.flush();
                continue;
            },
            error.ApiError => {
                if (g_telem) |t| t.errorEvent("api", root.last_api_error orelse "api error");
                if (json_mode) root.emit(.{ .type = "error", .message = root.last_api_error orelse "api error" });
                continue;
            },
            else => |e| {
                if (g_telem) |t| t.errorEvent("turn", @errorName(e));
                if (json_mode) {
                    root.emit(.{ .type = "error", .message = @errorName(e) });
                } else {
                    root.say("[turn aborted: {t}]\n", .{e}) catch {};
                }
                continue;
            },
        };
        if (json_mode) root.emit(.{ .type = "turn", .text = final_text, .context_tokens = root.last_context_tokens, .cost_usd = g_cost.snap(io).usd });

        // turn_end lifecycle hooks (best-effort; interrupted/errored turns
        // `continue` above and never reach here, so ok is always true).
        if (g_hooks.turn_end.len > 0) {
            for (g_hooks.turn_end) |h| {
                const res = runHookCmd(gpa, io, h.command, "{\"event\":\"turn_end\",\"ok\":true}", h.timeout_ms);
                if (res.stderr.len > 0) gpa.free(res.stderr);
            }
        }

        if (root.last_context_tokens >= root.provider.compactAt()) {
            root.compact() catch |err| switch (err) {
                error.ApiError => {},
                else => |e| root.say("[compaction skipped: {t}]\n", .{e}) catch {},
            };
        }
    }
    try out.writeAll("\n");
    try out.flush();
}

/// Is this .mcp.json entry one the harness would auto-connect anyway? A
/// muonry entry running the literal `muonry` binary with no args (or just
/// `--mcp`) carries the same trust as the PATH auto-activation — but ONLY
/// exactly that shape: a repo putting `{"muonry": {"command": "evil"}}` (or
/// extra args) in its config still hits the consent gate.
fn trustedMcpEntry(name: []const u8, cfg: Value) bool {
    if (!std.mem.eql(u8, name, "muonry") or cfg != .object) return false;
    const cmd = cfg.object.get("command") orelse return false;
    if (cmd != .string or !std.mem.eql(u8, cmd.string, "muonry")) return false;
    const args = cfg.object.get("args") orelse return true;
    if (args != .array) return false;
    if (args.array.items.len == 0) return true;
    if (args.array.items.len != 1) return false;
    const a0 = args.array.items[0];
    return a0 == .string and std.mem.eql(u8, a0.string, "--mcp");
}

/// Count the workspace .mcp.json servers that actually need consent at
/// startup (0 if none/missing; trusted muonry entries are exempt — see
/// trustedMcpEntry). Used to gate auto-spawning untrusted workspace servers.
fn countMcpServers(io: Io, arena: Allocator) usize {
    const data = Io.Dir.cwd().readFileAlloc(io, mcp_config_path, arena, .limited(1 << 20)) catch return 0;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return 0;
    if (v != .object) return 0;
    const servers = v.object.get("mcpServers") orelse return 0;
    if (servers != .object) return 0;
    var n: usize = 0;
    var it = servers.object.iterator();
    while (it.next()) |entry| {
        if (!trustedMcpEntry(entry.key_ptr.*, entry.value_ptr.*)) n += 1;
    }
    return n;
}

/// Best-effort write of a server entry into .mcp.json (so `/mcp add` survives
/// a restart). Merges into any existing config. Returns false on any error.
fn persistMcpServer(io: Io, arena: Allocator, name: []const u8, command: []const u8, args: []const []const u8) bool {
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, mcp_config_path, arena, .limited(1 << 20))) |text| {
        if (std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}

    var servers: std.json.ObjectMap = .empty;
    if (root_obj.get("mcpServers")) |m| if (m == .object) {
        servers = m.object;
    };
    var entry: std.json.ObjectMap = .empty;
    entry.put(arena, "command", .{ .string = command }) catch return false;
    var argv = std.json.Array.init(arena);
    for (args) |a| argv.append(.{ .string = a }) catch return false;
    entry.put(arena, "args", .{ .array = argv }) catch return false;
    servers.put(arena, name, .{ .object = entry }) catch return false;
    root_obj.put(arena, "mcpServers", .{ .object = servers }) catch return false;

    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(Value{ .object = root_obj }) catch return false;

    const f = Io.Dir.cwd().createFile(io, mcp_config_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Pull plain text out of a message's content (string, or the text blocks of a
/// content array — anthropic "text", openai "text", responses "input/output_text").
fn extractText(arena: Allocator, m: Value) []const u8 {
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

/// Switch the active provider/model. Within the same wire format
/// (provider.kind) the conversation is kept verbatim. Across formats
/// (OpenAI↔Anthropic↔Responses) the stored messages don't fit the new shape:
/// with keep_context on (default) the dialogue is translated to a text-only
/// history and carried over; off clears it.
fn switchProvider(root: *Agent, arena: Allocator, p: Provider, out: *Io.Writer) !void {
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
    root.provider = p;
    saveModel(root.io, root.home, p.id, p.model); // remember for next launch
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
    const fd = std.posix.STDIN_FILENO;
    const orig = std.posix.tcgetattr(fd) catch return null;
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(fd, .NOW, raw) catch return null;
    defer std.posix.tcsetattr(fd, .NOW, orig) catch {};
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
    const fd = std.posix.STDIN_FILENO;
    const orig = std.posix.tcgetattr(fd) catch return null;
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(fd, .NOW, raw) catch return null;
    defer std.posix.tcsetattr(fd, .NOW, orig) catch {};
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

/// The slash-command menu shown for a bare "/": every REPL command with a
/// one-line description, picked via listPicker. Returns the command to run.
const command_menu = [_]PickItem{
    .{ .name = "/model", .desc = "switch model/provider (picker)" },
    .{ .name = "/models", .desc = "list known models, context windows" },
    .{ .name = "/clear", .desc = "wipe the conversation, start fresh" },
    .{ .name = "/compact", .desc = "summarize history into a fresh context" },
    .{ .name = "/plan", .desc = "toggle plan mode (read-only, propose first)" },
    .{ .name = "/resume", .desc = "restore a saved session (picker)" },
    .{ .name = "/save", .desc = "save the conversation" },
    .{ .name = "/sessions", .desc = "list saved sessions" },
    .{ .name = "/rewind", .desc = "drop a past prompt & revert its file edits" },
    .{ .name = "/key", .desc = "API-key status / add one live" },
    .{ .name = "/yolo", .desc = "toggle permission prompts" },
    .{ .name = "/strict", .desc = "toggle every-message-is-a-tool mode" },
    .{ .name = "/keepcontext", .desc = "keep history across wire-format switches" },
    .{ .name = "/reasoning", .desc = "codex/gpt-5 reasoning depth" },
    .{ .name = "/image", .desc = "attach an image to the next message" },
    .{ .name = "/paste", .desc = "attach the clipboard image" },
    .{ .name = "/trace", .desc = "toggle the JSONL event trace" },
    .{ .name = "/trajectory", .desc = "show this session's agent tree (DGM-style)" },
    .{ .name = "/agents", .desc = "list agent types (builtins + .harness/agents)" },
    .{ .name = "/skills", .desc = "optional companion tools: list, /skills add|remove <name>" },
    .{ .name = "/hooks", .desc = "list lifecycle hooks (pre_tool/post_tool/turn_end)" },
    .{ .name = "/todo", .desc = "show the task list" },
    .{ .name = "/jobs", .desc = "list background bash jobs (bash run_in_background)" },
    .{ .name = "/cost", .desc = "session usage: api calls, tokens, USD total" },
    .{ .name = "/animation", .desc = "pick the thinking animation (braille, matrix, pacman…)" },
    .{ .name = "/mcp", .desc = "list/connect MCP servers" },
    .{ .name = "/help", .desc = "list all commands" },
};

fn handleCommand(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !void {
    if (std.mem.eql(u8, line, "/clear")) {
        root.messages = std.json.Array.init(arena);
        root.last_context_tokens = 0;
        root.last_cache_read = 0;
        root.todos.clearRetainingCapacity();
        try out.writeAll("context cleared — fresh conversation\n");
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/agents")) {
        try out.print("{s}agent types{s} — MAP-Elites niches: builtins + {s}/*.md (file shadows builtin); spawn via subagent agent:\"<name>\"\n", .{ style.bold, style.reset, agents_dir });
        for (g_agent_types) |t| {
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
            const current: []const u8 = if (g_anim_off) "off" else if (g_anim_random) "random" else anims[g_anim_index].name;
            try out.print("{s}thinking animations{s} (current: {s}{s}{s}) — /animation <name> picks one, persists to {s}\n", .{ style.bold, style.reset, style.cyan, current, style.reset, Approvals.settings_path });
            for (anims) |a| {
                try out.print("  {s}{s:<12}{s} {s}  preview: ", .{ style.cyan, a.name, style.reset, a.desc });
                try a.frame(out, 3);
                try out.writeAll("\n");
            }
            try out.print("  {s}{s:<12}{s} a different one each request\n  {s}{s:<12}{s} no animation\n", .{ style.cyan, "random", style.reset, style.cyan, "off", style.reset });
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "off")) {
            g_anim_off = true;
            g_anim_random = false;
        } else if (std.mem.eql(u8, arg, "random")) {
            g_anim_off = false;
            g_anim_random = true;
        } else if (animIndex(arg)) |i| {
            g_anim_off = false;
            g_anim_random = false;
            g_anim_index = i;
        } else {
            try out.print("unknown animation '{s}' — /animation lists them\n", .{arg});
            try out.flush();
            return;
        }
        const saved = saveAnimationSetting(root.io, root.gpa, arg);
        try out.print("{s}✓ thinking animation: {s}{s}", .{ style.green, arg, style.reset });
        if (!g_anim_off and !g_anim_random) {
            try out.writeAll("  ");
            try anims[g_anim_index].frame(out, 3);
        }
        try out.writeAll("\n");
        if (!saved) try out.print("{s}warning: could not persist to {s} — lasts only this session{s}\n", .{ style.yellow, Approvals.settings_path, style.reset });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/hooks")) {
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
                        try out.print("no key/login for {s} — add one with /key {s} <key>\n", .{ m.provider, m.provider });
                        try out.flush();
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
                    try out.print("no key/login for provider '{s}' — `graff key set {s} <key>` or set {s}\n", .{ pid, pid, spec.env_key });
                    try out.flush();
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
            const provider = keys.providerById(spec.id, spec.default_model) catch {
                try out.print("no key/login for provider '{s}' — `graff key set {s} <key>` or set {s}\n", .{ spec.id, spec.id, spec.env_key });
                try out.flush();
                return;
            };
            try switchProvider(root, arena, provider, out);
            return;
        }
        const resolved = resolveModelName(keys.*, arg);
        const name = try arena.dupe(u8, resolved orelse arg);
        const provider = keys.providerFor(name) catch {
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
        root.compact() catch |err| switch (err) {
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
                var snip = root.messages.items[idx].object.get("content").?.string;
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
    if (std.mem.startsWith(u8, line, "/reasoning")) {
        const arg = std.mem.trim(u8, line["/reasoning".len..], " \t");
        if (std.mem.eql(u8, arg, "low")) {
            root.reasoning = .low;
        } else if (std.mem.eql(u8, arg, "medium") or std.mem.eql(u8, arg, "med")) {
            root.reasoning = .medium;
        } else if (std.mem.eql(u8, arg, "high")) {
            root.reasoning = .high;
        } else if (arg.len != 0) {
            try out.writeAll("usage: /reasoning low|medium|high\n");
            try out.flush();
            return;
        }
        try out.print("reasoning effort: {s}{s}\n", .{
            @tagName(root.reasoning),
            if (root.provider.kind != .responses) " (applies to codex/responses models — current model ignores it)" else "",
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
        g_jobs.mutex.lockUncancelable(root.io);
        defer g_jobs.mutex.unlock(root.io);
        if (g_jobs.list.items.len == 0) {
            try out.writeAll("no background jobs — the model starts one with bash {run_in_background: true}\n");
            try out.flush();
            return;
        }
        try out.print("{s}background jobs{s}\n", .{ style.bold, style.reset });
        for (g_jobs.list.items) |job| {
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
        // Plain /mcp: list servers (with tool counts) then tools.
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
    if (std.mem.startsWith(u8, line, "/save")) {
        const arg = std.mem.trim(u8, line["/save".len..], " \t");
        const name = if (arg.len == 0) "last" else arg;
        saveSession(root, arena, name) catch |err| {
            try out.print("save failed: {t}\n", .{err});
            try out.flush();
            return;
        };
        try out.print("saved session → {s}{s}\n", .{ name, session_ext });
        try out.flush();
        return;
    }
    if (std.mem.startsWith(u8, line, "/resume")) {
        const arg = std.mem.trim(u8, line["/resume".len..], " \t");
        var name: []const u8 = if (arg.len == 0) "last" else arg;
        // Bare /resume on a TTY: pick from the saved sessions interactively.
        if (arg.len == 0 and use_color and root.in != null) {
            var sessions: std.ArrayList(PickItem) = .empty;
            defer sessions.deinit(arena);
            if (Io.Dir.cwd().openDir(root.io, ".", .{ .iterate = true })) |dir_v| {
                var dir = dir_v;
                defer dir.close(root.io);
                var it = dir.iterate();
                while (it.next(root.io) catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, entry.name, session_ext)) continue;
                    const base = entry.name[0 .. entry.name.len - session_ext.len];
                    sessions.append(arena, .{ .name = arena.dupe(u8, base) catch continue }) catch {};
                }
            } else |_| {}
            if (sessions.items.len == 0) {
                try out.writeAll("(no saved sessions in cwd — /save creates one)\n");
                try out.flush();
                return;
            }
            const idx = listPicker(root, arena, out, "Resume session ›", sessions.items) orelse return;
            name = sessions.items[idx].name;
        }
        loadSession(root, keys.*, arena, name) catch |err| {
            switch (err) {
                error.FileNotFound => try out.print("no session named '{s}' ({s}{s} not found in cwd) — /sessions lists saved ones\n", .{ name, name, session_ext }),
                else => try out.print("resume failed: {t}\n", .{err}),
            }
            try out.flush();
            return;
        };
        try out.print("resumed {s}{s} — {d} message(s), {s} via {s}{s}\n", .{
            name,                                 session_ext, root.messages.items.len, root.provider.model, root.provider.id,
            if (root.strict) " (strict)" else "",
        });
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, line, "/sessions")) {
        var dir = Io.Dir.cwd().openDir(root.io, ".", .{ .iterate = true }) catch {
            try out.writeAll("(could not list cwd)\n");
            try out.flush();
            return;
        };
        defer dir.close(root.io);
        var it = dir.iterate();
        var n: usize = 0;
        while (it.next(root.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, session_ext)) continue;
            const base = entry.name[0 .. entry.name.len - session_ext.len];
            try out.print("  {s}\n", .{base});
            n += 1;
        }
        if (n == 0) try out.writeAll("(no saved sessions in cwd)\n");
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
        \\  /plan           toggle plan mode: read-only explore + propose; writes/edits denied
        \\  /key [prov key] show API-key status; /key <provider> <key> adds one live (+ Keychain)
        \\  /keepcontext    toggle keeping the conversation when /model switches wire format (default on)
        \\  /reasoning      codex/gpt-5 reasoning depth: low|medium|high (default high)
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
        \\  /save [name]    write the conversation to <name>.session.json (default: last)
        \\  /resume [name]  restore a saved conversation (no arg → interactive picker)
        \\  /sessions       list saved sessions in the cwd
        \\  /todo           show the current task list
        \\  /animation      pick the thinking animation (braille/pulse/orbit-dots/block-wave/
        \\                  shimmer/matrix/pacman/starfield/random/off); persists to settings
        \\  /mcp [add …]    list MCP servers/tools; /mcp add <name> <cmd> [args...] connects one live
        \\  exit / /exit    quit (also: ctrl-d, or ctrl-c on an empty line)
        \\
        \\esc during a response interrupts the turn (what streamed stays in history).
        \\"always allow" answers persist to .harness/settings.json in the cwd.
        \\codeword: include "ultracode" in any message to force a multi-agent
        \\workflow turn (phases of parallel subagents, then synthesis).
        \\
        \\launch flags: --model <name> · --yolo (skip prompts) · -p "prompt" (one-shot) · --system-prompt/--append-system-prompt · --timing · --cost · --json (SDK protocol) · --help · --version
        \\subcommands: `graff login [codex]` (OAuth) · `graff key set <provider> <key>` (Keychain) · `graff --schema`
        \\
    );
    try out.flush();
}

const session_ext = ".session.json";

const CodexAuth = struct { token: []const u8, account: []const u8 };

/// Read the Codex CLI's ChatGPT OAuth credentials from ~/.codex/auth.json.
/// Returns the access token + account id (for the chatgpt-account-id header),
/// or null if the file is missing/unparseable (i.e. not logged in).
fn loadCodexAuth(io: Io, arena: Allocator, home: []const u8) ?CodexAuth {
    const path = std.fmt.allocPrint(arena, "{s}/.codex/auth.json", .{home}) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const tokens = v.object.get("tokens") orelse return null;
    if (tokens != .object) return null;
    const token = if (tokens.object.get("access_token")) |t| (if (t == .string) t.string else return null) else return null;
    if (token.len == 0) return null;
    const account = if (tokens.object.get("account_id")) |a| (if (a == .string) a.string else "") else "";
    return .{ .token = token, .account = account };
}

// Codex / ChatGPT OAuth (PKCE) — same client + endpoints the Codex CLI uses
// (verified from the live id_token: aud/client_id app_EMoamEEZ…, iss
// auth.openai.com). `harness login` runs the browser flow; `harness login
// --refresh` refreshes the stored token (no browser).
const oauth_authorize_url = "https://auth.openai.com/oauth/authorize";
const oauth_token_url = "https://auth.openai.com/oauth/token";
const codex_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const codex_redirect = "http://localhost:1455/auth/callback";
const codex_redirect_enc = "http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback";
const oauth_scope_enc = "openid%20profile%20email%20offline_access";

fn b64url(arena: Allocator, bytes: []const u8) []const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = arena.alloc(u8, enc.calcSize(bytes.len)) catch return "";
    return enc.encode(buf, bytes);
}

/// POST a form body to the OAuth token endpoint; return the parsed JSON object.
fn oauthTokenPost(io: Io, gpa: Allocator, arena: Allocator, body: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = oauth_token_url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

/// Pull chatgpt_account_id out of an id_token's claims (base64url middle segment).
fn accountFromIdToken(arena: Allocator, id_token: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, id_token, '.');
    _ = it.next();
    const payload = it.next() orelse return "";
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = dec.calcSizeForSlice(payload) catch return "";
    const buf = arena.alloc(u8, n) catch return "";
    dec.decode(buf, payload) catch return "";
    const v = std.json.parseFromSliceLeaky(Value, arena, buf, .{ .allocate = .alloc_always }) catch return "";
    if (v != .object) return "";
    const a = v.object.get("https://api.openai.com/auth") orelse return "";
    if (a != .object) return "";
    const acct = a.object.get("chatgpt_account_id") orelse return "";
    return if (acct == .string) acct.string else "";
}

fn writeCodexAuth(io: Io, arena: Allocator, home: []const u8, id_token: []const u8, access: []const u8, refresh: []const u8, account: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/.codex/auth.json", .{home});
    var toks: std.json.ObjectMap = .empty;
    try toks.put(arena, "id_token", .{ .string = id_token });
    try toks.put(arena, "access_token", .{ .string = access });
    try toks.put(arena, "refresh_token", .{ .string = refresh });
    try toks.put(arena, "account_id", .{ .string = account });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "auth_mode", .{ .string = "chatgpt" });
    try obj.put(arena, "tokens", .{ .object = toks });
    try obj.put(arena, "last_refresh", .{ .string = "harness-login" });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .object = obj });
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(aw.writer.buffered());
    try fw.interface.flush();
}

/// `harness login [--refresh]`: the ChatGPT/Codex OAuth flow. Fresh login runs
/// PKCE (open browser → localhost:1455 callback → code→token exchange); refresh
/// uses the stored refresh_token. Either way writes ~/.codex/auth.json.
fn codexLogin(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, refresh_only: bool) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    var body: []const u8 = undefined;
    if (refresh_only) {
        const path = try std.fmt.allocPrint(arena, "{s}/.codex/auth.json", .{home});
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch {
            try out.print("not logged in (no {s}) — run `graff login` first\n", .{path});
            try out.flush();
            return;
        };
        const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return error.BadOAuthResponse;
        const refresh = blk: {
            if (v == .object) if (v.object.get("tokens")) |t| if (t == .object)
                if (t.object.get("refresh_token")) |r| if (r == .string) break :blk r.string;
            try out.writeAll("no refresh_token in ~/.codex/auth.json\n");
            try out.flush();
            return;
        };
        body = try std.fmt.allocPrint(arena, "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope={s}", .{ codex_client_id, refresh, oauth_scope_enc });
        try out.writeAll("refreshing Codex token…\n");
        try out.flush();
    } else {
        var vbytes: [48]u8 = undefined;
        io.random(&vbytes);
        const verifier = b64url(arena, &vbytes);
        var ch: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &ch, .{});
        const challenge = b64url(arena, &ch);
        var sbytes: [16]u8 = undefined;
        io.random(&sbytes);
        const state = b64url(arena, &sbytes);

        const url = try std.fmt.allocPrint(arena, "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&id_token_add_organizations=true&codex_cli_simplified_flow=true", .{ oauth_authorize_url, codex_client_id, codex_redirect_enc, oauth_scope_enc, challenge, state });

        // Bind the callback port BEFORE opening the browser, so the redirect
        // can't arrive before we're listening.
        var addr = std.Io.net.IpAddress.parseLiteral("127.0.0.1:1455") catch return error.BadOAuthResponse;
        var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
        defer server.deinit(io);

        try out.print("\nOpen this URL to authorize (browser should open automatically):\n\n{s}\n\nwaiting for the callback on {s} …\n", .{ url, codex_redirect });
        try out.flush();
        openBrowser(io, url);

        const stream = try server.accept(io);
        defer stream.close(io);

        var rbuf: [16 * 1024]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(stream, io, &rbuf);
        const req_line = (sr.interface.takeDelimiter('\n') catch null) orelse return error.BadOAuthResponse;

        // Send a friendly page back so the browser tab isn't left hanging.
        const page = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body style=\"font-family:sans-serif\"><h2>Logged in ✓</h2><p>You can close this tab and return to the harness.</p></body></html>";
        var wbuf: [1024]u8 = undefined;
        var sw = std.Io.net.Stream.Writer.init(stream, io, &wbuf);
        sw.interface.writeAll(page) catch {};
        sw.interface.flush() catch {};

        const code = queryParam(req_line, "code") orelse {
            try out.writeAll("✗ no authorization code in callback\n");
            try out.flush();
            return;
        };
        const got_state = queryParam(req_line, "state") orelse "";
        if (!std.mem.eql(u8, got_state, state)) {
            try out.writeAll("✗ state mismatch — possible CSRF, aborting\n");
            try out.flush();
            return;
        }
        body = try std.fmt.allocPrint(arena, "grant_type=authorization_code&client_id={s}&code={s}&redirect_uri={s}&code_verifier={s}", .{ codex_client_id, code, codex_redirect_enc, verifier });
    }

    const resp = oauthTokenPost(io, gpa, arena, body) catch |err| {
        try out.print("✗ token exchange failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    if (resp.get("error")) |e| {
        const msg = if (e == .string) e.string else "unknown";
        const desc = if (resp.get("error_description")) |d| (if (d == .string) d.string else "") else "";
        try out.print("✗ OAuth error: {s} {s}\n", .{ msg, desc });
        try out.flush();
        return;
    }
    const access = strFieldObj(resp, "access_token") orelse return error.BadOAuthResponse;
    const id_token = strFieldObj(resp, "id_token") orelse "";
    const refresh = strFieldObj(resp, "refresh_token") orelse "";
    const account = accountFromIdToken(arena, id_token);
    try writeCodexAuth(io, arena, home, id_token, access, refresh, account);
    try out.print("✓ logged into Codex (account {s}…) — wrote ~/.codex/auth.json. /model gpt-5.5\n", .{account[0..@min(account.len, 8)]});
    try out.flush();
}

fn strFieldObj(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// Extract a query-string parameter from an HTTP request line ("GET /p?k=v…").
fn queryParam(req_line: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, req_line, '?') orelse return null;
    const sp = std.mem.indexOfScalarPos(u8, req_line, q, ' ') orelse req_line.len;
    var it = std.mem.tokenizeScalar(u8, req_line[q + 1 .. sp], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", url }
    else
        &.{ "xdg-open", url };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
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

const ServeConfig = struct {
    host: []const u8,
    port: u16,
    token: ?[]const u8,
    yolo: bool,
    model: ?[]const u8,
    system_prompt: ?[]const u8,
    append_system_prompt: ?[]const u8,
};

/// Cap on one child event line (a tool_result event carrying a big tool
/// output is the realistic worst case). Also the per-session reader buffer.
const serve_line_cap = 1024 * 1024;
/// Cap on one request body (a user prompt; pasted files can be large).
const serve_body_cap = 8 * 1024 * 1024;

const ServeSession = struct {
    id: [16]u8, // hex
    child: std.process.Child,
    rdr: Io.File.Reader, // persistent reader over child stdout — must not move (gpa.create)
    rbuf: []u8, // gpa-owned backing buffer for rdr
    busy: Io.Mutex = .init, // one in-flight protocol request per session
};

const ServeState = struct {
    gpa: Allocator,
    io: Io,
    exe: []const u8, // this binary, re-spawned as `<exe> --json …` per session
    cfg: ServeConfig,
    mutex: Io.Mutex = .init, // guards sessions
    sessions: std.ArrayList(*ServeSession) = .empty,
    group: *Io.Group, // detached reapers for closed sessions

    fn find(self: *ServeState, id: []const u8) ?*ServeSession {
        for (self.sessions.items) |s| if (std.mem.eql(u8, &s.id, id)) return s;
        return null;
    }
};

/// Constant-time bytes comparison for the bearer token.
fn ctEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn serveLog(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}

fn serveMain(gpa: Allocator, io: Io, cfg: ServeConfig, exe: []const u8) !void {
    const loopback = std.mem.eql(u8, cfg.host, "127.0.0.1") or std.mem.eql(u8, cfg.host, "::1");
    if (!loopback and cfg.token == null)
        std.process.fatal("serve: refusing to bind {s} without auth — pass --token <secret> or set HARNESS_SERVE_TOKEN", .{cfg.host});

    var addr = std.Io.net.IpAddress.parse(cfg.host, cfg.port) catch
        std.process.fatal("serve: --host needs an IP literal, got '{s}'", .{cfg.host});
    var server = std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch |err|
        std.process.fatal("serve: cannot listen on {s}:{d}: {t}", .{ cfg.host, cfg.port, err });
    defer server.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);
    var st: ServeState = .{ .gpa = gpa, .io = io, .exe = exe, .cfg = cfg, .group = &group };

    serveLog(io, "simple-harness serve · http://{s}:{d} · auth: {s} · sessions are `{s} --json` children", .{
        cfg.host, cfg.port, if (cfg.token != null) "bearer token" else "none (loopback)", exe,
    });
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
        group.concurrent(io, serveConn, .{ &st, stream }) catch serveConn(&st, stream);
    }
}

/// One connection: HTTP/1.1 with keep-alive, requests handled in sequence.
fn serveConn(st: *ServeState, stream: std.Io.net.Stream) void {
    const io = st.io;
    defer stream.close(io);
    var rbuf: [32 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    var sr = std.Io.net.Stream.Reader.init(stream, io, &rbuf);
    var sw = std.Io.net.Stream.Writer.init(stream, io, &wbuf);
    var http_server = std.http.Server.init(&sr.interface, &sw.interface);
    while (true) {
        var req = http_server.receiveHead() catch return;
        serveRequest(st, &req) catch return;
    }
}

const serve_json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
};

/// CORS headers, sent only when a bearer token is configured (see the module
/// comment above): with a token the token is the gate and cross-origin
/// browser clients are legitimate; without one, silence keeps browsers out.
const serve_cors_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "authorization, content-type" },
};

const serve_ndjson_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/x-ndjson" },
};
const serve_ndjson_cors_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/x-ndjson" },
    .{ .name = "access-control-allow-origin", .value = "*" },
};

fn serveJsonHeaders(st: *ServeState) []const std.http.Header {
    return if (st.cfg.token != null) &serve_cors_headers else &serve_json_headers;
}

fn respondJson(st: *ServeState, req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    // A body-less POST/DELETE (neither content-length nor transfer-encoding)
    // trips an assert in std's keep-alive discardBody path — just close the
    // connection for those instead.
    const keep = !req.head.method.requestHasBody() or
        req.head.transfer_encoding != .none or req.head.content_length != null;
    try req.respond(body, .{ .status = status, .keep_alive = keep, .extra_headers = serveJsonHeaders(st) });
}

fn serveRequest(st: *ServeState, req: *std.http.Server.Request) !void {
    const io = st.io;
    const gpa = st.gpa;
    // head strings are invalidated once the body reader starts — copy now.
    var target_buf: [256]u8 = undefined;
    if (req.head.target.len > target_buf.len) return respondJson(st, req, .uri_too_long, "{\"error\":\"target too long\"}");
    const target = target_buf[0..req.head.target.len];
    @memcpy(target, req.head.target);
    const method = req.head.method;

    if (method == .OPTIONS) // CORS preflight
        return req.respond("", .{ .status = .no_content, .extra_headers = serveJsonHeaders(st) });

    if (st.cfg.token) |tok| {
        if (!std.mem.eql(u8, target, "/healthz")) {
            var authed = false;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                    if (h.value.len > 7 and std.ascii.eqlIgnoreCase(h.value[0..7], "Bearer ") and ctEql(h.value[7..], tok))
                        authed = true;
                }
            }
            if (!authed) return respondJson(st, req, .unauthorized, "{\"error\":\"unauthorized — send Authorization: Bearer <token>\"}");
        }
    }

    if (method == .GET and std.mem.eql(u8, target, "/healthz")) {
        st.mutex.lockUncancelable(io);
        const n = st.sessions.items.len;
        st.mutex.unlock(io);
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"harness\":\"{s}\",\"schema\":\"{s}\",\"sessions\":{d}}}", .{ harness_version, schema_version, n }) catch unreachable;
        return respondJson(st, req, .ok, body);
    }
    if (method == .GET and std.mem.eql(u8, target, "/v1/schema")) {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        emitSchema(&aw.writer) catch return respondJson(st, req, .internal_server_error, "{\"error\":\"schema emit failed\"}");
        return respondJson(st, req, .ok, aw.writer.buffered());
    }
    if (method == .POST and std.mem.eql(u8, target, "/v1/sessions"))
        return serveCreate(st, req);
    const sess_prefix = "/v1/sessions/";
    if (std.mem.startsWith(u8, target, sess_prefix)) {
        const id = target[sess_prefix.len..];
        if (method == .POST) return serveMessage(st, req, id);
        if (method == .DELETE) return serveDelete(st, req, id);
    }
    return respondJson(st, req, .not_found, "{\"error\":\"not found — see /v1/schema\"}");
}

/// POST /v1/sessions: spawn a `harness --json` child. Per-session options in
/// the (optional) JSON body override the serve-level defaults.
fn serveCreate(st: *ServeState, req: *std.http.Server.Request) !void {
    const io = st.io;
    const gpa = st.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bbuf: [4096]u8 = undefined;
    const br = req.readerExpectContinue(&bbuf) catch return error.WriteFailed;
    const body = br.allocRemaining(arena, .limited(64 * 1024)) catch
        return respondJson(st, req, .payload_too_large, "{\"error\":\"body too large\"}");

    var model = st.cfg.model;
    var yolo = st.cfg.yolo;
    var sys = st.cfg.system_prompt;
    var append_sys = st.cfg.append_system_prompt;
    if (std.mem.trim(u8, body, " \t\r\n").len > 0) {
        const v = std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always }) catch
            return respondJson(st, req, .bad_request, "{\"error\":\"body must be a JSON object\"}");
        if (v != .object) return respondJson(st, req, .bad_request, "{\"error\":\"body must be a JSON object\"}");
        if (v.object.get("model")) |m| if (m == .string) {
            model = m.string;
        };
        if (v.object.get("yolo")) |y| if (y == .bool) {
            yolo = y.bool;
        };
        if (v.object.get("system_prompt")) |s| if (s == .string) {
            sys = s.string;
        };
        if (v.object.get("append_system_prompt")) |s| if (s == .string) {
            append_sys = s.string;
        };
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ st.exe, "--json" });
    if (yolo) try argv.append(arena, "--yolo");
    if (model) |m| try argv.appendSlice(arena, &.{ "--model", m });
    if (sys) |s| try argv.appendSlice(arena, &.{ "--system-prompt", s });
    if (append_sys) |s| try argv.appendSlice(arena, &.{ "--append-system-prompt", s });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit, // tool progress → the server's terminal
    }) catch return respondJson(st, req, .internal_server_error, "{\"error\":\"failed to spawn harness child\"}");

    const rbuf = gpa.alloc(u8, serve_line_cap) catch {
        child.kill(io);
        return error.WriteFailed;
    };
    const sess = gpa.create(ServeSession) catch {
        gpa.free(rbuf);
        child.kill(io);
        return error.WriteFailed;
    };
    var raw: [8]u8 = undefined;
    io.random(&raw);
    sess.* = .{ .id = undefined, .child = child, .rdr = undefined, .rbuf = rbuf };
    _ = std.fmt.bufPrint(&sess.id, "{x:0>16}", .{std.mem.readInt(u64, &raw, .big)}) catch unreachable;
    sess.rdr = sess.child.stdout.?.readerStreaming(io, sess.rbuf);

    st.mutex.lockUncancelable(io);
    const appended = blk: {
        st.sessions.append(gpa, sess) catch break :blk false;
        break :blk true;
    };
    st.mutex.unlock(io);
    if (!appended) {
        sess.child.kill(io);
        gpa.free(sess.rbuf);
        gpa.destroy(sess);
        return error.WriteFailed;
    }
    serveLog(io, "serve: session {s} created (model={s} yolo={})", .{ &sess.id, model orelse "default", yolo });
    var obuf: [64]u8 = undefined;
    const out = std.fmt.bufPrint(&obuf, "{{\"session_id\":\"{s}\"}}", .{&sess.id}) catch unreachable;
    return respondJson(st, req, .created, out);
}

/// POST /v1/sessions/<id>: forward one protocol request line to the child and
/// stream its stdout events back as chunked NDJSON until the terminal event
/// for that request (turn/error for user turns; system_prompt/score acks).
fn serveMessage(st: *ServeState, req: *std.http.Server.Request, id: []const u8) !void {
    const io = st.io;
    const gpa = st.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    st.mutex.lockUncancelable(io);
    const sess = st.find(id);
    st.mutex.unlock(io);
    const s = sess orelse return respondJson(st, req, .not_found, "{\"error\":\"no such session\"}");

    var bbuf: [64 * 1024]u8 = undefined;
    const br = req.readerExpectContinue(&bbuf) catch return error.WriteFailed;
    const body = br.allocRemaining(arena, .limited(serve_body_cap)) catch
        return respondJson(st, req, .payload_too_large, "{\"error\":\"body too large\"}");
    const line = std.mem.trim(u8, body, " \t\r\n");
    const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{ .allocate = .alloc_always }) catch
        return respondJson(st, req, .bad_request, "{\"error\":\"body must be one protocol request object, e.g. {\\\"type\\\":\\\"user\\\",\\\"text\\\":\\\"...\\\"}\"}");
    if (parsed != .object or std.mem.indexOfScalar(u8, line, '\n') != null)
        return respondJson(st, req, .bad_request, "{\"error\":\"body must be a single-line JSON object\"}");

    s.busy.lockUncancelable(io); // serialize requests per session
    defer s.busy.unlock(io);

    {
        var wb: [1024]u8 = undefined;
        var cw = s.child.stdin.?.writerStreaming(io, &wb);
        cw.interface.writeAll(line) catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
        cw.interface.writeByte('\n') catch return error.WriteFailed;
        cw.interface.flush() catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
    }

    var stream_buf: [16 * 1024]u8 = undefined;
    var bw = req.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .extra_headers = if (st.cfg.token != null) &serve_ndjson_cors_headers else &serve_ndjson_headers,
        },
    }) catch return error.WriteFailed;
    while (true) {
        const ev_line = s.rdr.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                bw.writer.writeAll("{\"type\":\"error\",\"message\":\"event line exceeded the 1 MiB serve cap — session closed\"}\n") catch {};
                bw.end() catch {};
                serveDrop(st, s);
                return;
            },
            error.ReadFailed => {
                bw.writer.writeAll("{\"type\":\"error\",\"message\":\"session process exited mid-request\"}\n") catch {};
                bw.end() catch {};
                serveDrop(st, s);
                return;
            },
        } orelse {
            bw.writer.writeAll("{\"type\":\"error\",\"message\":\"session process exited mid-request\"}\n") catch {};
            bw.end() catch {};
            serveDrop(st, s);
            return;
        };
        const trimmed = std.mem.trim(u8, ev_line, " \t\r");
        if (trimmed.len == 0) continue;
        bw.writer.writeAll(trimmed) catch return;
        bw.writer.writeByte('\n') catch return;
        bw.flush() catch return; // deliver each event as it happens
        if (serveTerminalEvent(trimmed)) break;
    }
    bw.end() catch return;
}

/// Is this child event line the terminal event of a protocol request?
/// turn/error end user turns; system_prompt and score are between-turn acks.
/// Unknown event types stream through (edge-version durability) — a newer
/// child must still terminate every request with one of these four.
fn serveTerminalEvent(line: []const u8) bool {
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    // Only the leading "type" field matters; events put it first, so parsing
    // a truncated prefix is enough even for MiB-sized tool_result lines.
    const head = line[0..@min(line.len, 256)];
    var t: []const u8 = "";
    if (std.json.parseFromSliceLeaky(Value, fba.allocator(), line, .{})) |v| {
        if (v == .object) if (v.object.get("type")) |ty| if (ty == .string) {
            t = ty.string;
        };
    } else |_| {
        // Huge line: fall back to a prefix scan for {"type":"..."}.
        const needle = "\"type\":\"";
        if (std.mem.indexOf(u8, head, needle)) |i| {
            const rest = head[i + needle.len ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |j| t = rest[0..j];
        }
    }
    return std.mem.eql(u8, t, "turn") or std.mem.eql(u8, t, "error") or
        std.mem.eql(u8, t, "system_prompt") or std.mem.eql(u8, t, "score");
}

/// Remove a dead session and free it (child already gone or being killed).
fn serveDrop(st: *ServeState, sess: *ServeSession) void {
    const io = st.io;
    st.mutex.lockUncancelable(io);
    for (st.sessions.items, 0..) |p, i| {
        if (p == sess) {
            _ = st.sessions.swapRemove(i);
            break;
        }
    }
    st.mutex.unlock(io);
    sess.child.kill(io); // reaps; harmless if already exited
    st.gpa.free(sess.rbuf);
    st.gpa.destroy(sess);
}

/// Background reaper for a gracefully-closed session: the child exits on
/// stdin EOF (after finishing any in-flight turn) and flushes telemetry and
/// trajectory records on the way out — kill would race (and lose) that flush.
fn serveReap(st: *ServeState, sess: *ServeSession) void {
    const io = st.io;
    _ = sess.child.wait(io) catch {};
    st.gpa.free(sess.rbuf);
    st.gpa.destroy(sess);
}

/// DELETE /v1/sessions/<id>: graceful close. Waits for an in-flight request
/// to finish streaming (the busy lock), then EOFs the child's stdin and
/// reaps it in the background.
fn serveDelete(st: *ServeState, req: *std.http.Server.Request, id: []const u8) !void {
    const io = st.io;
    st.mutex.lockUncancelable(io);
    const found = st.find(id);
    if (found) |sess| {
        for (st.sessions.items, 0..) |p, i| {
            if (p == sess) {
                _ = st.sessions.swapRemove(i);
                break;
            }
        }
    }
    st.mutex.unlock(io);
    const sess = found orelse return respondJson(st, req, .not_found, "{\"error\":\"no such session\"}");
    sess.busy.lockUncancelable(io);
    sess.busy.unlock(io);
    if (sess.child.stdin) |f| {
        f.close(io);
        sess.child.stdin = null;
    }
    st.group.concurrent(io, serveReap, .{ st, sess }) catch serveReap(st, sess);
    serveLog(io, "serve: session {s} closed", .{id});
    return respondJson(st, req, .ok, "{\"ok\":true}");
}

// ---------------------------------------------------------------------------

// Codegraff device-code login — mirrors graff's CodegraffDeviceStrategy:
// POST /v1/device/start → show verification_uri + user_code → poll
// /v1/device/poll until status "ok" yields the cg_sk_ key. Base derived from
// the codegraff provider URL (gateway.codegraff.com). The key is written to
// ~/.simple-harness-codegraff.json, which loadCodegraffKey reads at startup.
const codegraff_device_base = "https://gateway.codegraff.com";
const codegraff_key_file = ".simple-harness-codegraff.json";

fn httpJsonPost(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, body: []const u8) !std.json.ObjectMap {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

fn intFieldObj(obj: std.json.ObjectMap, name: []const u8, default: i64) i64 {
    const v = obj.get(name) orelse return default;
    return if (v == .integer) v.integer else default;
}

fn codegraffLogin(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const start_resp = httpJsonPost(io, gpa, arena, codegraff_device_base ++ "/v1/device/start", "{\"device_label\":\"simple-harness\"}") catch |err| {
        try out.print("✗ device/start failed: {t}\n", .{err});
        try out.flush();
        return;
    };
    const device_code = strFieldObj(start_resp, "device_code") orelse {
        try out.writeAll("✗ no device_code in start response\n");
        try out.flush();
        return;
    };
    const user_code = strFieldObj(start_resp, "user_code") orelse "";
    const vuri = strFieldObj(start_resp, "verification_uri") orelse "https://codegraff.com/cli/auth";
    const vuri_complete = strFieldObj(start_resp, "verification_uri_complete") orelse vuri;
    const interval: i64 = @max(1, intFieldObj(start_resp, "interval", 2));
    const expires: i64 = intFieldObj(start_resp, "expires_in", 600);

    try out.print("\nTo authorize, open:\n\n  {s}\n\nand enter code: {s}{s}{s}\n\nwaiting for approval …\n", .{ vuri, style.bold, user_code, style.reset });
    try out.flush();
    openBrowser(io, vuri_complete);

    const poll_body = try std.fmt.allocPrint(arena, "{{\"device_code\":\"{s}\"}}", .{device_code});
    var waited: i64 = 0;
    while (waited < expires) : (waited += interval) {
        io.sleep(Io.Duration.fromSeconds(interval), .awake) catch {};
        const poll = httpJsonPost(io, gpa, arena, codegraff_device_base ++ "/v1/device/poll", poll_body) catch continue;
        const status = strFieldObj(poll, "status") orelse "pending";
        if (std.mem.eql(u8, status, "ok")) {
            const key = strFieldObj(poll, "api_key") orelse {
                try out.writeAll("✗ approved but no api_key returned\n");
                try out.flush();
                return;
            };
            try writeCodegraffKey(io, arena, home, key);
            try out.print("{s}✓{s} logged into codegraff — key saved to ~/{s}. /model deepseek-v4-pro\n", .{ style.green, style.reset, codegraff_key_file });
            try out.flush();
            return;
        } else if (std.mem.eql(u8, status, "denied")) {
            try out.writeAll("✗ authorization denied\n");
            try out.flush();
            return;
        } else if (std.mem.eql(u8, status, "expired")) {
            try out.writeAll("✗ code expired — run `graff login codegraff` again\n");
            try out.flush();
            return;
        }
    }
    try out.writeAll("✗ timed out waiting for approval\n");
    try out.flush();
}

fn writeCodegraffKey(io: Io, arena: Allocator, home: []const u8, key: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, codegraff_key_file });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "api_key", .{ .string = key });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .object = obj });
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(aw.writer.buffered());
    try fw.interface.flush();
}

/// Load a codegraff key without an env var: the harness's own login file
/// (~/.simple-harness-codegraff.json) first, then graff's store
/// (~/forge/.credentials.json: array, entry id=="codegraff", .auth_details.api_key).
fn loadCodegraffKey(io: Io, arena: Allocator, home: []const u8) ?[]const u8 {
    if (std.fmt.allocPrint(arena, "{s}/{s}", .{ home, codegraff_key_file })) |path| {
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024))) |data| {
            if (std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always })) |v| {
                if (v == .object) if (v.object.get("api_key")) |k| if (k == .string and k.string.len > 0) return k.string;
            } else |_| {}
        } else |_| {}
    } else |_| {}
    if (std.fmt.allocPrint(arena, "{s}/forge/.credentials.json", .{home})) |path| {
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024))) |data| {
            if (std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always })) |v| {
                if (v == .array) for (v.array.items) |e| {
                    if (e != .object) continue;
                    const id = if (e.object.get("id")) |i| (if (i == .string) i.string else "") else "";
                    if (!std.mem.eql(u8, id, "codegraff")) continue;
                    if (e.object.get("auth_details")) |ad| if (ad == .object)
                        if (ad.object.get("api_key")) |k| if (k == .string and k.string.len > 0) return k.string;
                };
            } else |_| {}
        } else |_| {}
    } else |_| {}
    return null;
}

// Safe API-key store. On macOS, keys live in the login Keychain (service
// "simple-harness", account=provider id) via the `security` CLI — never on
// disk in plaintext. Elsewhere they fall back to a 0600 file
// (~/.simple-harness-keys.json). `harness key set <provider> <key>` writes;
// startup reads for any provider whose env var isn't set (env always wins).
const keychain_service = "simple-harness";
const keys_file = ".simple-harness-keys.json";

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
    try s.objectField("messages");
    try s.write(Value{ .array = root.messages });
    try s.endObject();

    const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, session_ext });
    try Io.Dir.cwd().writeFile(root.io, .{ .sub_path = path, .data = aw.writer.buffered() });
}

/// Restore a saved session: parse the file (arena-owned), rebuild the
/// provider, and replace the live history. The wire format must still match
/// the restored provider's kind — same provider id guarantees it.
fn loadSession(root: *Agent, keys: Keys, arena: Allocator, name: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, session_ext });
    const data = try Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(8 * 1024 * 1024));
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.BadSession;
    const obj = parsed.object;
    const pid = if (obj.get("provider")) |v| v.string else return error.BadSession;
    const model = if (obj.get("model")) |v| v.string else return error.BadSession;
    const msgs = if (obj.get("messages")) |v| (if (v == .array) v.array else return error.BadSession) else return error.BadSession;
    const strict = if (obj.get("strict")) |v| (v == .bool and v.bool) else false;

    root.provider = try keys.providerById(pid, model);
    root.messages = msgs;
    root.strict = strict;
    root.last_context_tokens = 0;
    root.cap_new = false; // per-provider; relearn on rejection
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

const TodoItem = struct {
    content: []const u8,
    status: []const u8,
};

/// One agent: a message history plus the POST/tool-dispatch loop. The root
/// agent prints to stdout; subagents (sub = true) run on pool threads and
/// log through std.debug.print, which locks stderr and is thread-safe.
const Agent = struct {
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
    reasoning: ReasoningEffort = .high, // codex/responses reasoning depth (/reasoning)
    sys_strict: []const u8 = main_system_prompt_strict,
    tools_anthropic: []const u8 = tools_anthropic_sub,
    tools_openai: []const u8 = tools_openai_sub,
    tools_responses: []const u8 = tools_responses_sub,
    todos: std.ArrayList(TodoItem) = .empty,
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
    arg_live: ArgLive = .{}, // live attempt_completion/ask_user argument text
    streamed_args: ArgTool = .none, // which meta tool's prose streamed live this request
    streamed_args_len: usize = 0, // raw bytes emitted for it (gates re-print suppression)
    cap_new: bool = false, // provider rejected max_tokens → use max_completion_tokens

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
            try w.print("\n{s}[{s}{s}{s}{s}{s} · {d}/{d}k tok ({d}%){s}{s}]{s} {s}›{s} ", .{
                style.dim,                style.reset,      style.cyan, self.provider.model, flag, style.dim,
                self.last_context_tokens, threshold / 1000, pct,        cached,              cost, style.reset,
                style.bold,               style.reset,
            });
        } else {
            try w.print("\n{s}[{s}{s}{s}{s}{s}{s}]{s} {s}›{s} ", .{
                style.dim,   style.reset, style.cyan,  self.provider.model, flag, style.dim, cost,
                style.reset, style.bold,  style.reset,
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
        var s: std.json.Stringify = .{ .writer = w };
        s.write(ev) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch return;
    }
    fn systemPrompt(self: *const Agent) []const u8 {
        if (self.sub) return self.sys_override orelse sub_system_prompt;
        return if (self.strict) self.sys_strict else self.sys_normal;
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
        while (true) {
            const live = !self.sub and self.out != null and !self.stream_quiet;
            self.streamed_text = false;
            self.streamed_args = .none;
            const body = try self.buildBody(tools, force, live, stream_usage);
            defer self.gpa.free(body);
            const t0: Io.Timestamp = .now(self.io, .awake);
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
                        const max_attempts: usize = if (throttled) 5 else 3;
                        if (attempt < max_attempts) {
                            if (throttled) {
                                const delay_ms = @min(@as(u64, 1000) << @intCast(@min(attempt, 3)), 8000);
                                const what: []const u8 = if (err == error.RateLimited) "rate limited (429)" else "server error (5xx)";
                                try self.say("[{s} — retrying in {d}s ({d}/{d})]\n", .{ what, delay_ms / 1000, attempt + 1, max_attempts });
                                if (self.tracer) |tr| tr.note("retry", what);
                                self.sleepInterruptible(delay_ms) catch return error.Interrupted;
                            } else {
                                try self.say("[network error: {t} — retrying ({d}/{d})]\n", .{ err, attempt + 1, max_attempts });
                            }
                            continue;
                        }
                        try self.say("[request failed: {t} — giving up this turn]\n", .{err});
                        // Network give-up is its own error kind: the ApiError
                        // handler's last_api_error is an API envelope, stale
                        // or null on a pure transport failure.
                        if (g_telem) |t| t.errorEvent("net", @errorName(err));
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
                        const e = root.get("error").?.object;
                        if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                        try self.sayApiError("api error ({s}): {s}", .{ e.get("type").?.string, e.get("message").?.string });
                        return error.ApiError;
                    };
                    self.recordUsage(root);
                    if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
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
                const e = root.get("error").?.object;
                if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                try self.sayApiError("api error ({s}): {s}", .{ e.get("type").?.string, e.get("message").?.string });
                return error.ApiError;
            };
            if (root.get("error")) |e| if (e == .object) {
                const msg = if (e.object.get("message")) |m| m.string else "unknown error";
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
                if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                try self.sayApiError("api error: {s}", .{msg});
                return error.ApiError;
            };

            self.recordUsage(root);
            if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
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
        if (u.get("total_tokens")) |v| {
            if (v == .integer and v.integer > 0) self.last_context_tokens = @intCast(v.integer);
        }
        var cached: i64 = 0;
        if (u.get("input_tokens_details")) |d| if (d == .object) {
            cached = usageInt(d.object, "cached_tokens");
            if (cached > 0) self.last_cache_read = @intCast(cached);
        };
        self.recordCost(usageInt(u, "input_tokens") - cached, cached, usageInt(u, "output_tokens"));
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
                var fco: std.json.ObjectMap = .empty;
                try fco.put(self.arena, "type", .{ .string = "function_call_output" });
                try fco.put(self.arena, "call_id", .{ .string = call.id });
                try fco.put(self.arena, "output", .{ .string = r.text });
                try self.messages.append(.{ .object = fco });
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
                var tr: std.json.ObjectMap = .empty;
                try tr.put(self.arena, "type", .{ .string = "tool_result" });
                try tr.put(self.arena, "tool_use_id", .{ .string = call.id });
                try tr.put(self.arena, "content", .{ .string = r.text });
                if (r.is_error) try tr.put(self.arena, "is_error", .{ .bool = true });
                try blocks.append(.{ .object = tr });
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
                var tool_msg: std.json.ObjectMap = .empty;
                try tool_msg.put(self.arena, "role", .{ .string = "tool" });
                try tool_msg.put(self.arena, "tool_call_id", .{ .string = call.id });
                const text = if (r.is_error)
                    try std.fmt.allocPrint(self.arena, "[error] {s}", .{r.text})
                else
                    r.text;
                try tool_msg.put(self.arena, "content", .{ .string = text });
                try self.messages.append(.{ .object = tool_msg });
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
            var esc_tio: ?std.posix.termios = null;
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
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, tio) catch {};
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

    /// The permission gate, root side: an unapproved bash command prompts
    /// the user — yes once, always (approve the command's first word for
    /// the rest of the session), or no. Returns the denial result, or null
    /// when cleared to execute. Subagents never prompt; their gate is the
    /// allowlist check in execToolInner.
    fn gateTool(self: *Agent, call: ToolCall) !?ExecResult {
        if (self.sub) return null; // subagents: gated structurally, not by prompt
        const approvals = self.approvals orelse return null;

        // Plan mode: read-only, regardless of approvals — deny mutating tools
        // up front (no point prompting for something the mode forbids).
        if (plan_mode) {
            if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or
                (mcp.Registry.isMcp(call.name) and !muonryReadOnly(call.name, call.input))) return .{
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
            if (approvals.allowed(self.io, cmd)) return null;
            key = firstWord(cmd);
            prompt_line = std.fmt.bufPrint(&line_buf, "run: {s}", .{cmd}) catch cmd;
        } else if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file")) {
            if (approvals.allowedExact(self.io, call.name)) return null;
            key = call.name;
            const path = if (call.input == .object)
                (if (call.input.object.get("path")) |p| (if (p == .string) p.string else "?") else "?")
            else
                "?";
            prompt_line = std.fmt.bufPrint(&line_buf, "{s} {s}", .{ call.name, path }) catch call.name;
        } else if (mcp.Registry.isMcp(call.name)) {
            if (muonryTrusted(call.name)) return null; // the whole suite: like native tools
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
        if (std.mem.eql(u8, call.name, "todo_write")) {
            self.todos.clearRetainingCapacity();
            if (call.input.object.get("todos")) |list| if (list == .array) {
                for (list.array.items) |item| {
                    try self.todos.append(self.arena, .{
                        .content = try self.arena.dupe(u8, item.object.get("content").?.string),
                        .status = try self.arena.dupe(u8, item.object.get("status").?.string),
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

    fn sayToolUse(self: *Agent, call: ToolCall) !void {
        if (json_mode) {
            self.emit(.{ .type = "tool_call", .name = call.name, .input = call.input });
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
        if (isMetaName(name)) return;
        if (json_mode) {
            self.emit(.{ .type = "tool_result", .name = name, .is_error = r.is_error, .text = r.text });
            return;
        }
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
    fn compact(self: *Agent) anyerror!void {
        if (self.messages.items.len == 0) {
            try self.say("nothing to compact\n", .{});
            return;
        }
        try self.say("[compacting ~{d} tokens…]\n", .{self.last_context_tokens});
        try self.messages.append(try textMessage(self.arena, "user", compact_instruction));
        errdefer _ = self.messages.pop();

        // The handoff summary is internal — don't stream it to the terminal.
        self.stream_quiet = true;
        defer self.stream_quiet = false;
        const root = try self.request(null);
        const summary = switch (self.provider.kind) {
            .anthropic => blk: {
                for (root.get("content").?.array.items) |block| {
                    if (std.mem.eql(u8, block.object.get("type").?.string, "text"))
                        break :blk block.object.get("text").?.string;
                }
                break :blk "";
            },
            .openai => blk: {
                const message = root.get("choices").?.array.items[0].object.get("message").?;
                const c = message.object.get("content") orelse break :blk "";
                break :blk if (c == .string) c.string else "";
            },
            .responses => blk: {
                const output = root.get("output") orelse break :blk "";
                if (output != .array) break :blk "";
                for (output.array.items) |item| {
                    if (item != .object) continue;
                    const it = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                    if (!std.mem.eql(u8, it, "message")) continue;
                    if (item.object.get("content")) |c| if (c == .array) {
                        for (c.array.items) |b| {
                            if (b != .object) continue;
                            const bt = if (b.object.get("type")) |x| (if (x == .string) x.string else "") else "";
                            if (std.mem.eql(u8, bt, "output_text")) {
                                if (b.object.get("text")) |txt| if (txt == .string) break :blk txt.string;
                            }
                        }
                    };
                }
                break :blk "";
            },
        };
        if (summary.len == 0) {
            try self.say("[compaction failed: empty summary, history unchanged]\n", .{});
            _ = self.messages.pop();
            return;
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
        try self.say("[history compacted to a {d}-char summary]\n", .{summary.len});
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
                for (self.messages.items) |m| try s.write(m);
                try s.endArray();
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
            // Clear-then-draw each frame: animations may vary in width.
            w.interface.writeAll("\r\x1b[2K") catch return;
            anims[g_anim_current].frame(&w.interface, i) catch return;
            w.interface.flush() catch return;
            i += 1;
            var t: usize = 0;
            while (t < 4 and !g_spin_stop.load(.acquire)) : (t += 1)
                io.sleep(.fromMilliseconds(20), .awake) catch break;
        }
        w.interface.writeAll("\r\x1b[2K") catch return;
        w.interface.flush() catch {};
    }

    fn spinnerStart(self: *Agent) void {
        if (self.sub or json_mode or !use_color or self.out == null) return;
        if (g_anim_off) return;
        if (g_spin_future != null) return;
        if (g_anim_random) {
            var b: [1]u8 = undefined;
            self.io.random(&b);
            g_anim_current = b[0] % anims.len;
        } else g_anim_current = g_anim_index;
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

    fn postStream(self: *Agent, body: []const u8) ![]u8 {
        self.spinnerStart();
        defer self.spinnerStop();
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
        var orig_tio: ?std.posix.termios = null;
        if (watch_esc) orig_tio = rawNonblockStdin();
        defer if (orig_tio) |o| {
            drainStdin();
            std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, o) catch {};
        };
        var req = try self.client.request(.POST, try std.Uri.parse(provider.url), .{
            .redirect_behavior = .unhandled,
            .headers = .{ .content_type = .{ .override = "application/json" } },
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
        req.transfer_encoding = .{ .content_length = body.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try req.connection.?.flush();
        var response = try req.receiveHead(&.{});

        // 429/5xx before any body: a retryable throttle — request() backs
        // off and retries (surfaced in the trace as a "retry" note).
        const status_code = @intFromEnum(response.head.status);
        if (status_code == 429 or status_code >= 500) {
            if (req.connection) |conn| conn.closing = true;
            return if (status_code == 429) error.RateLimited else error.ServerError;
        }
        // Esc pressed while connecting / waiting for headers? Stop before
        // reading any of the body.
        if (orig_tio != null and escPressed()) {
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
            _ = try reader.streamDelimiterEnding(&line.writer, '\n');
            // End of stream leaves the reader empty; otherwise the '\n' is
            // still buffered (and consumed below, after the line is handled).
            const more = if (reader.peekByte()) |_| true else |_| false;
            try full.writer.writeAll(line.writer.buffered());
            try full.writer.writeByte('\n');
            self.printDelta(line.writer.buffered());
            line.clearRetainingCapacity();
            if ((orig_tio != null and escPressed()) or (self.sub and esc_cancel.load(.acquire))) {
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
    var esc_cancel: std.atomic.Value(bool) = .init(false);
    var esc_watch_done: std.atomic.Value(bool) = .init(true);

    fn escWatchTask() void {
        while (!esc_watch_done.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, 100) catch return;
            if (n > 0 and escPressed()) {
                esc_cancel.store(true, .release);
                return;
            }
        }
    }

    /// Non-blocking scan of stdin for a bare Esc keypress (terminal must be
    /// in VMIN=0 raw mode). Escape *sequences* (arrows: ESC [ …) don't count;
    /// any other typed-ahead bytes are discarded.
    fn escPressed() bool {
        var buf: [64]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (buf[i] != 0x1b) continue;
            if (i + 1 >= n) return true; // lone Esc at the end of the burst
            if (buf[i + 1] != '[' and buf[i + 1] != 'O') return true;
        }
        return false;
    }

    /// Discard any bytes queued on stdin (terminal must be in VMIN=0 raw
    /// mode) so typed-ahead keys from mid-turn don't leak into the prompt.
    fn drainStdin() void {
        var buf: [256]u8 = undefined;
        while (true) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return;
            if (n == 0) return;
        }
    }

    /// Put stdin into raw non-blocking no-echo mode (VMIN=0) for Esc
    /// watching. Returns the termios to restore, or null off-tty.
    fn rawNonblockStdin() ?std.posix.termios {
        const fd = std.posix.STDIN_FILENO;
        const orig = std.posix.tcgetattr(fd) catch return null;
        var traw = orig;
        traw.lflag.ICANON = false;
        traw.lflag.ECHO = false;
        traw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        traw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(fd, .NOW, traw) catch return null;
        return orig;
    }

    /// Sleep `ms` watching stdin for Esc (when the root is on a TTY), so the
    /// user can cancel a retry backoff instead of waiting it out.
    fn sleepInterruptible(self: *Agent, ms: u64) error{Interrupted}!void {
        const watch = !self.sub and self.in != null and use_color and !json_mode;
        const orig_tio: ?std.posix.termios = if (watch) rawNonblockStdin() else null;
        defer if (orig_tio) |o| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, o) catch {};
        var left = ms;
        while (left > 0) {
            const chunk = @min(left, 100);
            self.io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch {};
            left -= chunk;
            if (orig_tio != null and escPressed()) return error.Interrupted;
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
        if (text.len == 0) return;
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

fn textMessage(arena: Allocator, role: []const u8, text: []const u8) !Value {
    var msg: std.json.ObjectMap = .empty;
    try msg.put(arena, "role", .{ .string = role });
    try msg.put(arena, "content", .{ .string = try arena.dupe(u8, text) });
    return .{ .object = msg };
}

/// A base64-encoded image staged by `/image`, sent with the next user turn.
const PendingImage = struct { media_type: []const u8, b64: []const u8, label: []const u8 };

/// Conservative vision check: only models we know accept images. Everything
/// else (deepseek, kimi, glm, minimax, mimo, …) is treated as text-only so
/// `/image` can point it out instead of triggering a provider 400.
/// Vision support by model-name prefix (provider-agnostic): which models
/// accept image content blocks. Used by /image, Ctrl-V, image drops, and
/// the /models vision column.
fn visionModel(m: []const u8) bool {
    return std.mem.startsWith(u8, m, "claude") or
        std.mem.startsWith(u8, m, "gpt-5") or
        std.mem.startsWith(u8, m, "gpt-4") or
        std.mem.startsWith(u8, m, "grok-4") or
        std.mem.startsWith(u8, m, "gemini");
}

fn visionCapable(p: Provider) bool {
    return visionModel(p.model);
}

/// Guess an image media type from a file extension (default image/png).
fn imageMediaType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    return "image/png";
}

/// A user message carrying text + one image, in the provider's wire format.
fn imageMessage(arena: Allocator, kind: Provider.Kind, text: []const u8, img: PendingImage) !Value {
    var msg: std.json.ObjectMap = .empty;
    try msg.put(arena, "role", .{ .string = "user" });
    var content = std.json.Array.init(arena);

    var tb: std.json.ObjectMap = .empty;
    try tb.put(arena, "type", .{ .string = if (kind == .responses) "input_text" else "text" });
    try tb.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
    try content.append(.{ .object = tb });

    var ib: std.json.ObjectMap = .empty;
    switch (kind) {
        .anthropic => {
            try ib.put(arena, "type", .{ .string = "image" });
            var src: std.json.ObjectMap = .empty;
            try src.put(arena, "type", .{ .string = "base64" });
            try src.put(arena, "media_type", .{ .string = img.media_type });
            try src.put(arena, "data", .{ .string = img.b64 });
            try ib.put(arena, "source", .{ .object = src });
        },
        .openai => {
            try ib.put(arena, "type", .{ .string = "image_url" });
            var iu: std.json.ObjectMap = .empty;
            try iu.put(arena, "url", .{ .string = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.media_type, img.b64 }) });
            try ib.put(arena, "image_url", .{ .object = iu });
        },
        .responses => {
            try ib.put(arena, "type", .{ .string = "input_image" });
            try ib.put(arena, "image_url", .{ .string = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.media_type, img.b64 }) });
        },
    }
    try content.append(.{ .object = ib });
    try msg.put(arena, "content", .{ .array = content });
    return .{ .object = msg };
}

const StageResult = enum { ok, no_vision, read_fail };

/// Read an image file, base64-encode it, and stage it on the agent for the next
/// turn (shared by /image, /paste, and Ctrl-V). Refuses on non-vision models.
fn stageImagePath(root: *Agent, path: []const u8) StageResult {
    if (!visionCapable(root.provider)) return .no_vision;
    const arena = root.arena;
    const data = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(5 * 1024 * 1024)) catch return .read_fail;
    const enc = std.base64.standard.Encoder;
    const b64 = arena.alloc(u8, enc.calcSize(data.len)) catch return .read_fail;
    _ = enc.encode(b64, data);
    root.pending_image = .{ .media_type = imageMediaType(path), .b64 = b64, .label = arena.dupe(u8, path) catch path };
    return .ok;
}

/// macOS: dump the clipboard image (if any) to a temp PNG via osascript and
/// return its path; null if the clipboard holds no image (or not macOS).
/// (A terminal can't receive clipboard image bytes over stdin, so we ask the OS.)
fn grabClipboardImage(io: Io) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const path = "/tmp/.harness-clip.png";
    var child = std.process.spawn(io, .{
        .argv = &.{
            "osascript",
            "-e",
            "try",
            "-e",
            "set thePNG to (the clipboard as «class PNGf»)",
            "-e",
            "set fp to open for access POSIX file \"/tmp/.harness-clip.png\" with write permission",
            "-e",
            "set eof fp to 0",
            "-e",
            "write thePNG to fp",
            "-e",
            "close access fp",
            "-e",
            "on error",
            "-e",
            "error number 1",
            "-e",
            "end try",
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const term = child.wait(io) catch return null;
    if (term == .exited and term.exited == 0) return path;
    return null;
}
/// Auth + provider-specific headers shared by post() and Agent.postStream().
fn providerHeaders(provider: Provider, bearer: []const u8, buf: *[6]std.http.Header) []const std.http.Header {
    var n: usize = 0;
    switch (provider.auth) {
        .x_api_key => {
            buf[n] = .{ .name = "x-api-key", .value = provider.api_key };
            n += 1;
        },
        .bearer => {
            buf[n] = .{ .name = "authorization", .value = bearer };
            n += 1;
        },
    }
    // Anthropic-format endpoints also get the anthropic-version header
    // (harmless extra for compatible providers).
    if (provider.kind == .anthropic) {
        buf[n] = .{ .name = "anthropic-version", .value = anthropic_version };
        n += 1;
    }
    // Codex / ChatGPT backend: identify as the codex client and carry the
    // ChatGPT account id + Responses beta opt-in.
    if (provider.kind == .responses) {
        buf[n] = .{ .name = "chatgpt-account-id", .value = provider.account };
        n += 1;
        buf[n] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
        n += 1;
        buf[n] = .{ .name = "originator", .value = "codex_cli_rs" };
        n += 1;
        buf[n] = .{ .name = "session_id", .value = "00000000-0000-0000-0000-000000000001" };
        n += 1;
    }
    return buf[0..n];
}

/// POST the request body; returns the raw response body (caller frees).
/// std.http.Client.fetch is thread-safe, so subagents on pool threads share
/// this client (and its connection pool).
fn post(gpa: Allocator, client: *std.http.Client, provider: Provider, body: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    const bearer = switch (provider.auth) {
        .x_api_key => "",
        .bearer => try std.fmt.allocPrint(gpa, "Bearer {s}", .{provider.api_key}),
    };
    defer if (bearer.len > 0) gpa.free(bearer);

    var headers_buf: [6]std.http.Header = undefined;
    const extra = providerHeaders(provider, bearer, &headers_buf);

    const res = try client.fetch(.{
        .location = .{ .url = provider.url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra,
    });
    const code = @intFromEnum(res.status);
    if (code == 429 or code >= 500) return if (code == 429) error.RateLimited else error.ServerError;
    return aw.toOwnedSlice();
}

/// Hard ceiling on one non-streaming request. The legitimate worst case
/// observed (a 160k-token subagent context) completed in ~134s; anything
/// past this is a hung response, not a slow one.
const post_deadline_ms: u64 = 5 * 60 * 1000;

const WatchdogFired = enum { esc, deadline };

/// Watchdog arm for postWatched: ticks every 200ms so a user Esc aborts a
/// stuck subagent request promptly; otherwise fires at the hard deadline.
fn postWatchdog(io: Io) WatchdogFired {
    var waited: u64 = 0;
    while (waited < post_deadline_ms) {
        io.sleep(.fromMilliseconds(200), .awake) catch return .deadline; // canceled: loser arm, result discarded
        waited += 200;
        if (Agent.esc_cancel.load(.acquire)) return .esc;
    }
    return .deadline;
}

/// Select-arm wrapper for `post` (pins the member type to anyerror![]u8).
fn postTask(gpa: Allocator, client: *std.http.Client, provider: Provider, body: []const u8) anyerror![]u8 {
    return post(gpa, client, provider, body);
}

/// Cancel the remaining select arms, freeing a late-arriving response body
/// (cancelDiscard would leak it — see Io.Select.cancel docs).
fn drainPostSelect(gpa: Allocator, sel: anytype) void {
    while (sel.cancel()) |late| switch (late) {
        .posted => |p| {
            if (p) |b| gpa.free(b) else |_| {}
        },
        .watchdog => {},
    };
}

/// Non-streaming POST raced against a watchdog. A bare `post` can block
/// forever on a stalled response — a hung subagent request once wedged an
/// entire workflow await, with no Esc path into the child's HTTP call.
/// Esc surfaces as error.Interrupted (no retry); the deadline as
/// error.HungRequest, which request()'s retry loop treats as a transport
/// flake. Falls back to a bare post when no spare concurrency exists.
fn postWatched(gpa: Allocator, io: Io, client: *std.http.Client, provider: Provider, body: []const u8) ![]u8 {
    const Done = union(enum) { posted: anyerror![]u8, watchdog: WatchdogFired };
    var done_buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &done_buf);
    sel.concurrent(.posted, postTask, .{ gpa, client, provider, body }) catch
        return post(gpa, client, provider, body); // no concurrency: accept the hang risk
    sel.concurrent(.watchdog, postWatchdog, .{io}) catch {
        const r = sel.await() catch |e| { // posted is the only arm
            sel.cancelDiscard();
            return e;
        };
        sel.cancelDiscard();
        return r.posted;
    };
    const first = sel.await() catch |e| {
        drainPostSelect(gpa, &sel);
        return e;
    };
    drainPostSelect(gpa, &sel);
    return switch (first) {
        .posted => |p| p,
        .watchdog => |w| if (w == .esc) error.Interrupted else error.HungRequest,
    };
}

const ToolOutput = struct {
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
        const res = runHookCmd(ctx.gpa, ctx.io, h.command, payload, h.timeout_ms);
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
        const res = runHookCmd(ctx.gpa, ctx.io, h.command, payload, h.timeout_ms);
        if (res.stderr.len > 0) ctx.gpa.free(res.stderr);
    }
}

/// Runs on a pool thread; never throws — failures become is_error results.
/// Every execution is timed (out.ms) and traced.
fn execTool(ctx: ToolCtx, call: ToolCall) ToolOutput {
    const t0: Io.Timestamp = .now(ctx.io, .awake);
    if (hookGate(ctx, call)) |blocked| {
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
        if (g_telem) |t| t.errorEvent("tool", detail);
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

const CappedRun = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
};

/// Like `std.process.run`, but hitting an output cap *truncates* instead of
/// failing the call: the first `cap` bytes are kept, the rest is discarded
/// as it streams (retained memory never exceeds the caps), and the child
/// still runs to completion so its exit code is real. A chatty `python`
/// (or an accidental `cat` of something huge) costs the child's own
/// process memory, never the harness's.
fn runCapped(gpa: Allocator, io: Io, argv: []const []const u8, stdout_cap: usize, stderr_cap: usize) !CappedRun {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const readers = [2]*Io.Reader{ multi_reader.reader(0), multi_reader.reader(1) };
    const caps = [2]usize{ stdout_cap, stderr_cap };
    var saved: [2]?[]u8 = .{ null, null };
    errdefer for (saved) |s| if (s) |b| gpa.free(b);

    // Fill in 200ms ticks so a root Esc (Agent.esc_cancel, set by the
    // tool-join watcher) kills a long-running child instead of waiting it
    // out — this is where a hung `sleep`-style command actually dies.
    var esc_killed = false;
    loop: while (true) {
        multi_reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break :loop,
            error.Timeout => {}, // poll tick: no data, just check for cancel
            else => |e| return e,
        };
        for (readers, caps, &saved) |r, cap, *s| {
            const buf = r.buffered();
            if (s.* == null and buf.len > cap) s.* = try gpa.dupe(u8, buf[0..cap]);
            if (s.* != null) r.toss(buf.len); // past the cap: discard as it streams
        }
        if (Agent.esc_cancel.load(.acquire)) {
            esc_killed = true;
            child.kill(io);
            break :loop;
        }
    }
    if (!esc_killed) try multi_reader.checkAnyError(); // killed streams error by design

    // kill() already reaped the child (wait would assert on id == null).
    const term: std.process.Child.Term = if (esc_killed) .{ .signal = .TERM } else try child.wait(io);
    const stdout = if (saved[0]) |b| b else try gpa.dupe(u8, readers[0].buffered());
    errdefer gpa.free(stdout);
    const stderr = if (saved[1]) |b| b else try gpa.dupe(u8, readers[1].buffered());
    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_truncated = saved[0] != null,
        .stderr_truncated = saved[1] != null,
    };
}

/// One background bash job (`bash` with run_in_background:true). A pump task
/// continuously drains stdout+stderr into `buf` so the child never blocks on
/// a full pipe; bash_output returns the bytes past `cursor`; bash_kill stops
/// it. Jobs are session-global — they deliberately survive the turn (and the
/// Esc cancel) that started them — and are reaped at exit.
const Job = struct {
    id: u32,
    cmd: []u8, // gpa-owned, for /jobs display
    child: std.process.Child,
    buf: std.ArrayList(u8) = .empty, // interleaved stdout+stderr
    cursor: usize = 0, // start of unread output
    exit_code: ?u8 = null, // meaningful once done
    done: bool = false,
    killed: bool = false, // ended via bash_kill rather than naturally
    kill_requested: bool = false, // pump notices within one 200ms tick
    dropped: bool = false, // unread output overflowed job_unread_cap
    future: Io.Future(void) = undefined, // the pump; awaited only by jobsReap
};

const job_unread_cap = 256 * 1024;
const job_wait_cap_ms: u64 = 30_000;

const Jobs = struct {
    mutex: Io.Mutex = .init,
    list: std.ArrayList(*Job) = .empty,
    next_id: u32 = 1,

    /// Caller holds the mutex.
    fn find(self: *Jobs, id: u32) ?*Job {
        for (self.list.items) |j| if (j.id == id) return j;
        return null;
    }
};

var g_jobs: Jobs = .{};

/// Drain whatever the MultiReader has buffered into the job's output buffer,
/// dropping the oldest *unread* bytes past the cap (a chatty server must not
/// grow memory unboundedly between bash_output polls). Caller holds the mutex.
fn jobDrain(job: *Job, gpa: Allocator, readers: []const *Io.Reader) void {
    for (readers) |r| {
        const b = r.buffered();
        if (b.len == 0) continue;
        job.buf.appendSlice(gpa, b) catch {};
        r.toss(b.len);
    }
    if (job.buf.items.len - job.cursor > job_unread_cap) {
        const drop = job.buf.items.len - job.cursor - job_unread_cap;
        job.buf.replaceRange(gpa, job.cursor, drop, &.{}) catch return;
        job.dropped = true;
    }
}

/// Pump task (one per job, on its own unit of concurrency): same MultiReader
/// loop as runCapped, but appending into the job buffer under the jobs mutex
/// and ignoring Esc — background jobs outlive turn cancellation by design.
fn jobPump(job: *Job, gpa: Allocator, io: Io) void {
    var mrb: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mrb.toStreams(), &.{ job.child.stdout.?, job.child.stderr.? });
    defer mr.deinit();
    const readers = [2]*Io.Reader{ mr.reader(0), mr.reader(1) };
    var killed = false;
    loop: while (true) {
        mr.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break :loop,
            error.Timeout => {}, // poll tick: check for a kill request
            else => break :loop,
        };
        g_jobs.mutex.lockUncancelable(io);
        jobDrain(job, gpa, &readers);
        killed = job.kill_requested;
        g_jobs.mutex.unlock(io);
        if (killed) break :loop;
    }
    g_jobs.mutex.lockUncancelable(io);
    jobDrain(job, gpa, &readers); // final drain of anything left at EOF/kill
    killed = killed or job.kill_requested;
    g_jobs.mutex.unlock(io);
    var code: ?u8 = null;
    if (killed) {
        job.child.kill(io); // also reaps (wait would assert afterwards)
    } else if (job.child.wait(io)) |term| {
        code = switch (term) {
            .exited => |c| c,
            else => null,
        };
    } else |_| {}
    g_jobs.mutex.lockUncancelable(io);
    job.exit_code = code;
    job.killed = killed;
    job.done = true;
    g_jobs.mutex.unlock(io);
}

/// Spawn a background job and its pump. Uses io.concurrent (NOT io.async,
/// which may run inline and block this tool forever on a long-lived child);
/// no spare concurrency cleans up and surfaces the error to the model.
fn spawnJob(gpa: Allocator, io: Io, cmd: []const u8) !*Job {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const cmd_copy = gpa.dupe(u8, cmd) catch |e| {
        child.kill(io);
        return e;
    };
    const job = gpa.create(Job) catch |e| {
        gpa.free(cmd_copy);
        child.kill(io);
        return e;
    };
    job.* = .{ .id = 0, .cmd = cmd_copy, .child = child };
    g_jobs.mutex.lockUncancelable(io);
    job.id = g_jobs.next_id;
    g_jobs.next_id += 1;
    const appended = blk: {
        g_jobs.list.append(gpa, job) catch break :blk false;
        break :blk true;
    };
    g_jobs.mutex.unlock(io);
    if (!appended) {
        job.child.kill(io);
        gpa.free(job.cmd);
        gpa.destroy(job);
        return error.OutOfMemory;
    }
    job.future = io.concurrent(jobPump, .{ job, gpa, io }) catch |e| {
        g_jobs.mutex.lockUncancelable(io);
        for (g_jobs.list.items, 0..) |j, i| {
            if (j == job) {
                _ = g_jobs.list.swapRemove(i);
                break;
            }
        }
        g_jobs.mutex.unlock(io);
        job.child.kill(io);
        gpa.free(job.cmd);
        gpa.destroy(job);
        return e;
    };
    return job;
}

/// bash_output: new output since the last read + status. With wait_ms > 0,
/// polls until new output, exit, Esc, or the (capped) deadline.
fn jobOutput(gpa: Allocator, io: Io, id: u32, wait_ms: u64) !ToolOutput {
    const deadline = @min(wait_ms, job_wait_cap_ms);
    var waited: u64 = 0;
    while (true) {
        g_jobs.mutex.lockUncancelable(io);
        const job = g_jobs.find(id) orelse {
            g_jobs.mutex.unlock(io);
            return .{ .text = try std.fmt.allocPrint(gpa, "no background job {d} — it may never have started; /jobs lists them", .{id}), .is_error = true };
        };
        const fresh = job.buf.items[job.cursor..];
        if (fresh.len > 0 or job.done or waited >= deadline) {
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const w = &aw.writer;
            if (!job.done) {
                try w.print("[job {d}: running]", .{id});
            } else if (job.killed) {
                try w.print("[job {d}: killed]", .{id});
            } else if (job.exit_code) |c| {
                try w.print("[job {d}: exited with code {d}]", .{ id, c });
            } else {
                try w.print("[job {d}: terminated abnormally]", .{id});
            }
            if (job.dropped) {
                try w.print("\n[oldest unread output was dropped at the {d} KB cap]", .{job_unread_cap / 1024});
                job.dropped = false;
            }
            if (fresh.len > 0) {
                try w.writeAll("\n");
                try w.writeAll(fresh);
            } else {
                try w.writeAll("\n(no new output)");
            }
            job.cursor = job.buf.items.len;
            g_jobs.mutex.unlock(io);
            return .{ .text = try aw.toOwnedSlice() };
        }
        g_jobs.mutex.unlock(io);
        if (Agent.esc_cancel.load(.acquire)) {
            waited = deadline; // render current state on the next pass
            continue;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {
            waited = deadline;
            continue;
        };
        waited += 100;
    }
}

/// bash_kill: flag the job and wait (bounded) for the pump to kill + reap it.
/// The pump's future is never awaited here — jobsReap owns it — so two
/// racing kills are harmless.
fn jobKill(gpa: Allocator, io: Io, id: u32) !ToolOutput {
    {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        const job = g_jobs.find(id) orelse return .{ .text = try std.fmt.allocPrint(gpa, "no background job {d} — /jobs lists them", .{id}), .is_error = true };
        if (job.done) {
            const unread = job.buf.items.len - job.cursor;
            return .{ .text = try std.fmt.allocPrint(gpa, "job {d} already finished ({d} unread byte(s) — bash_output reads them)", .{ id, unread }) };
        }
        job.kill_requested = true;
    }
    // The pump notices within one 200ms tick; give it a generous 2s.
    var waited: u64 = 0;
    while (waited < 2000) {
        g_jobs.mutex.lockUncancelable(io);
        const done = if (g_jobs.find(id)) |job| job.done else true;
        g_jobs.mutex.unlock(io);
        if (done) {
            g_jobs.mutex.lockUncancelable(io);
            defer g_jobs.mutex.unlock(io);
            const unread = if (g_jobs.find(id)) |job| job.buf.items.len - job.cursor else 0;
            return .{ .text = try std.fmt.allocPrint(gpa, "job {d} killed ({d} unread byte(s) — bash_output reads them)", .{ id, unread }) };
        }
        io.sleep(.fromMilliseconds(100), .awake) catch break;
        waited += 100;
    }
    return .{ .text = try std.fmt.allocPrint(gpa, "job {d}: kill requested (still shutting down — check bash_output)", .{id}) };
}

/// Session end: kill every job, await the pumps (sole owner of the futures),
/// free everything. Runs from main's defer, after the REPL/one-shot returns.
fn jobsReap(gpa: Allocator, io: Io) void {
    g_jobs.mutex.lockUncancelable(io);
    const jobs = g_jobs.list.toOwnedSlice(gpa) catch {
        g_jobs.mutex.unlock(io);
        return;
    };
    for (jobs) |job| job.kill_requested = true;
    g_jobs.mutex.unlock(io);
    for (jobs) |job| {
        job.future.await(io);
        job.buf.deinit(gpa);
        gpa.free(job.cmd);
        gpa.destroy(job);
    }
    gpa.free(jobs);
    g_jobs.list.deinit(gpa);
}

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
        const run = try runCapped(gpa, io, &.{ "/bin/sh", "-c", cmd }, bash_stdout_cap, bash_stderr_cap);
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
        if (exit_code) |code| {
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
            const run = runCapped(gpa, io, &.{ "kuri-fetch", "-q", "--no-color", url }, webfetch_cap, 4096) catch break :kuri;
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
            const run = runCapped(gpa, io, &.{ "zigpatch", path, "-p", old, "--all", "--content", new }, 4096, 4096) catch break :zp;
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
    const label = if (input.object.get("description")) |d| d.string else "subagent";
    const prompt = input.object.get("prompt").?.string;
    const sys_override = resolveOverride(input.object);
    return runSub(ctx, "subagent", label, prompt, sys_override);
}

/// Run one isolated subagent to completion: fresh arena, fresh history,
/// same shared http client and provider. Runs entirely on this pool thread;
/// its own tool calls fan out further via io.async. `sys_override` swaps the
/// lean default system prompt for a per-child variant (swarm prompt
/// evolution); either way the run is recorded as a trajectory node under
/// the turn that spawned it, with the prompt's fingerprint.
fn runSub(ctx: ToolCtx, kind: []const u8, label: []const u8, prompt: []const u8, sys_override: ?[]const u8) !ToolOutput {
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
    if (sys_override != null) if (g_telem) |t| t.countVariant();
    std.debug.print("  [{s}] started\n", .{label});
    try agent.messages.append(try textMessage(arena, "user", prompt));
    defer agent.tools_used.deinit(gpa);
    const report = agent.runTurn();
    const run_ms: i64 = @intCast(@max(0, sub_start.untilNow(ctx.io, .awake).toMilliseconds()));
    const run_ok = if (report) |r| r.len > 0 else |_| false;
    const tools = agent.tools_used.render(arena);
    const fp = promptFingerprint(agent.systemPrompt());
    if (g_traj) |tj| {
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
            .task = utf8Prefix(prompt, 160),
            .tools = tools,
            .ok = run_ok,
            .context_tokens = agent.last_context_tokens,
        });
    }
    if (g_telem) |t| t.runEvent(&fp, sys_override != null, run_ok, run_ms, tools);
    const text = try report;
    std.debug.print("  [{s}] done\n", .{label});
    if (text.len == 0) return .{ .text = try gpa.dupe(u8, "subagent finished without a report"), .is_error = true };
    return .{ .text = try gpa.dupe(u8, text) };
}

/// One task inside a workflow phase; never throws, suitable for io.async.
fn workflowTask(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8) ToolOutput {
    return runSub(ctx, "workflow_task", label, prompt, sys_override) catch |err| failure(ctx.gpa, err);
}

const max_workflow_phases = 5;
const max_workflow_tasks = 8;

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
    const phases_val = input.object.get("phases") orelse return .{
        .text = try gpa.dupe(u8, "workflow needs a phases array"),
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
    defer if (g_telem) |t| t.workflowEvent(
        phases.len,
        wf_tasks,
        wf_failed,
        @intCast(@max(0, wf_start.untilNow(ctx.io, .awake).toMilliseconds())),
    );

    var prev_results: []const u8 = "";
    for (phases, 1..) |phase_val, phase_no| {
        const phase = phase_val.object;
        const title = if (phase.get("title")) |t| t.string else "phase";
        const tasks_val = phase.get("tasks") orelse return .{
            .text = try gpa.dupe(u8, "each phase needs a tasks array"),
            .is_error = true,
        };
        const tasks = tasks_val.array.items;
        if (tasks.len == 0 or tasks.len > max_workflow_tasks) return .{
            .text = try std.fmt.allocPrint(gpa, "each phase needs 1-{d} tasks", .{max_workflow_tasks}),
            .is_error = true,
        };
        std.debug.print("  [workflow] phase {d}/{d}: {s} ({d} task(s))\n", .{ phase_no, phases.len, title, tasks.len });

        // Resolve prompts: substitute or append the previous phase results.
        const prompts = try arena.alloc([]const u8, tasks.len);
        const labels = try arena.alloc([]const u8, tasks.len);
        const overrides = try arena.alloc(?[]const u8, tasks.len);
        for (tasks, prompts, labels, overrides) |task_val, *prompt, *label, *override| {
            const task = task_val.object;
            label.* = if (task.get("description")) |d| d.string else "task";
            override.* = resolveOverride(task);
            const raw = task.get("prompt").?.string;
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
        for (labels, prompts, overrides, futures) |label, prompt, override, *fut| {
            fut.* = ctx.io.async(workflowTask, .{ ctx, label, prompt, override });
        }
        for (futures, outputs) |*fut, *out| out.* = fut.await(ctx.io);
        defer for (outputs) |out| gpa.free(out.text);
        wf_tasks += tasks.len;
        for (outputs) |out| {
            if (out.is_error) wf_failed += 1;
        }

        var aw: Io.Writer.Allocating = .init(arena);
        for (labels, outputs) |label, out| {
            try aw.writer.print("### {s}{s}\n{s}\n\n", .{
                label, if (out.is_error) " (failed)" else "", out.text,
            });
        }
        prev_results = std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
    }
    return .{ .text = try gpa.dupe(u8, prev_results) };
}

// ── Unit tests (`zig build test`) ──────────────────────────────────────────

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

test "promptFingerprint is stable, short, and collision-visible" {
    const a = promptFingerprint("you are a careful reviewer");
    const b = promptFingerprint("you are a careful reviewer");
    const c = promptFingerprint("you are a careless reviewer");
    try std.testing.expectEqualStrings(&a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "score signing message is canonical and cross-language stable" {
    // This exact byte layout is the contract the Python/JS verifiers
    // reimplement — a change here breaks signature verification, so it is
    // pinned. Score is fixed to 6 decimals; fields newline-joined; "v1" tag.
    var buf: [512]u8 = undefined;
    const msg = scoreSigMessage(&buf, "aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "").?;
    try std.testing.expectEqualStrings("v1\naaaaaaaaaaaaaaaa\n\n0.500000\nrun123\nj1\n\n", msg);

    // With a key, signScore is a stable, key-dependent HMAC; without one
    // (default global) it is all-zero hex and callers omit it.
    g_score_key = "testkey";
    defer g_score_key = null;
    const sig = signScore("aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "");
    const sig2 = signScore("aaaaaaaaaaaaaaaa", "", 0.5, "run123", "j1", "", "");
    try std.testing.expectEqualStrings(&sig, &sig2); // deterministic
    const sig_changed = signScore("aaaaaaaaaaaaaaaa", "", 0.6, "run123", "j1", "", "");
    try std.testing.expect(!std.mem.eql(u8, &sig, &sig_changed)); // score is signed
}

test "utf8Prefix truncates without splitting codepoints" {
    try std.testing.expectEqualStrings("abc", utf8Prefix("abc", 10));
    const s = [_]u8{ 'a', 'b', 0xC3, 0xA9, 'c' }; // "abéc"
    try std.testing.expectEqualStrings("ab", utf8Prefix(&s, 3)); // é would split
    try std.testing.expectEqualStrings("ab\xC3\xA9", utf8Prefix(&s, 4));
}

test "telemetry dupDetail never yields invalid UTF-8" {
    var t: Telemetry = .{
        .io = undefined, // dupDetail only touches gpa
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = undefined,
        .start_unix_ms = 0,
    };
    // The 200-byte cap lands mid-codepoint: 199 ASCII bytes + 2-byte 'é'.
    var buf: [201]u8 = undefined;
    @memset(buf[0..199], 'a');
    buf[199] = 0xC3;
    buf[200] = 0xA9;
    const cut = t.dupDetail(&buf);
    defer std.testing.allocator.free(cut);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqual(@as(usize, 199), cut.len); // split lead byte dropped
    // Raw invalid bytes mid-string (unparseable provider response) degrade
    // to ASCII instead of corrupting the OTLP payload.
    const garbage = t.dupDetail("ok\xff\xfe more text here");
    defer std.testing.allocator.free(garbage);
    try std.testing.expect(std.unicode.utf8ValidateSlice(garbage));
    try std.testing.expect(std.mem.startsWith(u8, garbage, "ok??"));
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

test "imageMediaType from extension" {
    try std.testing.expectEqualStrings("image/png", imageMediaType("shot.png"));
    try std.testing.expectEqualStrings("image/jpeg", imageMediaType("p.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", imageMediaType("p.jpeg"));
    try std.testing.expectEqualStrings("image/gif", imageMediaType("a.gif"));
    try std.testing.expectEqualStrings("image/webp", imageMediaType("a.webp"));
    try std.testing.expectEqualStrings("image/png", imageMediaType("noext")); // default
}

test "contextFor known model and default fallback" {
    try std.testing.expectEqual(@as(u64, 262_144), contextFor("kimi", "kimi-k2.6"));
    try std.testing.expectEqual(@as(u64, default_context), contextFor("nope", "unknown-xyz"));
}

test "resolveModelName exact match and miss" {
    const keys = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expect(resolveModelName(keys, "gpt-5.5") != null); // exact name
    try std.testing.expect(resolveModelName(keys, "totally-unknown-zzz") == null);
}

test "visionCapable allowlist" {
    const mk = struct {
        fn p(model: []const u8) Provider {
            return .{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .model = model, .context = 0, .api_key = "", .account = "" };
        }
    }.p;
    try std.testing.expect(visionCapable(mk("claude-opus-4-8")));
    try std.testing.expect(visionCapable(mk("gpt-5.5")));
    try std.testing.expect(!visionCapable(mk("deepseek-v4-pro")));
    try std.testing.expect(!visionCapable(mk("kimi-k2.6")));
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

test "signScore: matches the Python SDK HMAC for a known key" {
    // hmac.new(b"test-key", msg, sha256) over the canonical tuple above.
    const saved = g_score_key;
    defer g_score_key = saved;
    g_score_key = "test-key";
    const sig = signScore("a1b2", "c3d4", 0.5, "run1", "replay-v1", "art", "evalhash");
    try std.testing.expectEqualStrings(
        "32023137ff08de5962f81a0d0f7229bc5c0fb26b8c3399b8af54138fb47c6138",
        &sig,
    );
    g_score_key = null;
    const unsigned = signScore("a1b2", "c3d4", 0.5, "run1", "replay-v1", "art", "evalhash");
    try std.testing.expectEqual(@as(u8, 0), unsigned[0]); // no key -> zeroed sig
}

test "blankText: webfetch empty-output heuristic" {
    try std.testing.expect(blankText(""));
    try std.testing.expect(blankText("   \n\n\t\r\n  \n")); // SPA: pages of blank lines
    try std.testing.expect(blankText("ok\n")); // a couple of stray chars is still no content
    try std.testing.expect(!blankText("# Example Domain\n\nThis domain is for use..."));
}

test "trustedMcpEntry: only the exact muonry shape skips the consent gate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    try std.testing.expect(trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\",\"args\":[\"--mcp\"]}")));
    try std.testing.expect(trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\"}")));
    try std.testing.expect(trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\",\"args\":[]}")));
    try std.testing.expect(!trustedMcpEntry("muonry", parse(a, "{\"command\":\"evil\"}")));
    try std.testing.expect(!trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\",\"args\":[\"--mcp\",\"--evil\"]}")));
    try std.testing.expect(!trustedMcpEntry("muonry", parse(a, "{\"command\":\"./muonry\",\"args\":[\"--mcp\"]}")));
    try std.testing.expect(!trustedMcpEntry("other", parse(a, "{\"command\":\"muonry\"}")));
}

test "muonry trust: whole suite skips the gate; plan mode only frees read-only calls" {
    try std.testing.expect(muonryTrusted("mcp__muonry__read"));
    try std.testing.expect(muonryTrusted("mcp__muonry__edit"));
    try std.testing.expect(muonryTrusted("mcp__muonry__batch"));
    try std.testing.expect(!muonryTrusted("mcp__other__read"));
    try std.testing.expect(!muonryTrusted("read_file"));
}

test "muonryReadOnly: the plan-mode classifier mirrors readOnlyHint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    const none = Value{ .null = {} };
    try std.testing.expect(muonryReadOnly("mcp__muonry__read", none));
    try std.testing.expect(muonryReadOnly("mcp__muonry__search", none));
    try std.testing.expect(muonryReadOnly("mcp__muonry__faster_search", none));
    try std.testing.expect(!muonryReadOnly("mcp__muonry__edit", none));
    try std.testing.expect(!muonryReadOnly("mcp__muonry__patch", none));
    try std.testing.expect(!muonryReadOnly("mcp__muonry__memo", none));
    try std.testing.expect(!muonryReadOnly("mcp__other__read", none)); // only the trusted server
    try std.testing.expect(!muonryReadOnly("read_file", none));
    // batch: read-only iff every op is
    try std.testing.expect(muonryReadOnly("mcp__muonry__batch", parse(a,
        \\{"ops":[{"tool":"read","args":{}},{"tool":"search","args":{}}]}
    )));
    try std.testing.expect(!muonryReadOnly("mcp__muonry__batch", parse(a,
        \\{"ops":[{"tool":"read","args":{}},{"tool":"edit","args":{}}]}
    )));
    try std.testing.expect(!muonryReadOnly("mcp__muonry__batch", parse(a, "{\"ops\":[]}")));
    try std.testing.expect(!muonryReadOnly("mcp__muonry__batch", parse(a, "{}")));
}

test "billingFor: subscription, priced, unpriced classification" {
    try std.testing.expectEqual(Billing.sub, billingFor("codex", "gpt-5.5")); // priced model, but flat-rate login
    try std.testing.expectEqual(Billing.priced, billingFor("openai", "gpt-5.5"));
    try std.testing.expectEqual(Billing.priced, billingFor("anthropic", "claude-sonnet-4-6"));
    try std.testing.expectEqual(Billing.unpriced, billingFor("openai", "mystery-model"));
}

test "usdFor: per-million math and negative clamping" {
    const p = priceFor("gpt-5.5").?; // $5 in / $30 out / $0.5 cache per 1M
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), usdFor(p, 1_000_000, 0, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), usdFor(p, 0, 1_000_000, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), usdFor(p, 0, 0, 100_000), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), usdFor(p, -42, -1, 0), 1e-9); // clamped
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

test { // pull in tests from imported modules (mcp.zig)
    _ = mcp;
}

test "Hook.matches: wildcard, pipe lists, exact" {
    const star = Hook{ .match = "*", .command = "", .timeout_ms = 0 };
    try std.testing.expect(star.matches("bash"));
    try std.testing.expect(star.matches("anything"));
    const multi = Hook{ .match = "bash|edit_file | write_file", .command = "", .timeout_ms = 0 };
    try std.testing.expect(multi.matches("bash"));
    try std.testing.expect(multi.matches("edit_file"));
    try std.testing.expect(multi.matches("write_file")); // spaces trimmed
    try std.testing.expect(!multi.matches("read_file"));
    try std.testing.expect(!multi.matches("bas")); // no prefix matching
}

test "parseHookList: defaults, malformed entries skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"command": "./guard.sh"},
        \\ {"match": "bash", "command": "lint", "timeout_ms": 500},
        \\ {"match": "no-command-key"},
        \\ "not-an-object",
        \\ {"command": ""}]
    , .{});
    const hooks = parseHookList(a, v);
    try std.testing.expectEqual(@as(usize, 2), hooks.len);
    try std.testing.expectEqualStrings("*", hooks[0].match); // default match
    try std.testing.expectEqual(@as(u64, 10_000), hooks[0].timeout_ms); // default timeout
    try std.testing.expectEqualStrings("bash", hooks[1].match);
    try std.testing.expectEqual(@as(u64, 500), hooks[1].timeout_ms);
}
