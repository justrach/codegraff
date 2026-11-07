//! Stall-budget arithmetic for the streaming watchdogs (#56). Policy choices
//! are testable without Io or sleeping through real stalls; streamPolicy is
//! the boundary that reads configured/env overrides. Lives beside http.zig
//! like http_headers.zig; http.zig owns the watchdog loops and
//! the configured budget, this owns the decision they make each tick.

const std = @import("std");

/// Once tokens are flowing, a stream gets this fraction of the pre-first-token
/// budget: bytes were arriving and stopped, which is a dead socket rather than
/// a model thinking, and the next token was milliseconds away. A fraction of
/// the configured budget rather than a second env knob, so
/// GRAFF_STREAM_STALL_SECS still scales BOTH regimes for a slow provider.
const idle_divisor: u64 = 4;

/// ...but never below this, so a small GRAFF_STREAM_STALL_SECS cannot shrink
/// the between-lines budget to a couple of seconds and start killing healthy
/// streams. Clamped to the configured budget, which always wins when smaller.
/// Mutable ONLY so a test can exercise the two regimes apart without sleeping
/// through a real 15s floor; production never writes it. A test that shrinks it
/// must restore it (process-wide, shared with every later test in the binary).
pub var idle_floor_ms: u64 = 15 * 1000;

/// How long a stream read may sit silent before the watchdog calls it dead.
/// `base_ms` is the configured budget (http.stream_stall_ms); `tokens_flowing`
/// says whether THIS stream has already emitted tokens.
/// Pre-first-token ceiling. The full budget used to stand before the first
/// byte "because a reasoning model can be silent for minutes" — but with
/// thinking STREAMED (kimi keep:"all", codex reasoning deltas) a healthy
/// request emits its first token in seconds, and a totally silent socket is
/// dead, not thinking: the k3 benchmark watched a stalled first call burn
/// 127s before the watchdog retried, after which it completed in 6s.
/// GRAFF_STREAM_STALL_SECS (or GRAFF_STREAM_HEAD_STALL_SECS) still overrides
/// for a provider that genuinely buffers in silence. Mutable for tests, like
/// idle_floor_ms; production writes it only from session_settings.
pub var head_ceiling_ms: u64 = 45 * 1000;

/// Per-request reconnect state the SSE and WS readers consult (#680). Owned by
/// the Agent, reset at the top of every request(), advanced by each stall
/// reconnect.
pub const State = struct {
    /// Stall reconnects this request has already made. Each one widens the
    /// between-lines budget (budgetMsWidened): a stream that stalled at the
    /// same point twice is a model pausing mid-response — composing a large
    /// tool call, say — not a dead socket, and re-sending the identical
    /// request into the identical budget only re-pays the generation.
    widen: u8 = 0,
    /// The budget (ms) of the read that last tripped, so the turn-ending
    /// message reports what was actually waited rather than the configured
    /// total. 0 until a watchdog fires.
    tripped_ms: u64 = 0,
};

pub fn budgetMs(base_ms: u64, tokens_flowing: bool) u64 {
    return budgetMsWidened(base_ms, tokens_flowing, 0);
}

/// budgetMs with the reconnect ladder applied (#680): `widen` is how many
/// stall reconnects this request has made. The between-lines divisor halves
/// each time — a quarter, a half, then the full configured budget — and the
/// floor and the configured total still bound it. The pre-first-token
/// ceiling is NOT widened: a socket that never answered is dead on arrival
/// (#401), and that regime has its own retry ladder (HungRequest).
pub fn budgetMsWidened(base_ms: u64, tokens_flowing: bool, widen: u8) u64 {
    if (!tokens_flowing) return @min(base_ms, head_ceiling_ms);
    const divisor = idle_divisor >> @intCast(@min(widen, 2));
    return @min(base_ms, @max(idle_floor_ms, base_ms / divisor));
}

/// Inter-frame wait. No bytes yet is a dead socket (head ceiling). Protocol
/// frames without prose is a reasoning model (full `base_ms` — gpt-5.6-sol
/// high/max often encrypts thinking and emits nothing for well over 45s).
/// Visible prose tightens to the between-lines budget, widened per reconnect.
pub fn interFrameBudgetMs(base_ms: u64, saw_protocol: bool, tokens_flowing: bool, widen: u8) u64 {
    if (tokens_flowing) return budgetMsWidened(base_ms, true, widen);
    if (saw_protocol) return base_ms;
    return budgetMsWidened(base_ms, false, widen);
}

/// Request-local policy: buffered Gemini-4 generations may be silent after
/// HTTP headers, even before their first SSE frame. Keep connect/HTTP-head
/// watchdogs unchanged, and keep the usual fast budget while prose is open.
/// This cannot extend a gateway's own upstream/idle deadline or send SSE
/// keepalives on the server's behalf.
pub const StreamPolicy = struct {
    silence_ms: u64,
    initial_ms: u64,
    prose_base_ms: u64,

    pub fn init(model: []const u8, base_ms: u64, head_ms: u64, stream_override: bool, head_override: bool) StreamPolicy {
        // Non-default configured values also win for embedded callers/tests
        // that set budgets without going through the process environment.
        const explicit_stream = stream_override or base_ms != 120 * 1000;
        const buffered = bufferedToolModel(model) and !explicit_stream;
        const silence = if (buffered) @max(base_ms, 20 * 60 * 1000) else base_ms;
        const initial = if (buffered and !head_override and head_ms == 45 * 1000) silence else @min(silence, head_ms);
        return .{ .silence_ms = silence, .initial_ms = initial, .prose_base_ms = base_ms };
    }

    pub fn initForEndpoint(model: []const u8, url: []const u8, base_ms: u64, head_ms: u64, stream_override: bool, head_override: bool) StreamPolicy {
        var policy = init(model, base_ms, head_ms, stream_override, head_override);
        if (localEndpoint(url) and !stream_override and base_ms == 120_000) {
            policy.silence_ms = @max(policy.silence_ms, local_silence_ms);
            policy.prose_base_ms = local_silence_ms;
            if (!head_override and head_ms == 45_000) policy.initial_ms = policy.silence_ms;
        }
        return policy;
    }

    pub fn interFrameBudgetMs(self: StreamPolicy, saw_protocol: bool, prose_open: bool, widen: u8) u64 {
        if (prose_open) return budgetMsWidened(self.prose_base_ms, true, widen);
        return if (saw_protocol) self.silence_ms else self.initial_ms;
    }
};

/// Compute once per stream, never mutate shared watchdog budgets. Inspect the
/// explicit knobs as well as their configured values: an override equal to
/// the shipped default is still an override. Validation matches settings.
pub fn streamPolicy(model: []const u8, url: []const u8, base_ms: u64) StreamPolicy {
    return StreamPolicy.initForEndpoint(model, url, base_ms, head_ceiling_ms, validSecondsEnv("GRAFF_STREAM_STALL_SECS"), validSecondsEnv("GRAFF_STREAM_HEAD_STALL_SECS"));
}

const local_silence_ms: u64 = 10 * 60 * 1000;

/// Match the actual URL host, never a model name, path or hostname substring.
fn localEndpoint(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    const host = switch (uri.host orelse return false) {
        .raw, .percent_encoded => |value| value,
    };
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1");
}

/// Local inference may buffer HTTP headers until prefill/generation completes.
/// Preserve shortened fixture deadlines and explicit streaming overrides.
pub fn headBudgetMs(url: []const u8, configured_ms: u64, policy: StreamPolicy) u64 {
    return if (localEndpoint(url) and configured_ms == 30_000) policy.initial_ms else configured_ms;
}

pub fn postBudgetMs(url: []const u8, configured_ms: u64) u64 {
    return localBudgetMs(url, configured_ms, 300_000, validSecondsEnv("GRAFF_POST_DEADLINE_SECS"));
}

fn localBudgetMs(url: []const u8, configured_ms: u64, default_ms: u64, explicit: bool) u64 {
    return if (!explicit and configured_ms == default_ms and localEndpoint(url)) @max(configured_ms, local_silence_ms) else configured_ms;
}

fn validSecondsEnv(name: [*:0]const u8) bool {
    const raw = std.c.getenv(name) orelse return false;
    return validSeconds(std.mem.span(raw));
}

fn validSeconds(raw: []const u8) bool {
    const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t"), 10) catch return false;
    return seconds > 0;
}

fn bufferedToolModel(qualified_model: []const u8) bool {
    const model = if (std.mem.lastIndexOfScalar(u8, qualified_model, '/')) |slash| qualified_model[slash + 1 ..] else qualified_model;
    const prefix = "gemini-4";
    if (model.len < prefix.len or !std.ascii.eqlIgnoreCase(model[0..prefix.len], prefix)) return false;
    if (model.len == prefix.len) return true;
    // Bound the family match: gemini-40 and gemini-4ish are not Gemini-4.
    return switch (model[prefix.len]) {
        '-', '.', ':' => true,
        else => false,
    };
}

/// True once a silent read has outlasted its budget — the watchdog loop's only
/// decision, split out so it can be exercised at the boundary in a unit test.
pub fn expired(waited_ms: u64, base_ms: u64, tokens_flowing: bool) bool {
    return waited_ms >= budgetMs(base_ms, tokens_flowing);
}

test "local inference deadlines follow loopback endpoints and preserve explicit budgets" {
    for ([_][]const u8{ "http://127.0.0.1:8080/v1/chat/completions", "http://localhost:1234/v1/chat/completions", "https://LOCALHOST/v1", "http://[::1]:8080/v1" }) |url| {
        const policy = StreamPolicy.initForEndpoint("custom-local-model", url, 120_000, 45_000, false, false);
        try std.testing.expectEqual(@as(u64, 600_000), policy.interFrameBudgetMs(false, false, 0));
        try std.testing.expectEqual(@as(u64, 600_000), policy.interFrameBudgetMs(true, false, 0));
        try std.testing.expectEqual(@as(u64, 150_000), policy.interFrameBudgetMs(true, true, 0));
        try std.testing.expectEqual(@as(u64, 600_000), headBudgetMs(url, 30_000, policy));
        try std.testing.expectEqual(@as(u64, 123), headBudgetMs(url, 123, policy));
        try std.testing.expectEqual(@as(u64, 600_000), localBudgetMs(url, 300_000, 300_000, false));
        try std.testing.expectEqual(@as(u64, 300_000), localBudgetMs(url, 300_000, 300_000, true));
        try std.testing.expectEqual(@as(u64, 100), localBudgetMs(url, 100, 300_000, false));
        const stream = StreamPolicy.initForEndpoint("custom", url, 120_000, 120_000, true, false);
        try std.testing.expectEqual(@as(u64, 120_000), stream.initial_ms);
        try std.testing.expectEqual(@as(u64, 30_000), stream.interFrameBudgetMs(true, true, 0));
        const head = StreamPolicy.initForEndpoint("custom", url, 120_000, 45_000, false, true);
        try std.testing.expectEqual(@as(u64, 45_000), headBudgetMs(url, 30_000, head));
        try std.testing.expectEqual(@as(u64, 600_000), head.silence_ms);
    }
}

test "local inference deadlines never extend remote hosts or leak between requests" {
    for ([_][]const u8{ "https://api.example.com/v1", "https://localhost.example.com/v1", "https://127.0.0.1.example.com/v1", "https://example.com/localhost", "https://localhost@example.com/v1", "not a url" }) |url| {
        const policy = StreamPolicy.initForEndpoint("mlx-localhost", url, 120_000, 45_000, false, false);
        try std.testing.expectEqual(@as(u64, 45_000), policy.initial_ms);
        try std.testing.expectEqual(@as(u64, 120_000), policy.silence_ms);
        try std.testing.expectEqual(@as(u64, 30_000), policy.interFrameBudgetMs(true, true, 0));
        try std.testing.expectEqual(@as(u64, 30_000), headBudgetMs(url, 30_000, policy));
        try std.testing.expectEqual(@as(u64, 300_000), localBudgetMs(url, 300_000, 300_000, false));
    }
    const local = StreamPolicy.initForEndpoint("custom", "http://localhost:8080/v1", 120_000, 45_000, false, false);
    const remote = StreamPolicy.init("custom", 120_000, 45_000, false, false);
    try std.testing.expectEqual(@as(u64, 600_000), local.silence_ms);
    try std.testing.expectEqual(@as(u64, 120_000), remote.silence_ms);
}

test "stream policy: Gemini-4 model ids allow buffered tool silence, not slow prose" {
    const models = [_][]const u8{
        "gemini-4",                         "gemini-4-argon",             "gemini-4.0-pro", "google/gemini-4-argon",
        "openrouter/google/gemini-4-argon", "google/gemini-4-argon:free", "GEMINI-4-ARGON",
    };
    for (models) |model| {
        const policy = StreamPolicy.init(model, 120_000, 45_000, false, false);
        try std.testing.expectEqual(@as(u64, 1_200_000), policy.interFrameBudgetMs(false, false, 0));
        try std.testing.expectEqual(@as(u64, 1_200_000), policy.interFrameBudgetMs(true, false, 0));
        // A multi-minute buffered function call fits; a dead mid-answer
        // socket still gets the usual 30s / 60s / 120s reconnect ladder.
        try std.testing.expect(10 * 60 * 1000 < policy.interFrameBudgetMs(true, false, 0));
        try std.testing.expectEqual(@as(u64, 30_000), policy.interFrameBudgetMs(true, true, 0));
        try std.testing.expectEqual(@as(u64, 60_000), policy.interFrameBudgetMs(true, true, 1));
        try std.testing.expectEqual(@as(u64, 120_000), policy.interFrameBudgetMs(true, true, 2));
    }
}

test "stream policy: other models retain fast first-frame and prose defaults" {
    const models = [_][]const u8{
        "",                                  "gpt-6.1-sol", "claude-opus",        "gemini-3.7-flash", "google/gemini-3.7-pro",
        "openrouter/google/gemini-40-argon", "gemini-4ish", "not-gemini-4-argon", "google/",
    };
    for (models) |model| {
        const policy = StreamPolicy.init(model, 120_000, head_ceiling_ms, false, false);
        for ([_]bool{ false, true }) |protocol| {
            for ([_]bool{ false, true }) |prose| {
                for ([_]u8{ 0, 1, 2, 7 }) |widen| {
                    try std.testing.expectEqual(interFrameBudgetMs(120_000, protocol, prose, widen), policy.interFrameBudgetMs(protocol, prose, widen));
                }
            }
        }
    }
}

test "stream policy: explicit stream overrides win even at the shipped default" {
    for ([_]u64{ 5_000, 120_000, 600_000, 1_800_000, 86_400_000 }) |base| {
        const policy = StreamPolicy.init("openrouter/google/gemini-4-argon", base, base, true, false);
        try std.testing.expectEqual(base, policy.interFrameBudgetMs(false, false, 0));
        try std.testing.expectEqual(base, policy.interFrameBudgetMs(true, false, 0));
        try std.testing.expectEqual(budgetMsWidened(base, true, 1), policy.interFrameBudgetMs(true, true, 1));
    }
    // Embedded callers and shortened stall fixtures remain bounded too.
    const configured = StreamPolicy.init("gemini-4-argon", 1_200, 45_000, false, false);
    try std.testing.expectEqual(@as(u64, 1_200), configured.interFrameBudgetMs(false, false, 0));
}

test "stream policy: explicit HEAD overrides only the first SSE frame, not HTTP connect" {
    for ([_]u64{ 9_000, 45_000, 600_000, 1_800_000 }) |head| {
        const policy = StreamPolicy.init("google/gemini-4-argon", 120_000, head, false, true);
        try std.testing.expectEqual(@min(head, @as(u64, 1_200_000)), policy.interFrameBudgetMs(false, false, 0));
        try std.testing.expectEqual(@as(u64, 1_200_000), policy.interFrameBudgetMs(true, false, 0));
        try std.testing.expectEqual(@as(u64, 30_000), policy.interFrameBudgetMs(true, true, 0));
    }
    const both = StreamPolicy.init("gemini-4-argon", 120_000, 9_000, true, true);
    try std.testing.expectEqual(@as(u64, 9_000), both.interFrameBudgetMs(false, false, 0));
    try std.testing.expectEqual(@as(u64, 120_000), both.interFrameBudgetMs(true, false, 0));
}

test "stream policy: interleaved requests never leak the buffered allowance" {
    const saved_head = head_ceiling_ms;
    const saved_floor = idle_floor_ms;
    const gemini = StreamPolicy.init("openrouter/google/gemini-4-argon", 120_000, 45_000, false, false);
    const other = StreamPolicy.init("gpt-6.1-sol", 120_000, 45_000, false, false);
    const gemini_override = StreamPolicy.init("gemini-4-argon", 120_000, 120_000, true, false);
    try std.testing.expectEqual(@as(u64, 1_200_000), gemini.interFrameBudgetMs(true, false, 0));
    try std.testing.expectEqual(@as(u64, 45_000), other.interFrameBudgetMs(false, false, 0));
    try std.testing.expectEqual(@as(u64, 120_000), other.interFrameBudgetMs(true, false, 0));
    try std.testing.expectEqual(@as(u64, 120_000), gemini_override.interFrameBudgetMs(true, false, 0));
    try std.testing.expectEqual(@as(u64, 1_200_000), gemini.interFrameBudgetMs(false, false, 0));
    try std.testing.expectEqual(saved_head, head_ceiling_ms);
    try std.testing.expectEqual(saved_floor, idle_floor_ms);
}

test "stream policy: only valid positive seconds suppress model defaults" {
    for ([_][]const u8{ "", "0", " 0 ", "-1", "oops", "1.5", "18446744073709551616" }) |raw| {
        try std.testing.expect(!validSeconds(raw));
        const policy = StreamPolicy.init("gemini-4-argon", 120_000, 45_000, validSeconds(raw), validSeconds(raw));
        try std.testing.expectEqual(@as(u64, 1_200_000), policy.interFrameBudgetMs(false, false, 0));
    }
    for ([_][]const u8{ "1", "120", " \t120\t", "86401", "18446744073709551615" }) |raw| try std.testing.expect(validSeconds(raw));
}

test "stall budget (#56): between-lines silence trips sooner than a pre-first-token pause" {
    const base: u64 = 120 * 1000; // the shipped http.stream_stall_ms default

    // Before the first token the head ceiling applies: with thinking streamed,
    // a silent socket past it is dead, not reasoning.
    try std.testing.expectEqual(head_ceiling_ms, budgetMs(base, false));
    try std.testing.expect(!expired(head_ceiling_ms - 1, base, false));
    try std.testing.expect(expired(head_ceiling_ms, base, false));

    // Tokens already flowed: a quarter of it (30s), so a dead stream is given
    // up on 4x sooner instead of holding the turn for another 90s of silence.
    try std.testing.expectEqual(@as(u64, 30 * 1000), budgetMs(base, true));
    try std.testing.expect(!expired(30 * 1000 - 1, base, true));
    try std.testing.expect(expired(30 * 1000, base, true));
    // The whole point of the split: at 30s of silence the between-lines regime
    // is done and the pre-first-token one is still waiting.
    try std.testing.expect(expired(30 * 1000, base, true) and !expired(30 * 1000, base, false));

    // GRAFF_STREAM_STALL_SECS (session_settings writes http.stream_stall_ms,
    // which arrives here as base_ms) still wins BOTH regimes when set high —
    // simulated by raising the ceiling the way the env knob does.
    const saved_ceiling = head_ceiling_ms;
    head_ceiling_ms = 600 * 1000;
    defer head_ceiling_ms = saved_ceiling;
    try std.testing.expectEqual(@as(u64, 600 * 1000), budgetMs(600 * 1000, false));
    try std.testing.expectEqual(@as(u64, 150 * 1000), budgetMs(600 * 1000, true));

    // A short override floors the between-lines budget instead of shrinking it
    // to seconds, and never outlasts the configured total.
    try std.testing.expectEqual(idle_floor_ms, budgetMs(20 * 1000, true));
    try std.testing.expectEqual(@as(u64, 5 * 1000), budgetMs(5 * 1000, true));
    try std.testing.expect(expired(5 * 1000, 5 * 1000, true));
}

test "stall budget: protocol-seen thinking keeps the full wait, not the 45s ceiling" {
    const base: u64 = 120 * 1000;
    try std.testing.expectEqual(head_ceiling_ms, interFrameBudgetMs(base, false, false, 0));
    try std.testing.expectEqual(base, interFrameBudgetMs(base, true, false, 0));
    try std.testing.expectEqual(@as(u64, 30 * 1000), interFrameBudgetMs(base, true, true, 0));
}

// The #680 signature: reasoning streamed, one line of prose, then >30s of
// silence while the model composed a large tool call. The old ladder armed the
// same 30s on every reconnect, so all three attempts died at the same point
// and the turn ended claiming "no data for 120s".
test "stall budget (#680): each reconnect widens the between-lines wait — a quarter, a half, then all of it" {
    const base: u64 = 120 * 1000;
    try std.testing.expectEqual(@as(u64, 30 * 1000), budgetMsWidened(base, true, 0));
    try std.testing.expectEqual(@as(u64, 60 * 1000), budgetMsWidened(base, true, 1));
    try std.testing.expectEqual(base, budgetMsWidened(base, true, 2));
    try std.testing.expectEqual(base, budgetMsWidened(base, true, 7)); // past the ladder: still the configured total
    // Through the reader's entry point, and only for the prose regime.
    try std.testing.expectEqual(@as(u64, 60 * 1000), interFrameBudgetMs(base, true, true, 1));
    try std.testing.expectEqual(base, interFrameBudgetMs(base, true, false, 1)); // protocol-only: already the full wait
    try std.testing.expectEqual(head_ceiling_ms, interFrameBudgetMs(base, false, false, 2)); // dead on arrival is not widened
    // The floor and the total still bound a short GRAFF_STREAM_STALL_SECS.
    try std.testing.expectEqual(idle_floor_ms, budgetMsWidened(20 * 1000, true, 1)); // 10s < floor
    try std.testing.expectEqual(@as(u64, 20 * 1000), budgetMsWidened(20 * 1000, true, 2));
    try std.testing.expectEqual(@as(u64, 5 * 1000), budgetMsWidened(5 * 1000, true, 1));
}

// GPT-5.6 can pause generation for several seconds mid-stream while a safety
// classifier reviews the output (OpenAI's "Using GPT-5.6" guide). With prose
// already flowing the between-lines budget is the tight regime, so pin that a
// pause of that size never trips it: 30s on the shipped default, and the 15s
// floor still holds it when GRAFF_STREAM_STALL_SECS is set low.
test "stall budget: a several-second GPT-5.6 mid-stream safety pause stays inside the tightened budget" {
    const pause_ms: u64 = 10 * 1000; // "several seconds", with margin
    const base: u64 = 120 * 1000;
    try std.testing.expect(!expired(pause_ms, base, true));
    try std.testing.expect(pause_ms < interFrameBudgetMs(base, true, true, 0));
    try std.testing.expect(pause_ms < interFrameBudgetMs(base, true, false, 0)); // reasoning-only phase: full budget
    try std.testing.expect(pause_ms < budgetMs(20 * 1000, true)); // short override: the floor covers it
    try std.testing.expect(idle_floor_ms > pause_ms);
}
