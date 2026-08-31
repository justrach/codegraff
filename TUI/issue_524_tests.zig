//! Reachable fullscreen TUI regressions for legacy ESC ESC CSI navigation.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const key = @import("key.zig");
const recover = @import("key_recover.zig");
const stall = @import("run_stall.zig");
const Term = @import("sim.zig").Term;

const Trajectory = enum { idle, live_turn, compact, bash, files };
const trajectories = [_]Trajectory{ .idle, .live_turn, .compact, .bash, .files };

const Fixture = struct {
    term: Term,
    bg: ?*engine.BgOp = null,

    fn init(trajectory: Trajectory) !Fixture {
        var fixture: Fixture = undefined;
        fixture.bg = null;
        fixture.term.init(std.testing.allocator, 80, 24);
        errdefer fixture.term.deinit();
        try fixture.term.model.push(.user, "existing turn");
        switch (trajectory) {
            .idle => {},
            .live_turn => {
                const job = try std.testing.allocator.create(engine.Job);
                job.* = .{ .gpa = std.testing.allocator, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
                try fixture.term.model.push(.pending, "");
                fixture.term.model.pending = job;
            },
            .compact, .bash, .files => {
                const op = try std.testing.allocator.create(engine.BgOp);
                op.* = .{ .kind = switch (trajectory) {
                    .compact => .compact,
                    .bash => .bash,
                    .files => .files,
                    else => unreachable,
                }, .gpa = std.testing.allocator, .threaded = false };
                try fixture.term.model.push(.pending, "background operation");
                fixture.term.model.bg = op;
                fixture.bg = op;
            },
        }
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        if (self.bg) |op| {
            self.term.model.bg = null;
            std.testing.allocator.destroy(op);
        }
        if (self.term.model.pending) |job| {
            self.term.model.pending = null;
            std.testing.allocator.destroy(job);
        }
        self.term.deinit();
    }
};

fn expectAlive(fixture: *Fixture, trajectory: Trajectory) !void {
    try std.testing.expect(!fixture.term.model.cancel_requested);
    try std.testing.expect(fixture.term.last_effect == .stay);
    if (trajectory == .live_turn) try std.testing.expect(fixture.term.model.pending != null);
    if (trajectory != .idle and trajectory != .live_turn)
        try std.testing.expect(fixture.bg != null and !fixture.bg.?.cancelled);
}

test "legacy Alt CSI decodes to the underlying navigation keys" {
    const cases = [_]struct { bytes: []const u8, expected: key.Key }{
        .{ .bytes = "\x1b\x1b[D", .expected = .left },
        .{ .bytes = "\x1b\x1b[C", .expected = .right },
        .{ .bytes = "\x1b\x1b[A", .expected = .up },
        .{ .bytes = "\x1b\x1b[1;3A", .expected = .up },
        .{ .bytes = "\x1b\x1b[1;3C", .expected = .word_right },
        .{ .bytes = "\x1b\x1b[1;3D", .expected = .word_left },
    };
    key.resetInputState();
    defer key.resetInputState();
    for (cases) |case| {
        var i: usize = 0;
        try std.testing.expectEqual(case.expected, key.next(case.bytes, &i).?);
        try std.testing.expectEqual(case.bytes.len, i);
        try std.testing.expect(key.next(case.bytes, &i) == null);
    }
}

test "legacy Alt CSI navigation accepts a coalesced printable key" {
    const sequences = [_][]const u8{
        "\x1b\x1b[Ax",
        "\x1b\x1b[Cx",
        "\x1b\x1b[Dx",
        "\x1b\x1b[1;3Ax",
        "\x1b\x1b[1;3Cx",
        "\x1b\x1b[1;3Dx",
    };
    for (trajectories) |trajectory| for (sequences) |sequence| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        _ = fixture.term.feed(sequence);
        try std.testing.expectEqualStrings("x", fixture.term.model.input.getValue());
        try expectAlive(&fixture, trajectory);
    };
}

test "legacy Alt CSI boundary preserves printable prose on every TUI trajectory" {
    const prose = [_]struct { sequence: []const u8, expected: []const u8 }{
        .{ .sequence = "\x1b\x1b[Alice]", .expected = "seed:[Alice]" },
        .{ .sequence = "\x1b\x1b[1;3Alice]", .expected = "seed:[1;3Alice]" },
    };
    for (trajectories) |trajectory| for (prose) |case| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("seed:");
        fixture.term.model.scroll = 7;
        fixture.term.model.follow = false;
        _ = fixture.term.feed(case.sequence);
        try std.testing.expectEqualStrings(case.expected, fixture.term.model.input.getValue());
        try std.testing.expectEqual(@as(usize, 7), fixture.term.model.scroll);
        try std.testing.expectEqual(app.Overlay.none, fixture.term.model.overlay);
    };
}

test "legacy Alt CSI navigation never emits Escape on any TUI trajectory" {
    const sequences = [_][]const u8{
        "\x1b\x1b[D",
        "\x1b\x1b[C",
        "\x1b\x1b[A",
        "\x1b\x1b[1;3A",
        "\x1b\x1b[1;3C",
        "\x1b\x1b[1;3D",
    };
    for (trajectories) |trajectory| {
        for (sequences) |sequence| {
            for (0..sequence.len + 1) |cut| {
                var fixture = try Fixture.init(trajectory);
                defer fixture.deinit();
                _ = fixture.term.feed(sequence[0..cut]);
                _ = fixture.term.feed(sequence[cut..]);
                try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
                try expectAlive(&fixture, trajectory);
            }
        }
    }
}

test "legacy Alt CSI stays safe across the bounded stall window" {
    const sequences = [_][]const u8{
        "\x1b\x1b[A",
        "\x1b\x1b[C",
        "\x1b\x1b[D",
        "\x1b\x1b[1;3A",
        "\x1b\x1b[1;3C",
        "\x1b\x1b[1;3D",
    };
    for (trajectories) |trajectory| for (sequences) |sequence| {
        const grace: u8 = if (trajectory == .idle) 12 else stall.live_escape_stalls;
        for (0..sequence.len) |cut| {
            var fixture = try Fixture.init(trajectory);
            defer fixture.deinit();
            _ = fixture.term.feed(sequence[0..cut]);
            for (0..grace - 1) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
            _ = fixture.term.feed(sequence[cut..]);
            try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
            try expectAlive(&fixture, trajectory);
        }
    };
}

test "legacy Alt CSI rejoins after a dropped head and a full read" {
    const cases = [_]struct { tail: []const u8, expected: key.Key }{
        .{ .tail = "A", .expected = .up },
        .{ .tail = "C", .expected = .right },
        .{ .tail = "D", .expected = .left },
        .{ .tail = "1;3A", .expected = .up },
        .{ .tail = "1;3C", .expected = .word_right },
        .{ .tail = "1;3D", .expected = .word_left },
    };
    for (cases) |case| {
        key.resetInputState();
        key.abandonSequence("\x1b\x1b[", .dropped);
        var buf: [16 * 1024]u8 = @splat('x');
        @memcpy(buf[0..case.tail.len], case.tail);
        const n = key.joinOrphanHead(&buf, buf.len);
        var i: usize = 0;
        try std.testing.expectEqual(case.expected, key.next(buf[0..n], &i).?);
        try std.testing.expectEqual(key.Key{ .char = 'x' }, key.next(buf[0..n], &i).?);
    }
    key.resetInputState();
    key.abandonSequence("\x1b\x1b[", .dropped);
    var prose: [16]u8 = @splat(0);
    @memcpy(prose[0..6], "Alice]");
    try std.testing.expectEqual(@as(?usize, 1), recover.legacyCsiProse("\x1b\x1b[", "Alice]", 9));
    const prose_n = key.joinOrphanHead(&prose, 6);
    try std.testing.expectEqual(@as(usize, 7), prose_n);
    var prose_i: usize = 0;
    for ("[Alice]") |expected| try std.testing.expectEqual(key.Key{ .char = expected }, key.next(prose[0..prose_n], &prose_i).?);
    try std.testing.expectEqual(prose_n, prose_i);
    key.resetInputState();
}

test "legacy Alt CSI survives the runtime dropped-head seam" {
    var fixture = try Fixture.init(.live_turn);
    defer fixture.deinit();
    _ = fixture.term.feed("\x1b\x1b[");
    fixture.term.stallDropPending();
    _ = fixture.term.feed("1;3D");
    try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
    try expectAlive(&fixture, .live_turn);
}

test "genuine double Escape still arms rewind after legacy Alt ambiguity expires" {
    var fixture = try Fixture.init(.idle);
    defer fixture.deinit();
    _ = fixture.term.feed("\x1b\x1b");
    for (0..11) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
    try std.testing.expectEqual(stall.StallVerdict.escape_pair, fixture.term.stallTimeout());
    try std.testing.expectEqual(app.Overlay.rewind, fixture.term.model.overlay);
}

test "legacy Alt CSI does not close a paste or move through an overlay" {
    var paste = try Fixture.init(.idle);
    defer paste.deinit();
    _ = paste.term.feed("\x1b[200~");
    _ = paste.term.feed("\x1b\x1b[1;3D");
    try std.testing.expect(key.inPaste());
    try std.testing.expectEqualStrings("", paste.term.model.input.getValue());
    _ = paste.term.feed("\x1b[201~");
    try std.testing.expect(!key.inPaste());

    var overlay = try Fixture.init(.idle);
    defer overlay.deinit();
    overlay.term.model.openOverlay(.palette);
    overlay.term.model.overlay_sel = 1;
    _ = overlay.term.feed("\x1b\x1b[A");
    try std.testing.expectEqual(app.Overlay.palette, overlay.term.model.overlay);
    try std.testing.expectEqual(@as(usize, 0), overlay.term.model.overlay_sel);
}
