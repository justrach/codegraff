//! Live ACP `serviceTier` selector (`default` | `fast` | `ultrafast`) for
//! ChatGPT / Codex subscription routes (`codex` and `chatgpt-new`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const st = @import("service_tier.zig");

const fast_choices = [_]engine.ConfigValue{
    .{ .value = "default", .name = "Standard" },
    .{ .value = "fast", .name = "Fast" },
};

const ultrafast_choices = [_]engine.ConfigValue{
    .{ .value = "default", .name = "Standard" },
    .{ .value = "fast", .name = "Fast" },
    .{ .value = "ultrafast", .name = "Ultra Fast" },
};

pub fn option(ctx: *anyopaque, _: Allocator) anyerror!?engine.ConfigOption {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    if (!st.supportsFast(root.provider.id)) return null;
    const ultra = st.supportsUltrafast(root.provider.id, root.provider.model);
    const cur = st.normalizedForModel(root.provider.id, root.provider.model, st.effective(root));
    return .{
        .id = "serviceTier",
        .name = "Service Tier",
        .category = "speed",
        .currentValue = cur.label(),
        .options = if (ultra) &ultrafast_choices else &fast_choices,
    };
}

pub fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    if (!st.supportsFast(root.provider.id)) return false;
    const tier = st.parse(value) orelse return false;
    if (tier == .ultrafast and !st.supportsUltrafast(root.provider.id, root.provider.model)) return false;
    st.apply(root, tier);
    st.save(root);
    return true;
}

test "acp_service_tier offers Ultra Fast on 6.2 sol/astra for codex and chatgpt-new" {
    const saved_persist = st.persist_settings;
    st.persist_settings = false;
    defer st.persist_settings = saved_persist;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root = try @import("agent_request_body_responses.zig").testAgentFor(a, "chatgpt-new", .responses, "gpt-6.2-sol");
    var keys: @import("provider.zig").Keys = .{ .values = @splat(null) };
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = undefined };

    const opt = (try option(&live, a)).?;
    try std.testing.expectEqualStrings("serviceTier", opt.id);
    try std.testing.expectEqual(@as(usize, 3), opt.options.len);
    try std.testing.expectEqualStrings("ultrafast", opt.options[2].value);
    try std.testing.expect(try set(&live, "ultrafast"));
    try std.testing.expectEqual(st.Tier.ultrafast, st.effective(&root));
    try std.testing.expectEqualStrings("ultrafast", (try option(&live, a)).?.currentValue);

    root.provider.model = "gpt-6.1-sol";
    const older = (try option(&live, a)).?;
    try std.testing.expectEqual(@as(usize, 2), older.options.len);
    try std.testing.expectEqualStrings("fast", older.currentValue);
    try std.testing.expect(!try set(&live, "ultrafast"));

    root.provider.id = "openai";
    try std.testing.expect((try option(&live, a)) == null);
}
