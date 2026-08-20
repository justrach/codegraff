//! Z.AI GLM chat extras on the OpenAI-compatible wire.
//!
//! GLM-5.3 always reasons: `thinking.type` is only `enabled` (disabled fails)
//! and `reasoning_effort` is `low` | `high` | `max` (docs default `max`).
//! Graff's default is `medium`, which the API rejects — map it here.
//!
//! Context cache is implicit on identical prefixes
//! (`usage.prompt_tokens_details.cached_tokens`). Preserved thinking
//! (`clear_thinking: false`) keeps replayed `reasoning_content` in that
//! prefix so a tool turn does not drop the hit (docs.z.ai thinking-mode).

const std = @import("std");

/// Map a graff `/effort` tag onto Z.AI's allow-list. `medium` → `high`
/// (closest middle rung); `xhigh` / `ultra` → `max`.
pub fn reasoningEffort(requested: []const u8) []const u8 {
    if (std.mem.eql(u8, requested, "low")) return "low";
    if (std.mem.eql(u8, requested, "high")) return "high";
    if (std.mem.eql(u8, requested, "max")) return "max";
    if (std.mem.eql(u8, requested, "xhigh") or std.mem.eql(u8, requested, "ultra")) return "max";
    return "high";
}

/// OpenAI-chat extras after `prompt_cache_key`: Z.AI thinking, then the
/// shared `reasoning_effort` hint (Z.AI remapped; others pass through).
pub fn writeChatExtras(s: *std.json.Stringify, provider_id: []const u8, send_effort: bool, requested: []const u8) !void {
    const is_zai = std.mem.eql(u8, provider_id, "zai");
    if (is_zai) {
        try s.objectField("thinking");
        try s.print("{s}", .{"{\"type\":\"enabled\",\"clear_thinking\":false}"});
    }
    if (!std.mem.eql(u8, provider_id, "kimi") and send_effort) {
        try s.objectField("reasoning_effort");
        try s.write(if (is_zai) reasoningEffort(requested) else if (std.mem.eql(u8, requested, "ultra")) "max" else requested);
    }
}

test "Z.AI maps graff efforts onto low|high|max" {
    try std.testing.expectEqualStrings("low", reasoningEffort("low"));
    try std.testing.expectEqualStrings("high", reasoningEffort("medium"));
    try std.testing.expectEqualStrings("high", reasoningEffort("high"));
    try std.testing.expectEqualStrings("max", reasoningEffort("xhigh"));
    try std.testing.expectEqualStrings("max", reasoningEffort("max"));
    try std.testing.expectEqualStrings("max", reasoningEffort("ultra"));
}

test "Z.AI chat body sends thinking.enabled and remaps medium to high" {
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
            .id = "zai",
            .kind = .openai,
            .auth = .bearer,
            .url = "https://api.z.ai/api/paas/v4/chat/completions",
            .api_key = "k",
            .model = "glm-5.3",
            .context = 1_000_000,
        },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
        .reasoning = .medium,
    };
    const body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\",\"clear_thinking\":false}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") == null);

    agent.reasoning = .max;
    const max_body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(max_body);
    try std.testing.expect(std.mem.indexOf(u8, max_body, "\"reasoning_effort\":\"max\"") != null);
}

test "Keys.build: GRAFF_ZAI_URL rewires only the Z.AI endpoint" {
    const provider_mod = @import("provider.zig");
    const Keys = provider_mod.Keys;
    const all = Keys{ .values = @splat("k") };
    provider_mod.g_zai_url_override = provider_mod.zai_coding_url;
    defer provider_mod.g_zai_url_override = null;
    const zai = try all.providerById("zai", "glm-5.3");
    try std.testing.expectEqualStrings(provider_mod.zai_coding_url, zai.url);
    const deepseek = try all.providerById("deepseek", "deepseek-v4-pro");
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", deepseek.url);
}
