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

/// Vercel AI Gateway Chat Completions uses `reasoning.effort`
/// (none|minimal|low|medium|high|xhigh), not top-level reasoning_effort.
/// Graff `max`/`ultra` → `xhigh`.
pub fn vercelEffort(requested: []const u8) []const u8 {
    if (std.mem.eql(u8, requested, "low")) return "low";
    if (std.mem.eql(u8, requested, "medium")) return "medium";
    if (std.mem.eql(u8, requested, "high")) return "high";
    if (std.mem.eql(u8, requested, "xhigh")) return "xhigh";
    if (std.mem.eql(u8, requested, "max") or std.mem.eql(u8, requested, "ultra")) return "xhigh";
    return "medium";
}

/// DeepSeek V4 (native or via codegraff/fireworks): thinking is ON at
/// high unless `thinking.type` is `disabled`. `reasoning_effort: low`
/// still emits `reasoning_content` (ADR 0050).
pub fn isDeepseekFamily(provider_id: []const u8, model: []const u8) bool {
    if (std.mem.eql(u8, provider_id, "deepseek")) return true;
    return std.mem.indexOf(u8, model, "deepseek") != null;
}

/// OpenAI-chat extras after `prompt_cache_key`: Z.AI thinking, Vercel
/// `reasoning.effort`, DeepSeek thinking on/off, then `reasoning_effort`.
pub fn writeChatExtras(s: *std.json.Stringify, provider_id: []const u8, model: []const u8, send_effort: bool, requested: []const u8) !void {
    const is_zai = std.mem.eql(u8, provider_id, "zai");
    const is_vercel = std.mem.eql(u8, provider_id, "vercel");
    if (is_zai) {
        try s.objectField("thinking");
        try s.print("{s}", .{"{\"type\":\"enabled\",\"clear_thinking\":false}"});
    } else if (isDeepseekFamily(provider_id, model) and send_effort) {
        // Official off switch. GLM rejects type=disabled; do not send it there.
        try s.objectField("thinking");
        try s.print("{s}", .{if (std.mem.eql(u8, requested, "low"))
            "{\"type\":\"disabled\"}"
        else
            "{\"type\":\"enabled\"}"});
    }
    if (is_vercel and send_effort) {
        try s.objectField("reasoning");
        try s.beginObject();
        try s.objectField("effort");
        try s.write(vercelEffort(requested));
        try s.endObject();
        return;
    }
    if (!std.mem.eql(u8, provider_id, "kimi") and send_effort) {
        try s.objectField("reasoning_effort");
        try s.write(if (is_zai) reasoningEffort(requested) else if (std.mem.eql(u8, requested, "ultra")) "max" else requested);
    }
}

test "DeepSeek family is native id or a deepseek model name" {
    try std.testing.expect(isDeepseekFamily("deepseek", "deepseek-v4-pro"));
    try std.testing.expect(isDeepseekFamily("codegraff", "deepseek-v4-flash"));
    try std.testing.expect(isDeepseekFamily("fireworks", "accounts/fireworks/models/deepseek-v4-flash"));
    try std.testing.expect(!isDeepseekFamily("codegraff", "glm-5.3-flash"));
    try std.testing.expect(!isDeepseekFamily("zai", "glm-5.3"));
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

test "Vercel maps graff efforts onto reasoning.effort" {
    try std.testing.expectEqualStrings("low", vercelEffort("low"));
    try std.testing.expectEqualStrings("medium", vercelEffort("medium"));
    try std.testing.expectEqualStrings("high", vercelEffort("high"));
    try std.testing.expectEqualStrings("xhigh", vercelEffort("xhigh"));
    try std.testing.expectEqualStrings("xhigh", vercelEffort("max"));
    try std.testing.expectEqualStrings("xhigh", vercelEffort("ultra"));
}

test "Vercel chat body sends reasoning.effort and not reasoning_effort" {
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
            .id = "vercel",
            .kind = .openai,
            .auth = .bearer,
            .url = "https://ai-gateway.vercel.sh/coding-agent/v1/chat/completions",
            .api_key = "k",
            .model = "alibaba/qwen3.8-27b",
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
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"medium\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"") != null);

    agent.reasoning = .max;
    const max_body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(max_body);
    try std.testing.expect(std.mem.indexOf(u8, max_body, "\"reasoning\":{\"effort\":\"xhigh\"}") != null);
}
