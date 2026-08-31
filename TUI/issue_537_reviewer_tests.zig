//! Reviewer-W regressions for #537's bounded dropped-head recovery.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const keys = @import("keys.zig");
const pacing = @import("pacing.zig");
const stall = @import("run_stall.zig");
const Term = @import("sim.zig").Term;
const Effect = app.Effect;

const Trajectory = enum { idle, live_turn, compact, bash, files };
const trajectories = [_]Trajectory{ .idle, .live_turn, .compact, .bash, .files };

fn isBackground(trajectory: Trajectory) bool {
    return switch (trajectory) {
        .compact, .bash, .files => true,
        .idle, .live_turn => false,
    };
}

fn installPending(term: *Term) !void {
    const job = try std.testing.allocator.create(engine.Job);
    errdefer std.testing.allocator.destroy(job);
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{},
        .threaded = false,
    };
    try term.model.push(.pending, "");
    term.model.pending = job;
}

fn installBackground(term: *Term, kind: engine.BgOp.Kind) !*engine.BgOp {
    const op = try std.testing.allocator.create(engine.BgOp);
    errdefer std.testing.allocator.destroy(op);
    op.* = .{ .kind = kind, .gpa = std.testing.allocator, .threaded = false };
    try term.model.push(.pending, "background operation");
    term.model.bg = op;
    return op;
}

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
            .live_turn => try installPending(&fixture.term),
            .compact => fixture.bg = try installBackground(&fixture.term, .compact),
            .bash => fixture.bg = try installBackground(&fixture.term, .bash),
            .files => fixture.bg = try installBackground(&fixture.term, .files),
        }
        fixture.term.now_ms = 100;
        fixture.term.model.now_ms = 100;
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
    if (trajectory == .live_turn) try std.testing.expect(fixture.term.model.pending != null);
    if (isBackground(trajectory)) try std.testing.expect(fixture.term.model.bg != null and !fixture.bg.?.cancelled);
}

fn abandonedAt401(head: []const u8, recovery: key_mod.SequenceRecovery, close_paste: bool, fresh: []const u8, buf: []u8) usize {
    key_mod.abandonSequence(head, recovery);
    if (close_paste) key_mod.endPaste();
    // At 401ms the short genuine-Escape carry is gone, but the one-second
    // dropped-head recovery interval is still live.
    std.debug.assert(stall.escapeCarryExpired(401, 0));
    std.debug.assert(!stall.armExpired(401, 0));
    key_mod.expireOrphanHead();
    @memcpy(buf[0..fresh.len], fresh);
    return key_mod.joinOrphanHead(buf, fresh.len);
}

test "every internal paste-marker split reconstructs a real event at 401ms" {
    const cases = [_]struct { marker: []const u8, start: bool }{
        .{ .marker = "\x1b[200~", .start = true },
        .{ .marker = "\x1b[201~", .start = false },
    };
    for (cases) |case| for (1..case.marker.len) |cut| {
        errdefer std.debug.print("marker recovery failure: {s} split {d}\n", .{ case.marker, cut });
        key_mod.resetInputState();
        if (!case.start) {
            var open_i: usize = 0;
            try std.testing.expectEqual(key_mod.Key.paste_start, key_mod.next("\x1b[200~", &open_i).?);
        }
        const ctx: stall.StallCtx = .{ .in_paste = !case.start };
        const budget: u8 = if (cut == 1) 12 else if (case.start) 20 else 80;
        const verdict: stall.StallVerdict = if (cut == 1) .escape_key else .drop;
        try std.testing.expectEqual(stall.StallVerdict.wait, stall.stallVerdict(case.marker[0..cut], budget - 1, ctx));
        try std.testing.expectEqual(verdict, stall.stallVerdict(case.marker[0..cut], budget, ctx));

        var fresh: [32]u8 = undefined;
        const tail = case.marker[cut..];
        @memcpy(fresh[0..tail.len], tail);
        fresh[tail.len] = 0x11; // same-read Ctrl-Q: ordering is observable
        var joined: [64]u8 = undefined;
        const recovery: key_mod.SequenceRecovery = if (cut == 1) .escape else .dropped;
        const n = abandonedAt401(case.marker[0..cut], recovery, !case.start, fresh[0 .. tail.len + 1], &joined);
        var i: usize = 0;
        const marker = key_mod.next(joined[0..n], &i).?;
        if (case.start) {
            try std.testing.expectEqual(key_mod.Key.paste_start, marker);
            try std.testing.expect(key_mod.inPaste());
        } else {
            try std.testing.expectEqual(key_mod.Key.paste_end, marker);
            try std.testing.expect(!key_mod.inPaste());
        }
        try std.testing.expectEqual(key_mod.Key{ .ctrl = 'q' }, key_mod.next(joined[0..n], &i).?);
        try std.testing.expectEqual(n, i);
    };
    key_mod.resetInputState();
}

test "every dropped paste-start split latches before controls on every trajectory" {
    const marker = "\x1b[200~";
    const payload = "left\x11\x03\nright";
    for (trajectories) |trajectory| for (2..marker.len) |cut| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        errdefer std.debug.print("paste-start trajectory failure: {s} split {d}\n", .{ @tagName(trajectory), cut });
        try fixture.term.model.input.setValue("seed:");
        const history_len = fixture.term.model.history.items.len;
        _ = fixture.term.feed(marker[0..cut]);
        for (0..19) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        try std.testing.expectEqual(stall.StallVerdict.drop, fixture.term.stallTimeout());
        fixture.term.now_ms += 401;
        var fresh: [64]u8 = undefined;
        const tail = marker[cut..];
        @memcpy(fresh[0..tail.len], tail);
        @memcpy(fresh[tail.len .. tail.len + payload.len], payload);
        try std.testing.expectEqual(Effect.stay, fixture.term.feed(fresh[0 .. tail.len + payload.len]));
        try std.testing.expect(fixture.term.model.pasting and key_mod.inPaste());
        try std.testing.expectEqualStrings("seed:left\nright", fixture.term.model.input.getValue());
        try std.testing.expectEqual(history_len, fixture.term.model.history.items.len);
        try expectAlive(&fixture, trajectory);
        _ = fixture.term.feed("\x1b[201~");
    };
}

const FramedKind = enum { sgr, x10, kitty, osc };

fn expectFramed(kind: FramedKind, k: key_mod.Key) !void {
    switch (kind) {
        .sgr => {
            try std.testing.expect(k == .mouse);
            try std.testing.expectEqual(@as(u8, 65), k.mouse.btn);
            try std.testing.expectEqual(@as(u16, 20), k.mouse.x);
            try std.testing.expectEqual(@as(u16, 10), k.mouse.y);
        },
        .x10 => {
            try std.testing.expect(k == .mouse);
            try std.testing.expectEqual(@as(u8, 64), k.mouse.btn);
            try std.testing.expectEqual(@as(u16, 4), k.mouse.x);
            try std.testing.expectEqual(@as(u16, 4), k.mouse.y);
        },
        .kitty => try std.testing.expectEqual(key_mod.Key.left, k),
        .osc => try std.testing.expect(k == .bg_report),
    }
}

test "dropped SGR X10 kitty and OSC retain exact framing at 401ms" {
    const cases = [_]struct { bytes: []const u8, kind: FramedKind }{
        .{ .bytes = "\x1b[<65;20;10M", .kind = .sgr },
        .{ .bytes = "\x1b[M`$$", .kind = .x10 },
        .{ .bytes = "\x1b[57350;1u", .kind = .kitty },
        .{ .bytes = "\x1b]11;rgb:14/14/14\x07", .kind = .osc },
    };
    for (cases) |case| for (2..case.bytes.len) |cut| {
        key_mod.resetInputState();
        try std.testing.expectEqual(stall.StallVerdict.drop, stall.stallVerdict(case.bytes[0..cut], 20, .{}));
        var fresh: [128]u8 = undefined;
        const tail = case.bytes[cut..];
        @memcpy(fresh[0..tail.len], tail);
        fresh[tail.len] = 'X';
        var joined: [192]u8 = undefined;
        const n = abandonedAt401(case.bytes[0..cut], .dropped, false, fresh[0 .. tail.len + 1], &joined);
        var i: usize = 0;
        try expectFramed(case.kind, key_mod.next(joined[0..n], &i).?);
        try std.testing.expectEqual(key_mod.Key{ .char = 'X' }, key_mod.next(joined[0..n], &i).?);
        try std.testing.expectEqual(n, i);
    };
    key_mod.resetInputState();
}

test "every SGR separator split preserves button and coordinate alignment" {
    const report = "\x1b[<65;20;10M";
    for (report, 0..) |c, at| {
        if (c != ';') continue;
        for ([_]usize{ at, at + 1 }) |cut| {
            key_mod.resetInputState();
            var joined: [64]u8 = undefined;
            const n = abandonedAt401(report[0..cut], .dropped, false, report[cut..], &joined);
            var i: usize = 0;
            const k = key_mod.next(joined[0..n], &i).?;
            try expectFramed(.sgr, k);
            try std.testing.expectEqual(@as(?i32, -1), pacing.wheelNotch(k));
            try std.testing.expectEqual(n, i);
        }
    }
    key_mod.resetInputState();
}

test "unaligned mouse tails fail closed instead of fabricating mouse or wheel" {
    const tails = [_][]const u8{
        "65;20;10M", // may start at button, x, or y
        "20;10M",
        "10M",
        ";10M",
        "65;20;10m",
        "<65;20M", // field-zero marker, but a missing coordinate
    };
    for (tails) |tail| {
        key_mod.resetInputState();
        key_mod.armOrphan(true);
        var i: usize = 0;
        const k = key_mod.next(tail, &i).?;
        try std.testing.expect(k != .mouse);
        try std.testing.expectEqual(@as(?i32, null), pacing.wheelNotch(k));
        try std.testing.expectEqual(tail.len, i);
    }
    // With field zero and all three fields proven, recovery remains exact.
    key_mod.resetInputState();
    key_mod.armOrphan(true);
    var i: usize = 0;
    const framed = key_mod.next("<65;20;10M", &i).?;
    try std.testing.expectEqual(@as(?i32, -1), pacing.wheelNotch(framed));
    // Full ESC framing still cannot invent a missing SGR coordinate.
    key_mod.resetInputState();
    i = 0;
    const malformed = key_mod.next("\x1b[<65;20M", &i).?;
    try std.testing.expect(malformed != .mouse);
    try std.testing.expectEqual(@as(?i32, null), pacing.wheelNotch(malformed));
    key_mod.resetInputState();
}

test "a mismatched dropped head disarms before byte-at-a-time prose on every trajectory" {
    for (trajectories) |trajectory| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("seed:");
        fixture.term.model.scroll = 7;
        fixture.term.model.follow = false;
        _ = fixture.term.feed("\x1b[<65;20");
        for (0..19) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        try std.testing.expectEqual(stall.StallVerdict.drop, fixture.term.stallTimeout());
        fixture.term.now_ms += 401;
        for ("[Alice]") |c| {
            _ = fixture.term.feed(&[_]u8{c});
            fixture.term.now_ms += 50;
        }
        try std.testing.expectEqualStrings("seed:[Alice]", fixture.term.model.input.getValue());
        try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
        try std.testing.expectEqual(@as(usize, 7), fixture.term.model.scroll);
        try std.testing.expect(!fixture.term.model.follow);
        try expectAlive(&fixture, trajectory);
    }
}

fn dispatchProductionBatch(m: *app.Model, bytes: []const u8) !Effect {
    var batch: pacing.Batch = .{};
    var i: usize = 0;
    while (key_mod.next(bytes, &i)) |k| try std.testing.expectEqual(pacing.Push.ok, batch.push(k));
    // Both reports are consecutive and must reach run.zig as one folded item.
    try std.testing.expectEqual(@as(usize, 2), batch.folded);
    var wheel_items: usize = 0;
    var effect: Effect = .stay;
    for (batch.items()) |item| {
        if (item == .wheel) {
            wheel_items += 1;
            try std.testing.expectEqual(@as(i32, 2), item.wheel);
        }
        effect = keys.handleBatchItem(m, item);
        if (effect != .stay) break;
    }
    try std.testing.expectEqual(@as(usize, 1), wheel_items);
    return effect;
}

test "production folded SGR and X10 wheels are paste-aware on every trajectory" {
    const reads = [_][]const u8{
        "\x1b[200~left\x1b[<64;4;4M\x1b[<64;4;4Mright\x1b[201~",
        "\x1b[200~left\x1b[M`$$\x1b[M`$$right\x1b[201~",
    };
    for (trajectories) |trajectory| for (reads) |bytes| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        fixture.term.model.scroll = 7;
        fixture.term.model.follow = false;
        fixture.term.model.sel.active = true;
        fixture.term.model.sel.pressed = true;
        try std.testing.expectEqual(Effect.stay, try dispatchProductionBatch(&fixture.term.model, bytes));
        try std.testing.expectEqualStrings("leftright", fixture.term.model.input.getValue());
        try std.testing.expectEqual(@as(usize, 7), fixture.term.model.scroll);
        try std.testing.expect(!fixture.term.model.follow);
        try std.testing.expect(fixture.term.model.sel.active and fixture.term.model.sel.pressed);
        try std.testing.expect(!fixture.term.model.pasting and !key_mod.inPaste());
        try expectAlive(&fixture, trajectory);
    };
}

test "every paste marker cut is safe on every runtime trajectory" {
    const start = "\x1b[200~";
    const end = "\x1b[201~";
    for (trajectories) |trajectory| for (1..start.len) |cut| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        const history_len = fixture.term.model.history.items.len;
        _ = fixture.term.feed(start[0..cut]);
        try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        const payload = "left\x11\x03\nright";
        var fresh: [32]u8 = undefined;
        const tail = start[cut..];
        @memcpy(fresh[0..tail.len], tail);
        @memcpy(fresh[tail.len .. tail.len + payload.len], payload);
        _ = fixture.term.feed(fresh[0 .. tail.len + payload.len]);
        try std.testing.expectEqualStrings("left\nright", fixture.term.model.input.getValue());
        try std.testing.expect(fixture.term.model.pasting and key_mod.inPaste());
        _ = fixture.term.feed(end[0..cut]);
        try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        _ = fixture.term.feed(end[cut..]);
        try std.testing.expect(!fixture.term.model.pasting and !key_mod.inPaste());
        try std.testing.expectEqual(history_len, fixture.term.model.history.items.len);
        try expectAlive(&fixture, trajectory);
    };
}

test "dropped paste heads accumulate secondary late reads on every trajectory" {
    for (trajectories) |trajectory| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("seed:");
        const history_len = fixture.term.model.history.items.len;

        _ = fixture.term.feed("\x1b[20");
        for (0..19) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        try std.testing.expectEqual(stall.StallVerdict.drop, fixture.term.stallTimeout());
        fixture.term.now_ms += 401;
        try std.testing.expectEqual(Effect.stay, fixture.term.feed("0"));
        try std.testing.expectEqualStrings("seed:", fixture.term.model.input.getValue());
        try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);

        try std.testing.expectEqual(Effect.stay, fixture.term.feed("~left\x11\x03\nright"));
        try std.testing.expect(fixture.term.model.pasting and key_mod.inPaste());
        try std.testing.expectEqualStrings("seed:left\nright", fixture.term.model.input.getValue());
        try std.testing.expectEqual(history_len, fixture.term.model.history.items.len);
        try expectAlive(&fixture, trajectory);
        _ = fixture.term.feed("\x1b[201~");
    }
}

test "every paste marker cut permits a second bounded partial tail" {
    const cases = [_]struct { marker: []const u8, start: bool }{
        .{ .marker = "\x1b[200~", .start = true },
        .{ .marker = "\x1b[201~", .start = false },
    };
    for (cases) |case| for (2..case.marker.len - 1) |cut| {
        const tail = case.marker[cut..];
        for (1..tail.len) |second_cut| {
            key_mod.resetInputState();
            if (!case.start) {
                var open_i: usize = 0;
                try std.testing.expectEqual(key_mod.Key.paste_start, key_mod.next("\x1b[200~", &open_i).?);
            }
            key_mod.abandonSequence(case.marker[0..cut], .dropped);
            var buf: [64]u8 = undefined;
            @memcpy(buf[0..second_cut], tail[0..second_cut]);
            try std.testing.expectEqual(@as(usize, 0), key_mod.joinOrphanHead(&buf, second_cut));
            const rest = tail[second_cut..];
            @memcpy(buf[0..rest.len], rest);
            buf[rest.len] = 0x11;
            const n = key_mod.joinOrphanHead(&buf, rest.len + 1);
            var i: usize = 0;
            const expected: key_mod.Key = if (case.start) .paste_start else .paste_end;
            try std.testing.expectEqual(expected, key_mod.next(buf[0..n], &i).?);
            try std.testing.expectEqual(key_mod.Key{ .ctrl = 'q' }, key_mod.next(buf[0..n], &i).?);
            try std.testing.expectEqual(n, i);
        }
    };
    key_mod.resetInputState();
}

test "full input buffer recovers paste start before every payload byte" {
    key_mod.resetInputState();
    defer key_mod.resetInputState();
    key_mod.abandonSequence("\x1b[20", .dropped);
    var buf: [16 * 1024]u8 = undefined;
    @memset(&buf, 'x');
    @memcpy(buf[0..2], "0~");
    buf[2] = 0x11;
    buf[3] = 0x03;
    buf[4] = '\n';
    const n = key_mod.joinOrphanHead(&buf, buf.len);
    try std.testing.expectEqual(buf.len - 2, n);
    var i: usize = 0;
    try std.testing.expectEqual(key_mod.Key.paste_start, key_mod.next(buf[0..n], &i).?);
    try std.testing.expectEqual(key_mod.Key{ .ctrl = 'q' }, key_mod.next(buf[0..n], &i).?);
    try std.testing.expectEqual(key_mod.Key{ .ctrl = 'c' }, key_mod.next(buf[0..n], &i).?);
    try std.testing.expectEqual(key_mod.Key{ .char = '\n' }, key_mod.next(buf[0..n], &i).?);
    var xs: usize = 0;
    while (key_mod.next(buf[0..n], &i)) |k| {
        try std.testing.expectEqual(key_mod.Key{ .char = 'x' }, k);
        xs += 1;
    }
    try std.testing.expectEqual(buf.len - 5, xs);
    try std.testing.expectEqual(n, i);
}

test "invalid and oversized late tails fail closed and disarm" {
    key_mod.resetInputState();
    defer key_mod.resetInputState();
    key_mod.abandonSequence("\x1b[20", .dropped);
    var bad = [_]u8{ 'x', 0x11 };
    const bad_n = key_mod.joinOrphanHead(&bad, bad.len);
    var i: usize = 0;
    try std.testing.expectEqual(key_mod.Key{ .char = 'x' }, key_mod.next(bad[0..bad_n], &i).?);
    try std.testing.expectEqual(key_mod.Key{ .ctrl = 'q' }, key_mod.next(bad[0..bad_n], &i).?);
    try std.testing.expect(!key_mod.inPaste());

    key_mod.abandonSequence("\x1b[", .dropped);
    var oversized: [65]u8 = @splat('2');
    try std.testing.expectEqual(oversized.len, key_mod.joinOrphanHead(&oversized, oversized.len));
    i = 0;
    try std.testing.expectEqual(key_mod.Key{ .char = '2' }, key_mod.next(&oversized, &i).?);
    try std.testing.expect(!key_mod.inPaste());
}

test "a possible paste-start ESC cannot cancel live work before one second" {
    for (trajectories[1..]) |trajectory| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        const history_len = fixture.term.model.history.items.len;
        _ = fixture.term.feed("\x1b");
        for (1..stall.live_escape_stalls) |_| {
            try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
            try expectAlive(&fixture, trajectory);
        }
        try std.testing.expectEqual(Effect.stay, fixture.term.feed("[200~left\x11\x03\nright"));
        try std.testing.expectEqualStrings("left\nright", fixture.term.model.input.getValue());
        try std.testing.expectEqual(history_len, fixture.term.model.history.items.len);
        try expectAlive(&fixture, trajectory);
        _ = fixture.term.feed("\x1b[201~");
    }
}

test "live lone Escape is bounded while Ctrl-C and CSI-u Escape stay immediate" {
    for (trajectories[1..]) |trajectory| {
        var bounded = try Fixture.init(trajectory);
        defer bounded.deinit();
        _ = bounded.term.feed("\x1b");
        for (1..stall.live_escape_stalls) |_| try std.testing.expectEqual(stall.StallVerdict.wait, bounded.term.stallTimeout());
        try std.testing.expectEqual(stall.StallVerdict.escape_key, bounded.term.stallTimeout());
        if (trajectory == .live_turn) try std.testing.expect(bounded.term.model.cancel_requested);
        if (isBackground(trajectory)) try std.testing.expect(bounded.bg.?.cancelled);

        var ctrl_c = try Fixture.init(trajectory);
        defer ctrl_c.deinit();
        _ = ctrl_c.term.feed("\x03");
        if (trajectory == .live_turn) try std.testing.expect(ctrl_c.term.model.cancel_requested);
        if (isBackground(trajectory)) try std.testing.expect(ctrl_c.bg.?.cancelled);

        var kitty = try Fixture.init(trajectory);
        defer kitty.deinit();
        _ = kitty.term.feed("\x1b[27u");
        if (trajectory == .live_turn) try std.testing.expect(kitty.term.model.cancel_requested);
        if (isBackground(trajectory)) try std.testing.expect(kitty.bg.?.cancelled);
    }
}

const FullEventKind = enum { sgr, x10, kitty, osc };
const full_event_cases = [_]struct { head: []const u8, tail: []const u8, kind: FullEventKind }{
    .{ .head = "\x1b[<65;20", .tail = ";10M", .kind = .sgr },
    .{ .head = "\x1b[M", .tail = "`$$", .kind = .x10 },
    .{ .head = "\x1b[57350;", .tail = "1u", .kind = .kitty },
    .{ .head = "\x1b]11;rgb:f6", .tail = "/f6/f6\x07", .kind = .osc },
};

test "full reads recover framed events before remaining bytes on every trajectory" {
    for (trajectories) |trajectory| for (full_event_cases) |case| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        errdefer std.debug.print("full event failure: {s} / {s}\n", .{ @tagName(trajectory), @tagName(case.kind) });
        try fixture.term.model.input.setValue(if (case.kind == .kitty) "ab" else "seed:");
        fixture.term.model.scroll = 7;
        fixture.term.model.follow = false;
        fixture.term.model.theme_explicit = false;
        fixture.term.model.theme_id = .night;
        const history_len = fixture.term.model.history.items.len;
        _ = fixture.term.feed(case.head);
        try std.testing.expectEqual(case.head.len, fixture.term.pending);
        fixture.term.stallDropPending();

        var full: [16 * 1024]u8 = @splat(0x07);
        @memcpy(full[0..case.tail.len], case.tail);
        full[full.len - 1] = 'X';
        try std.testing.expectEqual(Effect.stay, fixture.term.feed(&full));
        try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
        switch (case.kind) {
            .sgr => {
                try std.testing.expectEqualStrings("seed:X", fixture.term.model.input.getValue());
                try std.testing.expectEqual(@as(usize, 4), fixture.term.model.scroll);
            },
            .x10 => {
                try std.testing.expectEqualStrings("seed:X", fixture.term.model.input.getValue());
                try std.testing.expectEqual(@as(usize, 10), fixture.term.model.scroll);
            },
            .kitty => try std.testing.expectEqualStrings("aXb", fixture.term.model.input.getValue()),
            .osc => {
                try std.testing.expectEqualStrings("seed:X", fixture.term.model.input.getValue());
                try std.testing.expectEqual(.day, fixture.term.model.theme_id);
            },
        }
        try std.testing.expectEqual(history_len, fixture.term.model.history.items.len);
        try expectAlive(&fixture, trajectory);
    };
}

test "one feed carries a 16KiB paste payload through its later terminator" {
    const start = "\x1b[200~";
    const end = "\x1b[201~";
    const payload: [16 * 1024]u8 = @splat('p');
    var wire: [payload.len + start.len + end.len]u8 = undefined;
    @memcpy(wire[0..start.len], start);
    @memcpy(wire[start.len .. start.len + payload.len], &payload);
    @memcpy(wire[start.len + payload.len ..], end);
    for (trajectories) |trajectory| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        const history_len = fixture.term.model.history.items.len;
        try std.testing.expectEqual(Effect.stay, fixture.term.feed(&wire));
        try std.testing.expectEqualStrings(&payload, fixture.term.model.input.getValue());
        try std.testing.expect(!fixture.term.model.pasting and !key_mod.inPaste());
        try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
        try std.testing.expectEqual(history_len, fixture.term.model.history.items.len);
        try expectAlive(&fixture, trajectory);
    }
}

test "feed stops at Ctrl-Q across a 16KiB+1 paste-start/paste-end wire" {
    const start = "\x1b[200~";
    const end = "\x1b[201~";
    const total = 16 * 1024 + 1;
    const payload_len = total - start.len - end.len - 2;
    var wire: [total]u8 = undefined;
    var at: usize = 0;
    @memcpy(wire[at .. at + start.len], start);
    at += start.len;
    @memset(wire[at .. at + payload_len], 'p');
    at += payload_len;
    @memcpy(wire[at .. at + end.len], end);
    at += end.len;
    wire[at] = 0x11; // Ctrl-Q: the last byte of the first 16KiB chunk
    wire[at + 1] = 'x'; // supplied after the effect; no tty queue exists here

    for (trajectories) |trajectory| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try std.testing.expectEqual(Effect.quit, fixture.term.feed(&wire));
        try std.testing.expectEqual(payload_len, fixture.term.model.input.getValue().len);
        try std.testing.expectEqualStrings(wire[start.len .. start.len + payload_len], fixture.term.model.input.getValue());
        try std.testing.expect(!fixture.term.model.pasting and !key_mod.inPaste());
    }
}
