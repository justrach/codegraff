//! The live ACP thought-level selector shares the root effort state with /effort.
const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");
const er = @import("effort_route.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const ReasoningEffort = @import("main.zig").ReasoningEffort;

fn label(tag: []const u8, mimo: bool) []const u8 {
    if (mimo and std.mem.eql(u8, tag, "none")) return "Off";
    if (mimo and std.mem.eql(u8, tag, "high")) return "On";
    if (std.mem.eql(u8, tag, "low")) return "Low";
    if (std.mem.eql(u8, tag, "medium")) return "Medium";
    if (std.mem.eql(u8, tag, "high")) return "High";
    if (std.mem.eql(u8, tag, "xhigh")) return "Extra High";
    if (std.mem.eql(u8, tag, "max")) return "Max";
    return "Ultra";
}

pub fn option(ctx: *anyopaque, arena: Allocator) anyerror!?engine.ConfigOption {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    if (!root.effortApplies()) return null;
    if (root.reasoning == .none and !er.mimoRoute(root.provider.id, root.provider.model)) return error.ReasoningOffUnsupported;
    const levels = er.levels(root.provider.id, root.provider.model);
    const values = try arena.alloc(engine.ConfigValue, levels.len);
    for (levels, values) |tag, *value| value.* = .{ .value = tag, .name = label(tag, er.mimoRoute(root.provider.id, root.provider.model)) };
    const normalized = er.normalize(root.provider.id, root.provider.model, @tagName(root.reasoning));
    return .{ .currentValue = if (er.allows(root.provider.id, root.provider.model, normalized)) normalized else "high", .options = values };
}

pub fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    const canonical = er.normalize(root.provider.id, root.provider.model, value);
    if (!root.effortApplies() or !er.allows(root.provider.id, root.provider.model, canonical)) return false;
    root.reasoning = std.meta.stringToEnum(ReasoningEffort, canonical) orelse return false;
    root.jev_effort_pending.invalidate(root.io);
    _ = @import("repl_glue.zig").saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
    return true;
}

test "thought-level options follow the active model allowlist and normalized current value" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var root = try @import("agent_request_body_responses.zig").testAgentFor(arena, "openai", .responses, "gpt-6-astra");
    var keys: @import("provider.zig").Keys = .{ .values = @splat(null) };
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = undefined };
    root.reasoning = .max;
    const broad = (try option(&live, arena)).?;
    try std.testing.expectEqualStrings("ultra", broad.currentValue);
    try std.testing.expectEqual(@as(usize, 5), broad.options.len);
    try std.testing.expectEqualStrings("ultra", broad.options[4].value);
    root.provider.id = "xai";
    root.provider.model = "grok-4.6";
    const narrow = (try option(&live, arena)).?;
    try std.testing.expectEqualStrings("high", narrow.currentValue);
    try std.testing.expectEqual(@as(usize, 4), narrow.options.len);
    try std.testing.expectEqualStrings("xhigh", narrow.options[3].value);
    root.provider.id = "anthropic";
    root.provider.kind = .anthropic;
    root.provider.model = "claude-opus-4-8";
    try std.testing.expect((try option(&live, arena)) == null);
}

test "MiMo thought-level discovery names Off and On and normalizes saved positive levels" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var root = try @import("agent_request_body_responses.zig").testAgentFor(arena, "xiaomi", .openai, "mimo-v2.6-flash");
    var keys: @import("provider.zig").Keys = .{ .values = @splat(null) };
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = undefined };
    root.reasoning = .low;
    const pending = root.jev_effort_pending.begin(root.io, root.provider).?;
    try std.testing.expect(root.jev_effort_pending.commit(root.io, pending, .none));
    try std.testing.expect(@import("jev_effort_state.zig").applyToState(&root));
    try std.testing.expectEqualStrings("none", (try option(&live, arena)).?.currentValue);
    root.reasoning = .low;
    const on = (try option(&live, arena)).?;
    try std.testing.expectEqualStrings("high", on.currentValue);
    try std.testing.expectEqual(@as(usize, 2), on.options.len);
    try std.testing.expectEqualStrings("none", on.options[0].value);
    try std.testing.expectEqualStrings("Off", on.options[0].name);
    try std.testing.expectEqualStrings("high", on.options[1].value);
    try std.testing.expectEqualStrings("On", on.options[1].name);
    try std.testing.expect(er.allows("xiaomi", "mimo-v2.6-flash", "none"));
    root.reasoning = .none;
    try std.testing.expectEqualStrings("none", (try option(&live, arena)).?.currentValue);
    root.provider.id = "openai";
    root.provider.kind = .responses;
    root.provider.model = "gpt-6-astra";
    try std.testing.expectError(error.ReasoningOffUnsupported, option(&live, arena));
    try std.testing.expect(!er.allows("openai", "gpt-6-astra", "none"));
}
