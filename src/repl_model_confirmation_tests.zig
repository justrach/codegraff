//! Offline `/model` confirmation regressions (#890).
//! Exercise the dispatcher using the backend's resolved change result.
const std = @import("std");
const repl = @import("repl.zig");

const Stub = struct {
    calls: usize = 0,
    last_name: []const u8 = "",
    // Separate storage makes equal resolved names distinct slices, so equality
    // must compare bytes rather than pointer identity.
    resolved: [7]u8 = "model-a".*,
    current: []const u8 = "model-a",

    fn select(ctx: ?*anyopaque, _: std.mem.Allocator, name: []const u8) ?repl.ModelPick {
        const self: *Stub = @ptrCast(@alignCast(ctx orelse return null));
        self.calls += 1;
        self.last_name = name;
        const model: []const u8 = if (std.mem.eql(u8, name, "model-a") or std.mem.eql(u8, name, "alias-a")) &self.resolved else if (std.mem.eql(u8, name, "model-b")) "model-b" else return null;
        const changed = !std.mem.eql(u8, self.current, model);
        self.current = model;
        return .{ .model = model, .changed = changed };
    }
};

const Saved = struct {
    model_fn: ?repl.ModelFn,
    turn_fn: ?repl.TurnFn,
    ctx: ?*anyopaque,
    name: []const u8,

    fn install(stub: *Stub) Saved {
        const saved: Saved = .{
            .model_fn = repl.g_model_fn,
            .turn_fn = repl.g_turn_fn,
            .ctx = repl.g_turn_ctx,
            .name = repl.g_model_name,
        };
        repl.g_model_fn = Stub.select;
        repl.g_turn_fn = null;
        repl.g_turn_ctx = stub;
        repl.g_model_name = "model-a";
        return saved;
    }

    fn restore(self: Saved) void {
        repl.g_model_fn = self.model_fn;
        repl.g_turn_fn = self.turn_fn;
        repl.g_turn_ctx = self.ctx;
        repl.g_model_name = self.name;
    }
};

fn expectInfo(m: *const repl.Model, text: []const u8) !void {
    const entry = m.history.items[m.history.items.len - 1];
    try std.testing.expect(entry.kind == .info);
    try std.testing.expectEqualStrings(text, entry.text);
}

test "model confirmation: repeated resolved selection is already using (#890)" {
    var stub: Stub = .{};
    const saved = Saved.install(&stub);
    defer saved.restore();
    var m: repl.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    for (0..2) |i| {
        m.runCommand("/model model-a");
        try expectInfo(&m, "already using model-a");
        try std.testing.expectEqualStrings("model-a", repl.g_model_name);
        try std.testing.expectEqual(i + 1, stub.calls);
        try std.testing.expectEqual(i + 2, m.history.items.len);
    }
}

test "model confirmation: alias resolving to current model is already using (#890)" {
    var stub: Stub = .{};
    const saved = Saved.install(&stub);
    defer saved.restore();
    var m: repl.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    m.runCommand("/model   alias-a \t");
    try expectInfo(&m, "already using model-a");
    try std.testing.expectEqualStrings("alias-a", stub.last_name);
    try std.testing.expectEqualStrings("model-a", repl.g_model_name);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try std.testing.expectEqual(@as(usize, 2), m.history.items.len);
}

test "model confirmation: actual change switches then repeated selection does not (#890)" {
    var stub: Stub = .{};
    const saved = Saved.install(&stub);
    defer saved.restore();
    var m: repl.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    m.runCommand("/model model-b");
    try expectInfo(&m, "switched to model-b");
    try std.testing.expectEqualStrings("model-b", repl.g_model_name);
    m.runCommand("/model model-b");
    try expectInfo(&m, "already using model-b");
    try std.testing.expectEqualStrings("model-b", repl.g_model_name);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 3), m.history.items.len);
}

test "model confirmation: failed selection retains current model and reports error (#890)" {
    var stub: Stub = .{};
    const saved = Saved.install(&stub);
    defer saved.restore();
    var m: repl.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    m.runCommand("/model unavailable");
    const entry = m.history.items[m.history.items.len - 1];
    try std.testing.expect(entry.kind == .err);
    try std.testing.expectEqualStrings("couldn't switch to 'unavailable' — see /models (need a key/login for it)", entry.text);
    try std.testing.expectEqualStrings("model-a", repl.g_model_name);
    try std.testing.expectEqualStrings("unavailable", stub.last_name);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try std.testing.expectEqual(@as(usize, 2), m.history.items.len);
}
