//! Fullscreen TUI constraint review and runtime-trajectory coverage for #789.

const std = @import("std");

const engine = @import("engine.zig");
const Term = @import("sim.zig").Term;

var callback_calls: usize = 0;

fn constraintCallback(_: ?*anyopaque, gpa: std.mem.Allocator, line: []const u8) ?[]const u8 {
    callback_calls += 1;
    return std.fmt.allocPrint(gpa, "scope=project · origin=user:1\n{s}\nundo with /never rm <unique text>\n", .{line}) catch null;
}

const Trajectory = enum { idle, live_turn, background_compact, background_bash, background_files };
const trajectories = [_]Trajectory{ .idle, .live_turn, .background_compact, .background_bash, .background_files };

const Fixture = struct {
    term: Term,
    bg: ?*engine.BgOp = null,

    fn init(trajectory: Trajectory) !Fixture {
        var fixture: Fixture = undefined;
        fixture.bg = null;
        fixture.term.init(std.testing.allocator, 80, 24);
        errdefer fixture.term.deinit();
        switch (trajectory) {
            .idle => {},
            .live_turn => {
                const job = try std.testing.allocator.create(engine.Job);
                job.* = .{ .gpa = std.testing.allocator, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
                fixture.term.model.pending = job;
            },
            .background_compact, .background_bash, .background_files => {
                const kind: engine.BgOp.Kind = switch (trajectory) {
                    .background_compact => .compact,
                    .background_bash => .bash,
                    .background_files => .files,
                    else => unreachable,
                };
                const op = try std.testing.allocator.create(engine.BgOp);
                op.* = .{ .kind = kind, .gpa = std.testing.allocator, .threaded = false };
                fixture.term.model.bg = op;
                fixture.bg = op;
            },
        }
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        if (self.term.model.pending) |job| {
            self.term.model.pending = null;
            std.testing.allocator.destroy(job);
        }
        if (self.bg) |op| {
            self.term.model.bg = null;
            std.testing.allocator.destroy(op);
        }
        self.term.deinit();
    }
};

test "#789 fullscreen TUI exposes visible constraint review and text removal" {
    engine.g_constraint_fn = constraintCallback;
    defer engine.g_constraint_fn = null;
    callback_calls = 0;

    var fixture = try Fixture.init(.idle);
    defer fixture.deinit();
    _ = fixture.term.typeText("/constraint rm navigation dots");
    const effect = fixture.term.enter();
    try std.testing.expectEqual(@import("app.zig").Effect.stay, effect);
    try std.testing.expectEqual(@as(usize, 1), callback_calls);
    try std.testing.expect(fixture.term.model.running);
    try std.testing.expect(!fixture.term.model.quit_requested);
    const screen = try fixture.term.screen();
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "scope=project") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "origin=user:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "unique text") != null);
}

test "#789 constraint commands never disrupt live TUI trajectories" {
    engine.g_constraint_fn = constraintCallback;
    defer engine.g_constraint_fn = null;

    for (trajectories[1..]) |trajectory| {
        callback_calls = 0;
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        _ = fixture.term.typeText("/never rm navigation dots");
        const effect = fixture.term.enter();
        try std.testing.expectEqual(@import("app.zig").Effect.stay, effect);
        try std.testing.expectEqual(@as(usize, 0), callback_calls);
        try std.testing.expect(fixture.term.model.running);
        try std.testing.expect(!fixture.term.model.quit_requested);
        try std.testing.expect(!fixture.term.model.cancel_requested);
        if (trajectory == .live_turn) try std.testing.expect(fixture.term.model.pending != null);
        if (fixture.bg) |op| try std.testing.expect(fixture.term.model.bg == op and !op.cancelled);
    }
}
