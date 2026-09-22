const std = @import("std");
const bench = @import("bench_priors.zig");
const pricing = @import("pricing.zig");
const provider = @import("provider.zig");
const pin = @import("subagent_pin.zig");
const selection = @import("subagent_selection.zig");
const ladder = @import("subagent_tier_ladder.zig");

fn request(a: std.mem.Allocator, json: []const u8) std.json.ObjectMap {
    return (std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch unreachable).object;
}

test "MiMo small workers stay on Flash despite a Luna subscription" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved_keys = bench.g_keys;
    const saved_ladders = bench.g_ladders;
    const saved_models = pricing.active_model_table;
    defer {
        bench.g_keys = saved_keys;
        bench.g_ladders = saved_ladders;
        pricing.active_model_table = saved_models;
    }
    bench.g_ladders = &.{};
    pricing.active_model_table = &pricing.model_table;
    var keys: provider.Keys = .{ .values = @splat(null) };
    for (provider.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "xiaomi") or std.mem.eql(u8, spec.id, "codex")) keys.values[i] = "test-key";
    }
    bench.g_keys = &keys;
    const base = try keys.providerById("xiaomi", "mimo-v2.6-pro");
    const small = pin.forSpawn(base, request(arena.allocator(), "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqualStrings("xiaomi", small.provider.?.id);
    try std.testing.expectEqualStrings("mimo-v2.6-flash", small.provider.?.model);
    const inherited = selection.resolveSubagentProvider(keys, base, null, null, false, false).?;
    try std.testing.expectEqualStrings("mimo-v2.6-flash", inherited.model);
    // An exact human pin still wins; this is a default, not a model ban.
    const exact = pin.forSpawn(base, request(arena.allocator(), "{\"model\":\"gpt-5.6-luna\"}"), true);
    try std.testing.expectEqualStrings("gpt-5.6-luna", exact.provider.?.model);
    try std.testing.expect(selection.resolveSubagentProvider(keys, base.withModel("mimo-v2.6-flash"), null, null, false, false) == null);
}

test "MiMo gateway preference requires live catalog availability and keeps credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved_models = pricing.active_model_table;
    const saved_keys = bench.g_keys;
    const saved_ladders = bench.g_ladders;
    defer {
        pricing.active_model_table = saved_models;
        bench.g_keys = saved_keys;
        bench.g_ladders = saved_ladders;
    }
    bench.g_ladders = &.{};
    pricing.active_model_table = &pricing.model_table;
    var keys: provider.Keys = .{ .values = @splat("test-key") };
    bench.g_keys = &keys;
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "codegraff", .name = "mimo-v2.6-pro", .context = 1_048_576 },
        .{ .provider = "codegraff", .name = "mimo-v2.6-flash", .context = 1_048_576 },
        .{ .provider = "codegraff", .name = "gpt-5.6-luna", .context = 272_000 },
    };
    try std.testing.expect(pricing.activateProviderModels(arena.allocator(), "codegraff", &discovered));
    const base = try keys.providerById("codegraff", "gpt-5.6-luna");
    const small = pin.forSpawn(base, request(arena.allocator(), "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqualStrings("codegraff", small.provider.?.id);
    try std.testing.expectEqualStrings(base.api_key, small.provider.?.api_key);
    try std.testing.expectEqualStrings("mimo-v2.6-flash", small.provider.?.model);
    const automatic = selection.resolveSubagentProvider(keys, base, null, null, false, false).?;
    try std.testing.expectEqualStrings("codegraff", automatic.id);
    try std.testing.expectEqualStrings("mimo-v2.6-flash", automatic.model);
    try std.testing.expect(pin.rungAffordableOn(base, "mimo-v2.6-pro"));
    const frontier = pin.forSpawn(base, request(arena.allocator(), "{\"tier\":\"frontier\"}"), true);
    try std.testing.expectEqualStrings("codegraff", frontier.provider.?.id);
    try std.testing.expectEqualStrings("mimo-v2.6-pro", frontier.provider.?.model);
    try std.testing.expectEqualStrings(base.api_key, frontier.provider.?.api_key);
    pricing.active_model_table = &pricing.model_table;
    try std.testing.expectEqualStrings("deepseek-v4-flash", ladder.forModel("codegraff", base.model).?.small.?);
}

test "MiMo default workers never fall through to an expensive or unpriced Flash rung" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved_models = pricing.active_model_table;
    const saved_prices = pricing.price_overlay;
    const saved_ladders = bench.g_ladders;
    const saved_keys = bench.g_keys;
    defer {
        pricing.active_model_table = saved_models;
        pricing.price_overlay = saved_prices;
        bench.g_ladders = saved_ladders;
        bench.g_keys = saved_keys;
    }
    var keys: provider.Keys = .{ .values = @splat("test-key") };
    bench.g_keys = &keys;
    bench.g_ladders = &.{};
    pricing.active_model_table = &pricing.model_table;
    const root = try keys.providerById("xiaomi", "mimo-v2.6-pro");
    pricing.price_overlay = &.{.{ .name = "mimo-v2.6-flash", .in = 10, .out = 20, .cache = 1 }};
    try std.testing.expect(!pin.rungAffordableOn(root, "mimo-v2.6-flash"));
    try std.testing.expect(selection.resolveSubagentProvider(keys, root, null, null, false, false) == null);
    // A discovered alias may be routable before its exact price row exists.
    // The Pro frontier match must not bypass the failed affordability check.
    pricing.price_overlay = &.{};
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "xiaomi", .name = "mimo-v2.6-pro", .context = 1_048_576 },
        .{ .provider = "xiaomi", .name = "MiMo-V2.6-Flash", .context = 1_048_576 },
    };
    try std.testing.expect(pricing.activateProviderModels(arena.allocator(), "xiaomi", &discovered));
    try std.testing.expect(pricing.priceFor("MiMo-V2.6-Flash") == null);
    try std.testing.expect(!pin.rungAffordableOn(root, "MiMo-V2.6-Flash"));
    try std.testing.expect(selection.resolveSubagentProvider(keys, root, null, null, false, false) == null);
}

test "MiMo routing does not cross to a metered provider without an explicit request" {
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    var keys: provider.Keys = .{ .values = @splat("test-key") };
    bench.g_keys = &keys;
    const base = try keys.providerById("codex", "gpt-5.6-sol");
    try std.testing.expectError(error.CrossProviderConsentRequired, selection.subagentProvider(keys, base, "xiaomi", "mimo-v2.6-flash", false));
    const selected = try selection.subagentProvider(keys, base, "xiaomi", "mimo-v2.6-flash", true);
    try std.testing.expectEqualStrings("xiaomi", selected.id);
    try std.testing.expectEqualStrings("mimo-v2.6-flash", selected.model);
}
