//! T3 Code profile through the engine.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");
const t3 = @import("acp_t3.zig");

test {
    _ = @import("acp_model_option.zig");
    _ = t3;
}

const Fixture = struct {
    slashed: []const u8 = "",
    picked: []const u8 = "codex/gpt-a",
    fn turn(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
        return "done";
    }
    fn slash(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.slashed = try arena.dupe(u8, text);
        return if (std.mem.eql(u8, text, "/models")) "models table" else null;
    }
    fn effort(_: *anyopaque, _: Allocator) anyerror!?engine.ConfigOption {
        return .{ .currentValue = "medium", .options = &.{.{ .value = "medium", .name = "Medium" }} };
    }
    fn setEffort(_: *anyopaque, _: []const u8) anyerror!bool {
        return true;
    }
    fn model(ctx: *anyopaque, _: Allocator) anyerror!?engine.ConfigOption {
        if (!t3.active()) return null;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return .{ .id = "model", .name = "Model", .category = "model", .currentValue = self.picked, .options = &.{ .{ .value = "codex/gpt-a", .name = "gpt-a" }, .{ .value = "codex/gpt-b", .name = "gpt-b" } } };
    }
    fn setModel(ctx: *anyopaque, value: []const u8) anyerror!bool {
        if (!t3.active()) return false;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.picked = value;
        return true;
    }
};

fn run(d: *engine.Dispatch, a: Allocator, buf: []u8, line: []const u8) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try engine.handleLine(d, a, &w, line);
    return w.buffered();
}

test "T3 Code profile: first-block slash, model option, trimmed commands; others unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer t3.note(null);
    var buf: [65536]u8 = undefined;
    const prompt = "{\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"acp-1-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"/models\"},{\"type\":\"text\",\"text\":\"<runtime_info>ctx</runtime_info>\"}]}}";
    const pick = "{\"id\":4,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"model\",\"value\":\"codex/gpt-b\"}}";

    // Another client: whole prompt reaches the slash handler, no model option.
    var plain: Fixture = .{};
    var d: engine.Dispatch = .{ .turn = Fixture.turn, .ctx = &plain, .seed = 1, .slash = Fixture.slash, .config = Fixture.effort, .set_config = Fixture.setEffort, .model_config = Fixture.model, .set_model = Fixture.setModel };
    _ = try run(&d, a, &buf, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"zed\"}}}");
    var out = try run(&d, a, &buf, "{\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"category\":\"model\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"model\"") != null);
    _ = try run(&d, a, &buf, prompt);
    try std.testing.expect(std.mem.indexOf(u8, plain.slashed, "<runtime_info>") != null);
    out = try run(&d, a, &buf, pick);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":-32602") != null);

    // T3 Code: the command alone, the model picker, and no duplicate /model.
    var tee: Fixture = .{};
    d = .{ .turn = Fixture.turn, .ctx = &tee, .seed = 1, .slash = Fixture.slash, .config = Fixture.effort, .set_config = Fixture.setEffort, .model_config = Fixture.model, .set_model = Fixture.setModel };
    _ = try run(&d, a, &buf, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"t3-code\"}}}");
    out = try run(&d, a, &buf, "{\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"category\":\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"category\":\"thought_level\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"model\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"yolo\"") == null);
    out = try run(&d, a, &buf, prompt);
    try std.testing.expectEqualStrings("/models", tee.slashed);
    try std.testing.expect(std.mem.indexOf(u8, out, "models table") != null);
    out = try run(&d, a, &buf, pick);
    try std.testing.expectEqualStrings("codex/gpt-b", tee.picked);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"currentValue\":\"codex/gpt-b\"") != null);
}
