//! Context-overflow classification and the recovery it drives (#193 arc, #414).
//!
//! Three questions, asked in this order:
//!   1. is this failure something OTHER than an over-window input — throttling,
//!      a billing cap? A guard hit wins outright, so the retry/Retry-After
//!      ladder is never shadowed by a compaction that cannot help.
//!   2. does the failure's structured code or wording name an over-window input?
//!   3. did the provider ACCEPT the oversized input and admit it only in its own
//!      usage numbers — HTTP 200 with nothing generated — rather than in an error?
//!
//! (1) and (2) are `isContextOverflow`; (3) is `classifyCompletion`. The recovery
//! all three feed (pin the meter to the window, emergency-trim, retry the turn
//! once) is `applyOverflowRecovery`, shared by every wire format.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");
const usageInt = @import("agent_context.zig").usageInt;

/// Non-overflow guards, tested BEFORE every overflow pattern and against both
/// the message and the structured code.
///
/// The motivating case is Bedrock, which formats throttling as
/// "ThrottlingException: Too many tokens, please wait before trying again." —
/// a 429 whose wording collides head-on with the generic "too many tokens"
/// overflow fallback below. Classifying that as overflow throws away real
/// conversation to fix a problem compaction cannot fix, AND shadows the
/// Retry-After backoff that would have worked.
///
/// Deliberately scoped to throttling / quota — the family whose remedy is
/// "wait", not "send less". Broader guards (a bare "overloaded", a generic
/// "server_error") were considered and rejected: a guard that swallows a REAL
/// overflow wedges the session forever, which is the #193 symptom and strictly
/// worse than one wasted compaction.
const non_overflow_needles = [_][]const u8{
    "throttlingexception", // bedrock: "ThrottlingException: Too many tokens, ..."
    "throttling error", // bedrock, formatBedrockError's human-readable prefix
    "throttled",
    "rate limit", // "rate limit exceeded", "Rate limit reached", "rate limited (429)"
    "rate_limit", // structured codes: rate_limit_exceeded / rate_limit_error
    "ratelimit",
    "too many requests", // generic HTTP 429 phrasing
    "tokens per minute", // anthropic org cap: "rate limit of 40000 input tokens per minute"
    "requests per minute",
    "please wait before trying again", // bedrock's throttle tail, verbatim
    "quota", // insufficient_quota / "exceeded your current quota" — isQuotaExceeded owns it
    "service unavailable",
};

/// Structured error codes that mean "input over the window" on their own (#203),
/// matched exactly so a local or non-English provider recovers even when its
/// message text is unfamiliar.
const overflow_codes = [_][]const u8{
    "context_length_exceeded", // openai
    "context_window_exceeded", // openai / responses
    "model_context_window_exceeded", // z.ai
    "request_too_large", // anthropic 413 (byte size, not token count)
};

/// Provider phrasings for "input over the window", matched case-insensitively —
/// the same rejection arrives Title-Cased from some gateways and lower-cased
/// from others, and a case-sensitive miss wedges the session.
const overflow_needles = [_][]const u8{
    // #193/#203, unchanged: the shapes graff already recovered from.
    "context window", // codex/responses: "exceeds the context window"
    "context length", // openai: "maximum context length is N tokens"; lmstudio
    "context_length_exceeded", // openai error code echoed into the message
    "context limit", // anthropic: "input length and max_tokens exceed context limit"
    "prompt is too long", // anthropic: "prompt is too long: N tokens > M maximum"
    "maximum context", // defensive: "maximum context ... exceeded"
    // #414: providers graff ships that phrase it differently. Each one is a
    // rejection the old table let die as a plain api error.
    "context_window_exceeded",
    "request_too_large", // anthropic 413
    "input is too long for requested model", // bedrock
    "input token count", // google: "The input token count (N) exceeds the maximum ..."
    "prompt token count", // github copilot: "prompt token count of N exceeds the limit of M"
    "maximum prompt length", // xai: "This model's maximum prompt length is N ..."
    "reduce the length of the messages", // groq
    "exceeds the available context size", // llama.cpp server
    "exceeded model token limit", // kimi for coding
    "too large for model with", // mistral: "... too large for model with N maximum context length"
    "prompt too long", // ollama: "prompt too long; exceeded max context length"
    // Generic fallbacks. These are the reason the guard list above exists: they
    // are broad enough to catch an unknown provider and broad enough to collide
    // with throttling, so they are only ever reached after the guards decline.
    "too many tokens",
    "token limit exceeded",
};

/// True if `msg`/`code` is a NON-overflow condition — throttling or a billing
/// cap — whose remedy is waiting, not compacting.
pub fn isNonOverflow(msg: []const u8, code: ?[]const u8) bool {
    for (non_overflow_needles) |n| {
        if (util.indexOfIgnoreCase(msg, n) != null) return true;
        if (code) |c| if (util.indexOfIgnoreCase(c, n) != null) return true;
    }
    return false;
}

/// True if `msg` is a provider's "input is over the context window" rejection,
/// across wire formats: codex/responses ("exceeds the context window"), openai
/// ("maximum context length", "context_length_exceeded"), anthropic ("prompt is
/// too long", "exceed context limit"), plus the #414 table above. Drives the
/// in-turn emergency-trim + retry recovery symmetrically for every provider
/// (#193) — before it, only the codex path recovered and anthropic/openai died
/// on an over-window turn.
pub fn isContextOverflow(msg: []const u8, code: ?[]const u8) bool {
    // #414: guards first, unconditionally. A throttle whose wording overlaps an
    // overflow pattern must ride the existing 429/Retry-After ladder instead.
    if (isNonOverflow(msg, code)) return false;
    if (code) |c| {
        for (overflow_codes) |k| if (std.ascii.eqlIgnoreCase(c, k)) return true;
    }
    for (overflow_needles) |n| if (util.indexOfIgnoreCase(msg, n) != null) return true;
    return false;
}

/// How the provider says it stopped, normalized across wire formats.
pub const StopKind = enum {
    normal, // end_turn / stop_sequence / stop
    length, // finish_reason "length" / stop_reason "max_tokens"
    other, // anything else, including "not reported"
};

/// One completed HTTP 200 response, reduced to the four numbers that decide
/// whether the provider silently overflowed.
pub const Completion = struct {
    /// Everything that occupied the window: prompt + cache reads + cache writes.
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    stop: StopKind = .other,
    /// Any assistant text or any tool call — i.e. the turn produced something.
    has_content: bool = false,
};

pub const Verdict = enum {
    ok,
    /// z.ai: HTTP 200, nothing generated, usage says the input already filled
    /// (or overran) the window. The provider accepted an over-window request
    /// and answered with silence instead of an error.
    silent_overflow,
    /// Xiaomi MiMo: the server truncated an oversized input to exactly fit the
    /// window, leaving no room to generate, then reported finish_reason=length
    /// with zero output. The conversation the model saw is NOT the one we sent.
    upstream_truncation,
};

/// Percent of the window the reported input must fill before a `length` stop
/// counts as upstream truncation. 99 (not 100) because a provider's own
/// tokenizer rounds a few tokens differently than its advertised window, and a
/// server that truncates-to-fit lands one or two tokens short of the wall.
pub const truncation_fill_pct: u64 = 99;

/// Classify a successful (HTTP 200) response from its own reported usage.
///
/// Conservative by construction — three independent conditions must hold before
/// `upstream_truncation` fires, so an ORDINARY max-tokens completion (the model
/// genuinely wrote until it hit its output cap) can never trip it:
///   * `output_tokens == 0` — a normal length-stop spends its whole output
///     budget, so any generated token at all disqualifies it;
///   * `has_content == false` — and it leaves that text behind;
///   * the reported input fills >= 99% of the window — a normal length-stop
///     happens at any input size, including a two-line prompt.
/// `silent_overflow` needs an empty completion too: if the input is over our
/// window figure and the model STILL answered, the window figure is wrong (a
/// stale catalog row), and trimming real history over a bad constant is the
/// more expensive mistake.
pub fn classifyCompletion(c: Completion, window: u64) Verdict {
    if (window == 0) return .ok; // unknown window — never guess
    if (c.input_tokens == 0) return .ok; // no usage reported — nothing to judge
    if (c.has_content) return .ok;
    // Checked before the plain over-window rule so the more specific diagnosis
    // wins when a truncating provider lands exactly ON the window.
    if (c.stop == .length and c.output_tokens == 0 and
        c.input_tokens >= window / 100 * truncation_fill_pct) return .upstream_truncation;
    if (c.input_tokens >= window) return .silent_overflow;
    return .ok;
}

fn stopFromString(kind: Provider.Kind, s: []const u8) StopKind {
    if (std.mem.eql(u8, s, "length") or std.mem.eql(u8, s, "max_tokens")) return .length;
    return switch (kind) {
        .anthropic => if (std.mem.eql(u8, s, "end_turn") or std.mem.eql(u8, s, "stop_sequence")) .normal else .other,
        else => if (std.mem.eql(u8, s, "stop")) .normal else .other,
    };
}

fn str(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn arr(obj: std.json.ObjectMap, name: []const u8) ?std.json.Array {
    const v = obj.get(name) orelse return null;
    return if (v == .array) v.array else null;
}

fn usageOf(root: std.json.ObjectMap) ?std.json.ObjectMap {
    const v = root.get("usage") orelse return null;
    return if (v == .object) v.object else null;
}

fn nonNegative(n: i64) u64 {
    return if (n > 0) @intCast(n) else 0;
}

/// Reduce a parsed 200 response to the numbers `classifyCompletion` needs.
/// Everything is optional: a provider that reports no usage yields
/// `input_tokens == 0`, which classifies as `.ok`.
pub fn readCompletion(kind: Provider.Kind, root: std.json.ObjectMap) Completion {
    var c: Completion = .{};
    return switch (kind) {
        // Interactions reports totals under its own names, and any step other
        // than a bare thought counts as content the turn actually produced.
        .interactions => {
            if (usageOf(root)) |u| {
                c.input_tokens = nonNegative(usageInt(u, "total_input_tokens"));
                c.output_tokens = nonNegative(usageInt(u, "total_output_tokens") +| usageInt(u, "total_thought_tokens"));
            }
            if (str(root, "status")) |s| c.stop = stopFromString(kind, s);
            if (arr(root, "steps")) |steps| for (steps.items) |st| {
                if (st != .object) continue;
                const t = str(st.object, "type") orelse continue;
                if (!std.mem.eql(u8, t, "thought")) c.has_content = true;
            };
            return c;
        },
        .anthropic => {
            if (usageOf(root)) |u| {
                c.input_tokens = nonNegative(usageInt(u, "input_tokens") +|
                    usageInt(u, "cache_read_input_tokens") +| usageInt(u, "cache_creation_input_tokens"));
                c.output_tokens = nonNegative(usageInt(u, "output_tokens"));
            }
            if (str(root, "stop_reason")) |s| c.stop = stopFromString(kind, s);
            if (arr(root, "content")) |blocks| for (blocks.items) |b| {
                if (b != .object) continue;
                const bt = str(b.object, "type") orelse continue;
                if (std.mem.eql(u8, bt, "tool_use")) c.has_content = true;
                if (std.mem.eql(u8, bt, "text")) {
                    if (str(b.object, "text")) |t| if (t.len > 0) {
                        c.has_content = true;
                    };
                }
            };
            return c;
        },
        .openai => {
            if (usageOf(root)) |u| {
                // prompt_tokens already includes cached prompt tokens.
                c.input_tokens = nonNegative(usageInt(u, "prompt_tokens"));
                c.output_tokens = nonNegative(usageInt(u, "completion_tokens"));
            }
            const choices = arr(root, "choices") orelse return c;
            if (choices.items.len == 0 or choices.items[0] != .object) return c;
            const choice = choices.items[0].object;
            if (str(choice, "finish_reason")) |s| c.stop = stopFromString(kind, s);
            const message = choice.get("message") orelse return c;
            if (message != .object) return c;
            if (str(message.object, "content")) |t| if (t.len > 0) {
                c.has_content = true;
            };
            if (arr(message.object, "tool_calls")) |tc| if (tc.items.len > 0) {
                c.has_content = true;
            };
            return c;
        },
        .responses => {
            if (usageOf(root)) |u| {
                // Responses usage.input_tokens already includes cached input.
                c.input_tokens = nonNegative(usageInt(u, "input_tokens"));
                c.output_tokens = nonNegative(usageInt(u, "output_tokens"));
            }
            // parseResponses collapses every terminal to output items + an
            // `incomplete` flag, so there is no finish_reason to read: leave
            // `stop` at .other and let only the silent-overflow rule apply.
            if (arr(root, "output")) |items| for (items.items) |item| {
                if (item != .object) continue;
                const it = str(item.object, "type") orelse continue;
                if (std.mem.eql(u8, it, "function_call") or std.mem.eql(u8, it, "custom_tool_call")) c.has_content = true;
                if (!std.mem.eql(u8, it, "message")) continue;
                const blocks = arr(item.object, "content") orelse continue;
                for (blocks.items) |b| {
                    if (b != .object) continue;
                    if (str(b.object, "text")) |t| if (t.len > 0) {
                        c.has_content = true;
                    };
                }
            };
            return c;
        },
    };
}

/// Pin the meter to the window, emergency-trim, and retry the turn once.
///
/// Pins FIRST so the between-turns compaction engages even when we cannot
/// recover here — a rejected request returns no usage to correct the lagging
/// meter (#174). Guarded by `retried` (one `context_retried` per request) so a
/// second overflow falls through instead of looping. Returns true if the caller
/// should `continue` its rebuild loop.
fn applyOverflowRecovery(self: *Agent, retried: *bool) bool {
    self.last_request_context_overflow = true;
    // Rejection proves at least the advertised window, not an exact total.
    // Preserve stronger server/local evidence already above that floor.
    const estimate = self.contextEstimate();
    self.last_context_tokens = @max(estimate.effective, self.provider.context);
    self.context_local_tokens = estimate.local;
    // compact() marks its synthetic summary request explicitly. Generic
    // in-request recovery is destructive there: the synthetic compact
    // instruction is the newest clean user turn, so emergencyTrim can discard
    // the entire real conversation and retry with only "summarize it". Let the
    // outer compactOrRecover policy handle a failed summary after compact()'s
    // errdefer removes that synthetic instruction.
    if (self.compaction_request) return false;
    if (retried.* or self.emergencyTrim() == 0) return false;
    retried.* = true;
    if (self.tracer) |tr| tr.note("context", "input over the window — emergency-trimmed and retrying the turn");
    return true;
}

/// #193 follow-up: shared in-turn context-overflow recovery for the codex
/// failure branch and the three anthropic/openai error branches (streamed error
/// event, non-streamed `{"type":"error"}` envelope, and the generic
/// apiErrorMessage path). These wire formats send the full input each rebuild,
/// so — unlike the codex branch — no closeCodexWs re-anchor is needed.
pub fn recoverContextOverflow(self: *Agent, msg: []const u8, code: ?[]const u8, retried: *bool) bool {
    if (!isContextOverflow(msg, code)) return false;
    return applyOverflowRecovery(self, retried);
}

/// #414: the provider returned HTTP 200 and no answer, and only its own usage
/// numbers say why. Runs on every successful response, after recordUsage* has
/// already banked the sample. Compaction requests are excluded: an empty
/// summary is compact()'s own escalation (#379), and recovering here would
/// trim against the synthetic instruction.
///
/// Both verdicts surface DISTINCTLY — a line, a trace note, a telemetry event —
/// rather than reaching the user as an inexplicably short answer, and both then
/// take the ordinary overflow recovery. When recovery is unavailable (already
/// retried this request, or nothing left to trim) the reason is recorded as
/// `last_api_error` so a subagent's parent and the --json error event carry it.
pub fn recoverBehavioralOverflow(self: *Agent, root: std.json.ObjectMap, retried: *bool) bool {
    if (self.compaction_request) return false;
    const c = readCompletion(self.provider.kind, root);
    const window = self.provider.context;
    const verdict = classifyCompletion(c, window);
    if (verdict == .ok) return false;
    const kind: []const u8 = if (verdict == .silent_overflow) "silent_overflow" else "upstream_truncation";
    const what: []const u8 = if (verdict == .silent_overflow)
        "returned no answer while reporting"
    else
        "truncated the input to fit the window and had no room left to answer:";
    self.say("[{s}: {s} {s} {d} input tokens against a {d}-token window — compacting and retrying (#414)]\n", .{
        kind, self.provider.id, what, c.input_tokens, window,
    }) catch {};
    if (self.tracer) |tr| tr.note("context", kind);
    if (telemetry.g_telem) |t| t.errorEvent(kind, self.provider.id);
    const recovered = applyOverflowRecovery(self, retried);
    if (!recovered) self.last_api_error = std.fmt.allocPrint(
        self.arena,
        "{s}: {s} accepted {d} input tokens against a {d}-token window and produced no output — the reply is not a real answer",
        .{ kind, self.provider.id, c.input_tokens, window },
    ) catch null;
    return recovered;
}

const ClassifyRow = struct {
    msg: []const u8,
    code: ?[]const u8 = null,
    want: bool,
    why: []const u8,
};

test "isContextOverflow (#193/#203/#414): guards beat patterns; every provider phrasing still classifies" {
    const rows = [_]ClassifyRow{
        // ---- #414 guards: real throttle/quota strings that must ride the retry ladder
        .{ .msg = "ThrottlingException: Too many tokens, please wait before trying again.", .want = false, .why = "bedrock throttle collides with the generic 'too many tokens' fallback" },
        .{ .msg = "Throttling error: Too many tokens, please wait before trying again.", .want = false, .why = "bedrock formatBedrockError prefix" },
        .{ .msg = "Rate limit reached for gpt-4o: Limit 30000 tokens per minute", .code = "rate_limit_exceeded", .want = false, .why = "openai TPM cap" },
        .{ .msg = "This request would exceed your organization's rate limit of 40000 input tokens per minute.", .want = false, .why = "anthropic org TPM cap" },
        .{ .msg = "429 too many requests", .want = false, .why = "generic 429" },
        .{ .msg = "rate limited (429): quota/billing cap — You exceeded your current quota", .want = false, .why = "graff's own quota-cap marker must not compact" },
        .{ .msg = "Service unavailable: the model is starting up", .want = false, .why = "5xx, not a window" },
        .{ .msg = "de invoerlengte is te groot", .code = "rate_limit_error", .want = false, .why = "guard applies to the structured code too" },
        // A guard must NOT swallow a real overflow that merely mentions a limit.
        .{ .msg = "prompt is too long: 219373 tokens > 200000 maximum", .code = "rate_limit_exceeded", .want = false, .why = "documented precedence: guards win outright, even over an explicit overflow phrase" },
        // ---- regression rows: everything #193/#203 already classified, unchanged
        .{ .msg = "Your input exceeds the context window of 272000 tokens", .want = true, .why = "codex/responses" },
        .{ .msg = "This model's maximum context length is 128000 tokens. However, you requested 130000", .want = true, .why = "openai" },
        .{ .msg = "context_length_exceeded", .want = true, .why = "openai code echoed into the message" },
        .{ .msg = "prompt is too long: 219373 tokens > 200000 maximum", .want = true, .why = "anthropic" },
        .{ .msg = "input length and max_tokens exceed context limit", .want = true, .why = "anthropic" },
        .{ .msg = "de invoerlengte overschrijdt het venster", .code = "context_length_exceeded", .want = true, .why = "#203 structured code, unfamiliar text" },
        .{ .msg = "", .code = "context_window_exceeded", .want = true, .why = "#203 structured code, empty text" },
        .{ .msg = "maximum context reached", .want = true, .why = "defensive needle" },
        .{ .msg = "The API Key appears to be invalid or may have expired.", .want = false, .why = "auth" },
        .{ .msg = "tool_choice is not supported", .want = false, .why = "capability" },
        .{ .msg = "rate limit exceeded", .want = false, .why = "throttle" },
        .{ .msg = "model not found", .want = false, .why = "routing" },
        .{ .msg = "some unrelated failure", .code = "rate_limit_exceeded", .want = false, .why = "unrelated code" },
        // ---- #414 provider phrasings the old six-needle table let die as api errors
        .{ .msg = "Input is too long for requested model.", .want = true, .why = "bedrock" },
        .{ .msg = "The input token count (1196265) exceeds the maximum number of tokens allowed (1048575)", .want = true, .why = "google gemini" },
        .{ .msg = "prompt token count of 141000 exceeds the limit of 128000", .want = true, .why = "github copilot" },
        .{ .msg = "This model's maximum prompt length is 131072 but the request contains 537812 tokens", .want = true, .why = "xai/grok" },
        .{ .msg = "Please reduce the length of the messages or completion.", .want = true, .why = "groq" },
        .{ .msg = "the request exceeds the available context size, try increasing it", .want = true, .why = "llama.cpp" },
        .{ .msg = "Your request exceeded model token limit: 262144 (requested: 300000)", .want = true, .why = "kimi for coding" },
        .{ .msg = "Prompt contains 40000 tokens, too large for model with 32768 maximum context length", .want = true, .why = "mistral" },
        .{ .msg = "prompt too long; exceeded max context length by 4096 tokens", .want = true, .why = "ollama" },
        .{ .msg = "tokens to keep from the initial prompt is greater than the context length", .want = true, .why = "lm studio" },
        .{ .msg = "invalid params, context window exceeds limit", .want = true, .why = "minimax" },
        .{ .msg = "413 request_too_large: Request exceeds the maximum size", .want = true, .why = "anthropic 413 byte-size overflow" },
        .{ .msg = "", .code = "model_context_window_exceeded", .want = true, .why = "z.ai non-standard code" },
        .{ .msg = "Token limit exceeded for this request", .want = true, .why = "generic fallback" },
        // Case-insensitivity: the same rejection Title-Cased by a gateway.
        .{ .msg = "PROMPT IS TOO LONG: 219373 TOKENS > 200000 MAXIMUM", .want = true, .why = "case-insensitive match" },
        .{ .msg = "Context Length Exceeded", .want = true, .why = "case-insensitive match" },
    };
    for (rows) |r| {
        const got = isContextOverflow(r.msg, r.code);
        if (got != r.want) {
            std.debug.print("row failed ({s}): msg={s} code={?s} want={} got={}\n", .{ r.why, r.msg, r.code, r.want, got });
            return error.TestUnexpectedResult;
        }
    }
}

const CompletionRow = struct {
    kind: Provider.Kind,
    body: []const u8,
    window: u64,
    want: Verdict,
    why: []const u8,
};

test "classifyCompletion (#414): the silent-200 and truncate-then-length shapes, and what must NOT trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rows = [_]CompletionRow{
        // ---- silent overflow (z.ai): HTTP 200, empty completion, usage at/over the window
        .{ .kind = .openai, .window = 128_000, .want = .silent_overflow, .why = "z.ai silent 200", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":131072,"completion_tokens":0,"total_tokens":131072}}
        },
        .{ .kind = .openai, .window = 128_000, .want = .silent_overflow, .why = "exactly AT the window still counts", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":null},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":128000,"completion_tokens":0}}
        },
        .{ .kind = .anthropic, .window = 200_000, .want = .silent_overflow, .why = "cache reads count toward the window", .body =
        \\{"stop_reason":"end_turn","content":[],
        \\ "usage":{"input_tokens":1000,"cache_read_input_tokens":199000,"output_tokens":0}}
        },
        .{ .kind = .responses, .window = 272_000, .want = .silent_overflow, .why = "reasoning-only output is not an answer", .body =
        \\{"output":[{"type":"reasoning","summary":[]}],
        \\ "usage":{"input_tokens":280000,"output_tokens":0}}
        },
        // ---- upstream truncation (MiMo): finish_reason=length, zero output, input fills the window
        .{ .kind = .openai, .window = 32_768, .want = .upstream_truncation, .why = "MiMo truncate-then-length", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"length"}],
        \\ "usage":{"prompt_tokens":32768,"completion_tokens":0,"total_tokens":32768}}
        },
        .{ .kind = .openai, .window = 32_768, .want = .upstream_truncation, .why = "99% fill: a truncating server lands a hair short", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"length"}],
        \\ "usage":{"prompt_tokens":32500,"completion_tokens":0}}
        },
        .{ .kind = .anthropic, .window = 200_000, .want = .upstream_truncation, .why = "anthropic spells the same stop max_tokens", .body =
        \\{"stop_reason":"max_tokens","content":[],
        \\ "usage":{"input_tokens":200000,"output_tokens":0}}
        },
        // ---- must NOT trip: an ORDINARY max-tokens completion
        .{ .kind = .openai, .window = 32_768, .want = .ok, .why = "normal max-tokens: real output, small input", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":"here is a very long answer that ran out of room"},"finish_reason":"length"}],
        \\ "usage":{"prompt_tokens":900,"completion_tokens":16000}}
        },
        .{ .kind = .openai, .window = 32_768, .want = .ok, .why = "normal max-tokens on a nearly-full window still generated", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":"partial answer"},"finish_reason":"length"}],
        \\ "usage":{"prompt_tokens":32700,"completion_tokens":68}}
        },
        .{ .kind = .openai, .window = 32_768, .want = .ok, .why = "length stop, zero output, but the input is nowhere near the wall", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"length"}],
        \\ "usage":{"prompt_tokens":900,"completion_tokens":0}}
        },
        // ---- must NOT trip: ordinary success, and the two "no evidence" cases
        .{ .kind = .openai, .window = 128_000, .want = .ok, .why = "an over-window figure the model ANSWERED means our window is wrong, not the history", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":131072,"completion_tokens":12}}
        },
        .{ .kind = .openai, .window = 128_000, .want = .ok, .why = "a tool call is content", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":"tool_calls"}],
        \\ "usage":{"prompt_tokens":131072,"completion_tokens":9}}
        },
        .{ .kind = .openai, .window = 128_000, .want = .ok, .why = "empty answer but the input is well under the window (a terse model, not overflow)", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":40,"completion_tokens":0}}
        },
        .{ .kind = .openai, .window = 0, .want = .ok, .why = "unknown window never guesses", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":131072,"completion_tokens":0}}
        },
        .{ .kind = .openai, .window = 128_000, .want = .ok, .why = "no usage reported: nothing to judge", .body =
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}
        },
        .{ .kind = .responses, .window = 272_000, .want = .ok, .why = "a real responses answer", .body =
        \\{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}],
        \\ "usage":{"input_tokens":280000,"output_tokens":4}}
        },
        .{ .kind = .anthropic, .window = 200_000, .want = .ok, .why = "anthropic text block is content", .body =
        \\{"stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],
        \\ "usage":{"input_tokens":210000,"output_tokens":2}}
        },
    };
    for (rows) |r| {
        const parsed = try std.json.parseFromSliceLeaky(Value, a, r.body, .{ .allocate = .alloc_always });
        const got = classifyCompletion(readCompletion(r.kind, parsed.object), r.window);
        if (got != r.want) {
            std.debug.print("row failed ({s}): want={s} got={s}\n", .{ r.why, @tagName(r.want), @tagName(got) });
            return error.TestUnexpectedResult;
        }
    }
}
