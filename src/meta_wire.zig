//! Meta / Muse Spark request-body policy (#751).
//!
//! Meta's chat API only accepts `tool_choice: "auto"`. `none`, `required`,
//! and named function choices 400 as `request_rejected`. The Codegraff
//! gateway already translates those (zigrepper `34a4882`); the harness still
//! must not emit them for a known-restricted model — a silent `required`→
//! `auto` rewrite at the gateway is a semantic gap. ADR 0070.

const std = @import("std");

/// Native Meta seat, or a Muse Spark id on any provider (Codegraff gateway).
pub fn restricted(provider_id: []const u8, model: []const u8) bool {
    if (std.mem.eql(u8, provider_id, "meta")) return true;
    return std.mem.startsWith(u8, model, "muse-spark");
}

/// Value written as OpenAI-chat `tool_choice`. Restricted models always
/// get `auto`, even when the harness wanted a forced call.
pub fn toolChoice(force_tool: bool, provider_id: []const u8, model: []const u8) []const u8 {
    if (restricted(provider_id, model)) return "auto";
    return if (force_tool) "required" else "auto";
}

/// Chat `reasoning_effort` after Z.AI's own map. Meta 1.3 rejects `max`
/// for non-contributor seats; fold `max`/`ultra` to `xhigh` (gateway
/// `0051310`). Everyone else: `ultra` → `max`, otherwise the tag as-is.
pub fn chatEffort(requested: []const u8, provider_id: []const u8, model: []const u8) []const u8 {
    if (restricted(provider_id, model)) {
        if (std.mem.eql(u8, requested, "max") or std.mem.eql(u8, requested, "ultra"))
            return "xhigh";
        return requested;
    }
    if (std.mem.eql(u8, requested, "ultra")) return "max";
    return requested;
}

test "meta: restricted is the meta seat or any muse-spark id" {
    try std.testing.expect(restricted("meta", "muse-spark-1.3"));
    try std.testing.expect(restricted("codegraff", "muse-spark-1.3"));
    try std.testing.expect(restricted("meta", "something-else"));
    try std.testing.expect(!restricted("openai", "gpt-5.6"));
    try std.testing.expect(!restricted("codegraff", "grok-4.6"));
}

test "meta: tool_choice is auto even when the harness forces a call" {
    try std.testing.expectEqualStrings("auto", toolChoice(true, "meta", "muse-spark-1.3"));
    try std.testing.expectEqualStrings("auto", toolChoice(false, "meta", "muse-spark-1.3"));
    try std.testing.expectEqualStrings("auto", toolChoice(true, "codegraff", "muse-spark-1.2"));
    try std.testing.expectEqualStrings("required", toolChoice(true, "openai", "gpt-5.6"));
    try std.testing.expectEqualStrings("auto", toolChoice(false, "openai", "gpt-5.6"));
}

test "meta: max/ultra effort folds to xhigh; other providers keep ultra→max" {
    try std.testing.expectEqualStrings("xhigh", chatEffort("max", "meta", "muse-spark-1.3"));
    try std.testing.expectEqualStrings("xhigh", chatEffort("ultra", "codegraff", "muse-spark-1.3"));
    try std.testing.expectEqualStrings("high", chatEffort("high", "meta", "muse-spark-1.3"));
    try std.testing.expectEqualStrings("max", chatEffort("ultra", "openai", "gpt-5.6"));
    try std.testing.expectEqualStrings("high", chatEffort("high", "openai", "gpt-5.6"));
}

test "meta: forced chat body sends auto, never required; max effort is xhigh" {
    const Agent = @import("agent.zig").Agent;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "hello" });
    try messages.append(.{ .object = user });
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = "meta",
            .kind = .openai,
            .auth = .bearer,
            .url = "https://api.meta.ai/v1/chat/completions",
            .api_key = "k",
            .model = "muse-spark-1.3",
            .context = 1_048_576,
        },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
        .reasoning = .max,
    };
    const tools = "[{\"type\":\"function\",\"function\":{\"name\":\"ping\",\"description\":\"\",\"parameters\":{\"type\":\"object\"}}}]";
    const forced = try agent.buildBody(tools, true, true, true);
    defer std.testing.allocator.free(forced);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"tool_choice\":\"required\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"reasoning_effort\":\"xhigh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"reasoning_effort\":\"max\"") == null);

    agent.provider.id = "codegraff";
    const gw = try agent.buildBody(tools, true, true, true);
    defer std.testing.allocator.free(gw);
    try std.testing.expect(std.mem.indexOf(u8, gw, "\"tool_choice\":\"required\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, gw, "\"tool_choice\":\"auto\"") != null);
}
