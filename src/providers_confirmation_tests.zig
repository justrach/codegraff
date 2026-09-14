//! Offline /model confirmation regressions (#890). Imported by the test root.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const Keys = provider_mod.Keys;
const providers = @import("providers.zig");
const pricing = @import("pricing.zig");
const serde = @import("serde.zig");

// Match the minimal applyProviderInner fixture in providers.zig. No catalog
// refresh or turn execution is involved; credentials are inert test strings.
fn agent(arena: std.mem.Allocator, home: []const u8, p: Provider) !Agent {
    var root: Agent = undefined;
    root.io = std.testing.io;
    root.home = home;
    root.provider = p;
    root.subagent_provider = null;
    root.subagent_provider_explicit = true;
    root.arena = arena;
    root.registry = null;
    root.messages = std.json.Array.init(arena);
    try root.messages.append(try @import("messages.zig").textMessage(arena, "user", "keep this conversation"));
    root.sub = false;
    root.strict = false;
    root.sys_normal = "";
    root.sys_strict = "";
    root.tools_anthropic = "";
    root.tools_openai = "";
    root.tools_responses = "";
    root.keep_context = true;
    root.last_context_tokens = 220_000;
    root.context_local_tokens = 321;
    root.last_cache_read = 12_345;
    root.cap_new = true;
    root.sox_json_object = true;
    root.effort_rejected = true;
    root.ws_off = true;
    root.ws_transport_failures = 2;
    root.compact_transport_failures = 3;
    root.fallback_active = true;
    root.fallback_blocked = true;
    return root;
}

fn confirm(root: *Agent, arena: std.mem.Allocator, p: Provider, changed: bool) !void {
    const history = root.messages.items.ptr;
    const same_format = root.provider.kind == p.kind;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try providers.switchProvider(root, arena, p, &output.writer);
    const text = output.writer.buffered();
    const prefix = try std.fmt.allocPrint(arena, "{s} {s} via {s} (", .{
        if (changed) "switched to" else "already using", p.model, p.id,
    });
    try std.testing.expect(std.mem.startsWith(u8, text, prefix));
    try std.testing.expect(std.mem.indexOf(u8, text, if (changed) "already using" else "switched to") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, if (same_format) "context kept" else "context translated & kept") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "saved for next session\n"));
    try std.testing.expectEqualStrings(p.id, root.provider.id);
    try std.testing.expectEqualStrings(p.model, root.provider.model);
    if (same_format) try std.testing.expect(history == root.messages.items.ptr);
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    try std.testing.expectEqualStrings("keep this conversation", providers.extractText(arena, root.messages.items[0]));
    try std.testing.expect(!root.fallback_active);
    try std.testing.expect(!root.fallback_blocked);
    const saved = serde.loadModel(root.io, arena, root.home) orelse return error.ModelNotSaved;
    try std.testing.expectEqualStrings(p.id, saved.pid);
    try std.testing.expectEqualStrings(p.model, saved.model);
}

fn exercise(query: []const u8, target_provider: []const u8, target_model: []const u8, changed: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    // Own the catalog for deterministic alias/routing tests, not live accounts.
    const previous = pricing.active_model_table;
    defer pricing.active_model_table = previous;
    const rows = [_]pricing.ModelInfo{
        .{ .provider = "openai", .name = "confirmation-model", .context = 270_000 },
        .{ .provider = "openai", .name = "confirmation-next", .context = 270_000 },
        .{ .provider = "codegraff", .name = "confirmation-model", .context = 270_000 },
    };
    pricing.active_model_table = &rows;
    var keys: Keys = .{ .values = @splat("offline-test-key") };
    const initial = try providers.resolveProviderControlRequest(&keys, arena, "openai", "confirmation-model", "");
    const selected = try providers.resolveProviderControlRequest(&keys, arena, target_provider, target_model, query);
    try std.testing.expectEqualStrings(if (target_provider.len == 0) "openai" else target_provider, selected.id);
    try std.testing.expectEqualStrings(if (target_model.len == 0) "confirmation-model" else target_model, selected.model);
    var root = try agent(arena, home, initial);
    // A stale saved preference proves no-op confirmation still applies/persists.
    serde.saveModel(root.io, home, "stale-provider", "stale-model");
    try confirm(&root, arena, selected, changed);
    if (!changed) {
        try std.testing.expectEqual(@as(u64, 220_000), root.last_context_tokens);
        try std.testing.expectEqual(@as(u64, 321), root.context_local_tokens);
        try std.testing.expectEqual(@as(u64, 12_345), root.last_cache_read);
        try std.testing.expect(root.cap_new and root.sox_json_object and root.effort_rejected and root.ws_off);
        try std.testing.expectEqual(@as(u8, 2), root.ws_transport_failures);
        try std.testing.expectEqual(@as(u8, 3), root.compact_transport_failures);
    } else {
        try std.testing.expectEqual(root.fullRequestEstimateTokens(), root.last_context_tokens);
        try std.testing.expectEqual(root.last_context_tokens, root.context_local_tokens);
        try std.testing.expectEqual(@as(u64, 0), root.last_cache_read);
        try std.testing.expect(!root.cap_new and !root.sox_json_object and !root.effort_rejected and !root.ws_off);
        try std.testing.expectEqual(@as(u8, 0), root.ws_transport_failures);
        try std.testing.expectEqual(@as(u8, 0), root.compact_transport_failures);
    }
    // Repeating even a genuine switch must now announce the current selection.
    try confirm(&root, arena, selected, false);
}

test "#890 confirmation: repeated resolved selection preserves server state and persists" {
    try exercise("", "openai", "confirmation-model", false);
}

test "#890 confirmation: normalized alias resolves to the active selection" {
    try exercise("CONFIRMATION_MODEL", "", "", false);
}

test "#890 confirmation: different provider with the same model is a switch" {
    try exercise("", "codegraff", "confirmation-model", true);
}

test "#890 confirmation: different model on the same provider is a switch" {
    try exercise("", "openai", "confirmation-next", true);
}

test "#890 confirmation: same identity refreshes context endpoint and wire format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const initial: Provider = .{
        .id = "openai",
        .model = "confirmation-model",
        .kind = .openai,
        .auth = .bearer,
        .url = "https://initial.invalid/v1/chat/completions",
        .api_key = "offline-test-key",
        .context = 270_000,
    };
    var root = try agent(arena, home, initial);
    serde.saveModel(root.io, home, "stale-provider", "stale-model");
    var refreshed = initial;
    refreshed.context = 400_000;
    refreshed.url = "https://refreshed.invalid/v1/messages";
    refreshed.kind = .anthropic;
    try confirm(&root, arena, refreshed, false);
    try std.testing.expectEqual(refreshed.context, root.provider.context);
    try std.testing.expectEqualStrings(refreshed.url, root.provider.url);
    try std.testing.expectEqual(refreshed.kind, root.provider.kind);
    // Explicitly choosing the active fallback still persists that identity.
    root.fallback_active = true;
    root.fallback_blocked = true;
    serde.saveModel(root.io, home, "stale-provider", "stale-model");
    try confirm(&root, arena, refreshed, false);
}
