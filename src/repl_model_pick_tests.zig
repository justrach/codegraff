//! Offline engine-side model selection regressions (#890).
const std = @import("std");
const provider_mod = @import("provider.zig");
const repl_glue = @import("repl_glue.zig");
const pricing = @import("pricing.zig");
const serde = @import("serde.zig");

const rows = [_]pricing.ModelInfo{
    .{ .provider = "openai", .name = "pick-model", .context = 270_000 },
    .{ .provider = "openai", .name = "pick-next", .context = 270_000 },
    .{ .provider = "codegraff", .name = "pick-model", .context = 270_000 },
};

fn keyedFor(id: []const u8) provider_mod.Keys {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    _ = keys.set(id, "offline-test-key", .stored);
    return keys;
}

// Like repl_model_pick_test.zig: no client operations or turns are needed.
fn switchCtx(client: *std.http.Client, home: []const u8) !repl_glue.ReplCtx {
    const keys = keyedFor("openai");
    return .{
        .io = std.testing.io,
        .client = client,
        .keys = keys,
        .home = home,
        .provider = try keys.providerById("openai", "pick-model"),
        .fallback_allow = &.{},
        .fallback_active = false,
        .fallback_blocked = false,
        .registry = null,
        .tracer = null,
        .run_budget = null,
        .sys_normal = "",
        .tools_anthropic = "",
        .tools_openai = "",
        .tools_responses = "",
    };
}

fn expectSaved(arena: std.mem.Allocator, ctx: *const repl_glue.ReplCtx) !void {
    const saved = serde.loadModel(ctx.io, arena, ctx.home) orelse return error.ModelNotSaved;
    try std.testing.expectEqualStrings(ctx.provider.id, saved.pid);
    try std.testing.expectEqualStrings(ctx.provider.model, saved.model);
}

fn exercise(query: []const u8, provider_id: []const u8, model: []const u8, changed: bool, fallback: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const previous = pricing.active_model_table;
    defer pricing.active_model_table = previous;
    pricing.active_model_table = &rows;
    var client: std.http.Client = undefined;
    var ctx = try switchCtx(&client, home);
    // Change routing credentials without changing the active engine provider.
    ctx.keys = keyedFor(provider_id);
    ctx.fallback_active = fallback;
    ctx.fallback_blocked = fallback;
    serde.saveModel(ctx.io, home, "stale-provider", "stale-model");

    const picked = repl_glue.replModelCb(&ctx, std.testing.allocator, query) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(picked.model);
    try std.testing.expectEqual(changed, picked.changed);
    try std.testing.expectEqualStrings(model, picked.model);
    try std.testing.expectEqualStrings(model, ctx.provider.model);
    try std.testing.expectEqualStrings(provider_id, ctx.provider.id);
    try std.testing.expect(!ctx.fallback_active);
    try std.testing.expect(!ctx.fallback_blocked);
    try expectSaved(arena, &ctx);

    // The changed bit describes this dispatch, not the original session seat.
    const repeated = repl_glue.replModelCb(&ctx, std.testing.allocator, query) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(repeated.model);
    try std.testing.expect(!repeated.changed);
    try std.testing.expectEqualStrings(model, repeated.model);
    try expectSaved(arena, &ctx);
}

test "#890 replModelCb: unchanged normalized alias" {
    try exercise("PICK_MODEL", "openai", "pick-model", false, false);
}

test "#890 replModelCb: real model change" {
    try exercise("pick-next", "openai", "pick-next", true, false);
}

test "#890 replModelCb: same model with changed credential routing switches provider" {
    try exercise("pick-model", "codegraff", "pick-model", true, false);
}

test "#890 replModelCb: explicitly reselected fallback is unchanged but saved and cleared" {
    try exercise("pick-model", "openai", "pick-model", false, true);
}

test "#890 replModelCb: result allocation failure keeps selection and preference" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena_state.allocator());
    const previous = pricing.active_model_table;
    defer pricing.active_model_table = previous;
    pricing.active_model_table = &rows;
    var client: std.http.Client = undefined;
    var ctx = try switchCtx(&client, home);
    ctx.fallback_active = true;
    ctx.fallback_blocked = true;
    serde.saveModel(ctx.io, home, ctx.provider.id, ctx.provider.model);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(repl_glue.replModelCb(&ctx, failing.allocator(), "pick-next") == null);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqualStrings("openai", ctx.provider.id);
    try std.testing.expectEqualStrings("pick-model", ctx.provider.model);
    try std.testing.expect(ctx.fallback_active and ctx.fallback_blocked);
    try expectSaved(arena_state.allocator(), &ctx);
    // Named off-catalog selections allocate both the provider name and display.
    // Failing either allocation must leave the same state and free any temporary.
    for (0..2) |fail_index| {
        var named_failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expect(repl_glue.replModelPick(&ctx, named_failure.allocator(), "openai", "off-catalog") == null);
        try std.testing.expect(named_failure.has_induced_failure);
        try std.testing.expectEqualStrings("openai", ctx.provider.id);
        try std.testing.expectEqualStrings("pick-model", ctx.provider.model);
        try std.testing.expect(ctx.fallback_active and ctx.fallback_blocked);
        try expectSaved(arena_state.allocator(), &ctx);
    }
}

test "#890 replModelPick: named provider returns the resolved engine seat" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const previous = pricing.active_model_table;
    defer pricing.active_model_table = previous;
    pricing.active_model_table = &rows;
    var client: std.http.Client = undefined;
    var ctx = try switchCtx(&client, home);
    _ = ctx.keys.set("codegraff", "offline-test-key", .stored);
    ctx.fallback_active = true;
    ctx.fallback_blocked = true;
    const picked = repl_glue.replModelPick(&ctx, std.testing.allocator, "codegraff", "pick-model") orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(picked.model);
    try std.testing.expectEqualStrings("codegraff", picked.provider);
    try std.testing.expectEqualStrings(ctx.provider.id, picked.provider);
    try std.testing.expectEqualStrings("pick-model", picked.model);
    try std.testing.expectEqualStrings(ctx.provider.model, picked.model);
    try std.testing.expect(!ctx.fallback_active);
    try std.testing.expect(!ctx.fallback_blocked);
    try expectSaved(arena, &ctx);
}
