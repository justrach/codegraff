const std = @import("std");
const provider_mod = @import("provider.zig");
const pricing = @import("pricing.zig");
const catalog = @import("router_catalog.zig");
const native = @import("provider_nanoattention.zig");
const Agent = @import("agent.zig").Agent;

test "native Flint routes locally, honors its configured context, and never falls back" {
    const old_context = provider_mod.g_context_override;
    defer provider_mod.g_context_override = old_context;
    const saved_table = pricing.active_model_table;
    defer pricing.active_model_table = saved_table;

    const spec = provider_mod.specFor("nanoattention").?;
    try std.testing.expectEqualStrings("flint", spec.default_model);
    try std.testing.expectEqualStrings("NANOATTENTION_API_KEY", spec.env_key);
    try std.testing.expect(!spec.takes_effort);
    try std.testing.expectEqualStrings("nanoattention", (try (provider_mod.Keys{ .values = @splat("local") }).providerById("nanoattention", "flint")).id);
    try std.testing.expectEqual(@as(u64, 32_768), (try (provider_mod.Keys{ .values = @splat("local") }).providerById("nanoattention", "flint")).context);

    provider_mod.g_context_override = 4096;
    try std.testing.expectEqual(@as(u64, 4096), (try (provider_mod.Keys{ .values = @splat("local") }).providerById("nanoattention", "flint")).context);
    provider_mod.g_context_override = 65_536;
    try std.testing.expectEqual(@as(u64, 65_536), (try (provider_mod.Keys{ .values = @splat("local") }).providerById("nanoattention", "flint")).context);
    const no_keys: provider_mod.Keys = .{ .values = @splat(null) };
    try std.testing.expectError(error.MissingKey, no_keys.providerById("nanoattention", "flint"));
    try std.testing.expectError(error.MissingKey, no_keys.providerFor("flint"));
}

test "native Flint chat and catalog routes share a validated loopback override" {
    const old = native.url_override;
    defer native.url_override = old;
    native.url_override = "http://localhost:43123/v1/chat/completions";

    const spec = provider_mod.specFor("nanoattention").?;
    const keys = provider_mod.Keys{ .values = @splat("local") };
    const route = try keys.providerById("nanoattention", "flint");
    try std.testing.expectEqualStrings("http://localhost:43123/v1/chat/completions", route.url);
    try std.testing.expectEqualStrings("http://localhost:43123/v1/models", catalog.modelsUrl(spec));
    try std.testing.expect(!native.validEndpoint("http://example.com:43123/v1/chat/completions"));
}

test "native Flint request uses ordinary greedy-compatible OpenAI fields only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = std.json.Array.init(arena);
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = "nanoattention",
            .kind = .openai,
            .auth = .bearer,
            .url = native.default_chat_url,
            .api_key = "local",
            .model = "flint",
            .context = 32_768,
        },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"flint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"top_p\"") == null);
}
