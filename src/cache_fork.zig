//! Compaction forks that keep the conversation's cached prefix (ADR 0220).
//!
//! compact() makes up to two model calls over the whole history: the note to
//! self (#391) and the handoff summary. Both used to leave the tools off, the
//! note swapped in its own system prompt, and the summary cut old tool
//! outputs to stubs. On the Anthropic API neither shared a byte of prefix with
//! the conversation the cache held, so each re-read the history at the full
//! input price and wrote it back at the 1.25x cache-write price, for a prefix
//! no later request would read.
//!
//! A fork that sends the same tools, the same system prompt and every message
//! verbatim, its instruction appended as the last user message, reads that
//! history from the cache instead (0.05x of input on Claude Opus 5.5, 0.1x on
//! Sonnet 5.5). It runs when the cache can still hold the prefix and the
//! request fits: this agent's last request began inside the TTL it asked for
//! (5 minutes, or the hour cache_ttl.zig picks for slow calls), no overflow is
//! being recovered, the history does not end on an unanswered tool call, and
//! the last summary attempt did not come back unusable.
//! Otherwise the old shape runs without breakpoints (cache_ttl.control): a
//! prefix nothing will read again is cheaper sent uncached (1x) than written
//! (1.25x).

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const claude = @import("claude_wire.zig");

/// A 5-minute entry, less the time the fork's own request takes to arrive.
const warm_ms: i64 = 4 * 60 * 1000 + 30 * 1000;
/// The same margin under a 1-hour entry (cache_ttl.zig, #1320).
const warm_long_ms: i64 = 55 * 60 * 1000;
/// Room for the instruction the fork appends.
const instruction_tokens: u64 = 8_000;

/// This thread's compaction requests fork the conversation. compact() and the
/// note it writes run on the thread that made the conversation's requests.
threadlocal var active: bool = false;

pub fn shares() bool {
    return active;
}

/// Decide for this compaction and mark the thread; pair with end().
pub fn begin(self: *Agent) bool {
    active = warm(self);
    return active;
}

pub fn end() void {
    active = false;
}

/// Whether this wire + provider route preserves an identical request prefix on
/// a forked compaction request. Anthropic Messages (Claude API) and OpenAI Chat
/// Completions (Codegraff gateway, DeepSeek, Z.AI, OpenAI, Xiaomi, xAI Chat,
/// OpenRouter) keep tools, system prompt, messages[0..n], and cache key
/// byte-identical when `shares()` is true. Responses uses in-stream server
/// compaction or lowers reasoning effort on client compaction.
pub fn supportsFork(kind: Provider.Kind, provider_id: []const u8, model: []const u8) bool {
    return switch (kind) {
        .anthropic => claude.isClaudeApi(provider_id, model),
        .openai => true,
        .responses, .interactions => false,
    };
}

/// Whether the cache still holds this conversation's prefix and a fork of the
/// whole history fits the window.
pub fn warm(self: *Agent) bool {
    if (!supportsFork(self.provider.kind, self.provider.id, self.provider.model)) return false;
    if (self.last_request_context_overflow or self.compact_summary_failures > 0) return false;
    const started = self.request_started orelse return false;
    const window = if (@import("cache_ttl.zig").asksLong(self.provider.id, self.provider.model)) warm_long_ms else warm_ms;
    if (started.untilNow(self.io, .awake).toMilliseconds() >= window) return false;
    if (endsOnToolCall(self.messages.items)) return false;
    const default_max = @import("main.zig").max_tokens;
    const out = if (self.provider.kind == .anthropic)
        claude.maxTokens(self.provider.model, self.reasoning, default_max)
    else
        default_max;
    return self.effectiveContextTokens() +| out +| instruction_tokens <= self.provider.context;
}

/// The tools a compaction request sends: the ones the conversation's own
/// requests carry when it forks, none otherwise.
pub fn tools(self: *const Agent, fork: bool) ?[]const u8 {
    if (!fork or self.text_only) return null;
    return self.toolsJson();
}

/// An assistant turn whose tool calls have no results yet: a user message
/// appended after it is a 400 on both Anthropic (`tool_use` block) and OpenAI
/// (`tool_calls` array).
pub fn endsOnToolCall(items: []const Value) bool {
    if (items.len == 0) return true;
    const m = items[items.len - 1];
    if (m != .object) return true;
    const role = m.object.get("role") orelse return true;
    if (role != .string or !std.mem.eql(u8, role.string, "assistant")) return false;
    if (m.object.get("tool_calls")) |tc| {
        if (tc == .array and tc.array.items.len > 0) return true;
    }
    const content = m.object.get("content") orelse return false;
    if (content != .array) return false;
    for (content.array.items) |block| {
        if (block != .object) continue;
        const kind = block.object.get("type") orelse continue;
        if (kind == .string and std.mem.eql(u8, kind.string, "tool_use")) return true;
    }
    return false;
}

fn message(arena: std.mem.Allocator, role: []const u8, block_type: ?[]const u8) !Value {
    var m: std.json.ObjectMap = .empty;
    try m.put(arena, "role", .{ .string = role });
    if (block_type) |kind| {
        var block: std.json.ObjectMap = .empty;
        try block.put(arena, "type", .{ .string = kind });
        var blocks = std.json.Array.init(arena);
        try blocks.append(.{ .object = block });
        try m.put(arena, "content", .{ .array = blocks });
    } else try m.put(arena, "content", .{ .string = "done" });
    return .{ .object = m };
}

fn testAgent(arena: std.mem.Allocator, model: []const u8, messages: std.json.Array) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = model, .context = 1_000_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
}

test "ADR 0220: a compaction forks the conversation only while the cache holds it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(try message(arena, "user", null));
    try messages.append(try message(arena, "assistant", null));
    var agent = testAgent(arena, "claude-opus-5-5", messages);
    try std.testing.expect(!warm(&agent)); // no request yet: nothing cached
    agent.request_started = std.Io.Timestamp.now(std.testing.io, .awake);
    try std.testing.expect(warm(&agent));
    try std.testing.expect(begin(&agent) and shares());
    end();
    try std.testing.expect(!shares());

    // A history that ends on an unanswered tool call cannot take a user turn.
    try agent.messages.append(try message(arena, "assistant", "tool_use"));
    try std.testing.expect(!warm(&agent));
    _ = agent.messages.pop();
    // Over the window, recovering an overflow, or after an unusable summary.
    agent.last_context_tokens = 990_000;
    try std.testing.expect(!warm(&agent));
    agent.last_context_tokens = 0;
    agent.compact_summary_failures = 1;
    try std.testing.expect(!warm(&agent));
    agent.compact_summary_failures = 0;
    agent.last_request_context_overflow = true;
    try std.testing.expect(!warm(&agent));
    agent.last_request_context_overflow = false;
    // Only the Anthropic API: other providers keep the old shape.
    agent.provider.id = "kimi";
    try std.testing.expect(!warm(&agent));
    agent.provider.id = "anthropic";
    try std.testing.expect(warm(&agent));

    // The fork carries the conversation's own tools; the old shape none.
    try std.testing.expectEqualStrings(agent.toolsJson(), tools(&agent, true).?);
    try std.testing.expect(tools(&agent, false) == null);
    agent.text_only = true;
    try std.testing.expect(tools(&agent, true) == null);
}

test "ADR 0220: a forked compaction request keeps the conversation's prefix byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(try message(arena, "user", null));
    var agent = testAgent(arena, "claude-sonnet-5-5", messages);
    const catalog = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    const live = try agent.buildBody(catalog, false, true, true);
    defer std.testing.allocator.free(live);

    agent.compaction_request = true;
    active = true;
    defer active = false;
    try agent.messages.append(try message(arena, "user", null));
    const fork = try agent.buildBody(catalog, false, true, true);
    defer std.testing.allocator.free(fork);
    // Tools, system prompt, thinking and effort match; the breakpoints stay.
    const cut = std.mem.indexOf(u8, live, "\"messages\"").?;
    try std.testing.expectEqualStrings(live[0..cut], fork[0..cut]);
    try std.testing.expect(std.mem.indexOf(u8, fork, "\"cache_control\"") != null);
}

test "ADR 0220: OpenAI-wire compaction fork keeps prefix and root cache partition" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(try message(arena, "user", null));
    try messages.append(try message(arena, "assistant", null));
    var agent = testAgent(arena, "deepseek-v4-flash", messages);
    agent.provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-flash", .context = 256_000 };
    agent.label = "main";
    agent.request_started = std.Io.Timestamp.now(std.testing.io, .awake);
    try std.testing.expect(warm(&agent));

    // An unanswered OpenAI tool_calls array blocks the fork just like Anthropic tool_use.
    var tc_msg: std.json.ObjectMap = .empty;
    try tc_msg.put(arena, "role", .{ .string = "assistant" });
    var tc_arr = std.json.Array.init(arena);
    var tc_item: std.json.ObjectMap = .empty;
    try tc_item.put(arena, "id", .{ .string = "call_1" });
    try tc_arr.append(.{ .object = tc_item });
    try tc_msg.put(arena, "tool_calls", .{ .array = tc_arr });
    try agent.messages.append(.{ .object = tc_msg });
    try std.testing.expect(!warm(&agent));
    _ = agent.messages.pop();
    try std.testing.expect(warm(&agent));

    const catalog = "[{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"\",\"parameters\":{\"type\":\"object\"}}}]";
    const live = try agent.buildBody(catalog, false, true, true);
    defer std.testing.allocator.free(live);

    agent.compaction_request = true;
    active = true;
    defer active = false;
    try agent.messages.append(try message(arena, "user", null));
    const fork = try agent.buildBody(catalog, false, true, true);
    defer std.testing.allocator.free(fork);

    // Every byte through the prior assistant message (model, max_tokens, stream,
    // tools, system message, and conversation history) is identical.
    const cut = std.mem.indexOf(u8, live, "],\"prompt_cache_key\"").?;
    try std.testing.expectEqualStrings(live[0..cut], fork[0..cut]);
    // And the #391 note label shares the root prompt_cache_key while forked.
    try std.testing.expect(@import("http_headers.zig").sharesParentCache("note"));
}
