//! Adversarial bracketed-paste and nested-sequence coverage for #537.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const stall = @import("run_stall.zig");
const theme_mod = @import("theme.zig");
const Term = @import("sim.zig").Term;
const Effect = app.Effect;

const PasteTrajectory = enum { idle, live_turn, background_compact, background_bash, background_files };

const all_trajectories = [_]PasteTrajectory{ .idle, .live_turn, .background_compact, .background_bash, .background_files };

fn isBackground(trajectory: PasteTrajectory) bool {
    return switch (trajectory) {
        .background_compact, .background_bash, .background_files => true,
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

    fn init(trajectory: PasteTrajectory) !Fixture {
        var fixture: Fixture = undefined;
        fixture.bg = null;
        fixture.term.init(std.testing.allocator, 80, 24);
        errdefer fixture.term.deinit();
        try fixture.term.model.push(.user, "existing turn");
        switch (trajectory) {
            .idle => {},
            .live_turn => try installPending(&fixture.term),
            .background_compact => fixture.bg = try installBackground(&fixture.term, .compact),
            .background_bash => fixture.bg = try installBackground(&fixture.term, .bash),
            .background_files => fixture.bg = try installBackground(&fixture.term, .files),
        }
        fixture.term.model.scroll = 7;
        fixture.term.model.follow = false;
        fixture.term.model.selected = 3;
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

fn trajectoryName(trajectory: PasteTrajectory) []const u8 {
    return switch (trajectory) {
        .idle => "idle",
        .live_turn => "live-turn",
        .background_compact => "background-compact",
        .background_bash => "background-bash",
        .background_files => "background-files",
    };
}

/// Deliver a genuine Escape through the same 25ms stall policy as run.zig,
/// then advance beyond its 400ms carried-head window but not its 1s exact-tail
/// arm. A live operation uses the full bounded one-second ambiguity window.
fn armCarryExpiredEscape(term: *Term) !void {
    _ = term.feed("\x1b");
    var verdict: stall.StallVerdict = .wait;
    for (0..stall.live_escape_stalls) |_| {
        verdict = term.stallTimeout();
        if (verdict != .wait) break;
    }
    try std.testing.expectEqual(stall.StallVerdict.escape_key, verdict);
    term.now_ms += 401;
}

fn expectOperationAlive(fixture: *Fixture, trajectory: PasteTrajectory) !void {
    try std.testing.expect(!fixture.term.model.cancel_requested);
    if (trajectory == .live_turn) try std.testing.expect(fixture.term.model.pending != null);
    if (isBackground(trajectory)) try std.testing.expect(fixture.term.model.bg != null and !fixture.bg.?.cancelled);
}

const C0PasteCase = struct {
    name: []const u8,
    byte: u8,
    expected: []const u8,
};

// These are the actual single-byte tty encodings, not synthetic Key values.
// In particular, Ctrl-J is LF and is intentionally retained as paste newline.
const c0_paste_cases = [_]C0PasteCase{
    .{ .name = "Ctrl-Q", .byte = 0x11, .expected = "leftright" },
    .{ .name = "Ctrl-C", .byte = 0x03, .expected = "leftright" },
    .{ .name = "Ctrl-Z", .byte = 0x1a, .expected = "leftright" },
    .{ .name = "Ctrl-N", .byte = 0x0e, .expected = "leftright" },
    .{ .name = "Ctrl-J", .byte = 0x0a, .expected = "left\nright" },
    .{ .name = "Ctrl-K", .byte = 0x0b, .expected = "leftright" },
    .{ .name = "Tab", .byte = 0x09, .expected = "leftright" },
    .{ .name = "Backspace (DEL)", .byte = 0x7f, .expected = "leftright" },
    .{ .name = "Backspace (BS)", .byte = 0x08, .expected = "leftright" },
};

fn pasteInvariantFailure(failures: *usize, trajectory: PasteTrajectory, case: C0PasteCase, what: []const u8) void {
    failures.* += 1;
    std.debug.print("C0 paste failure [{s} / {s}]: {s}\n", .{ trajectoryName(trajectory), case.name, what });
}

// A bracketed paste is one draft on every TUI path. The raw byte is fed in its
// own read to exercise the runtime parser boundary while idle, during a turn,
// and during a background engine operation.
test "C0 bytes inside bracketed paste stay one draft on every TUI trajectory (#537)" {
    var failures: usize = 0;

    for (all_trajectories) |trajectory| {
        for (c0_paste_cases) |case| {
            var fixture = try Fixture.init(trajectory);
            defer fixture.deinit();
            const history_len = fixture.term.model.history.items.len;

            _ = fixture.term.feed("\x1b[200~left");
            const effect = fixture.term.feed(&[_]u8{case.byte});
            if (!fixture.term.model.pasting) pasteInvariantFailure(&failures, trajectory, case, "lost the paste latch before its terminator");
            _ = fixture.term.feed("right\x1b[201~");

            const m = &fixture.term.model;
            if (effect != .stay) pasteInvariantFailure(&failures, trajectory, case, "returned a non-stay effect");
            if (m.quit_requested) pasteInvariantFailure(&failures, trajectory, case, "requested quit");
            if (!std.mem.eql(u8, case.expected, m.input.getValue())) pasteInvariantFailure(&failures, trajectory, case, "changed the draft");
            if (m.steer_queue.items.len != 0) pasteInvariantFailure(&failures, trajectory, case, "queued a steer");
            if (m.history.items.len != history_len) pasteInvariantFailure(&failures, trajectory, case, "created a history entry");
            if (m.focus != .prompt) pasteInvariantFailure(&failures, trajectory, case, "moved focus");
            if (m.scroll != 7 or m.follow) pasteInvariantFailure(&failures, trajectory, case, "navigated the viewport");
            if (m.selected != 3) pasteInvariantFailure(&failures, trajectory, case, "changed the selected turn");
            if (m.new_arm_until_ms != 0) pasteInvariantFailure(&failures, trajectory, case, "armed Ctrl-N");
            if (m.pasting) pasteInvariantFailure(&failures, trajectory, case, "did not accept the paste terminator");
            if (m.cancel_requested) pasteInvariantFailure(&failures, trajectory, case, "cancelled an in-flight turn");
            if (trajectory == .live_turn and m.pending == null) pasteInvariantFailure(&failures, trajectory, case, "dropped the live turn");
            if (isBackground(trajectory) and (m.bg == null or fixture.bg.?.cancelled)) pasteInvariantFailure(&failures, trajectory, case, "cancelled the background operation");
        }
    }

    try std.testing.expectEqual(@as(usize, 0), failures);
}

const ParsedPasteCase = struct {
    name: []const u8,
    bytes: []const u8,
    middle: []const u8 = "left",
    final: []const u8 = "leftright",
    held: u32 = 0,
};

const parsed_paste_cases = [_]ParsedPasteCase{
    .{ .name = "SGR mouse", .bytes = "\x1b[<0;1;1M" },
    .{ .name = "X10 mouse", .bytes = "\x1b[M !!" },
    .{ .name = "background OSC", .bytes = "\x1b]11;rgb:f6/f6/f6\x07" },
    .{ .name = "kitty Super down", .bytes = "\x1b[57444;1:1u" },
    .{ .name = "kitty Super release", .bytes = "\x1b[57444;1:3u", .held = 8 },
    .{ .name = "kitty modified Backspace", .bytes = "\x1b[127;9u" },
    .{ .name = "kitty text", .bytes = "\x1b[97u", .middle = "lefta", .final = "leftaright", .held = 8 },
    .{ .name = "CSI arrow", .bytes = "\x1b[A" },
    .{ .name = "CSI Delete", .bytes = "\x1b[3~" },
    .{ .name = "SS3 arrow", .bytes = "\x1bOA" },
    .{ .name = "truncated CSI before SGR", .bytes = "\x1b[99;\x1b[<35;2;2M" },
    .{ .name = "truncated SS3 before SS3", .bytes = "\x1bO\x1bOA" },
};

fn expectParsedPasteSafe(fixture: *Fixture, trajectory: PasteTrajectory, case: ParsedPasteCase, cut: usize) !void {
    const m = &fixture.term.model;
    errdefer std.debug.print("parsed paste failure [{s} / {s} / split {d}]\n", .{ trajectoryName(trajectory), case.name, cut });

    try std.testing.expectEqual(Effect.stay, fixture.term.feed(case.bytes[0..cut]));
    try std.testing.expectEqual(Effect.stay, fixture.term.feed(case.bytes[cut..]));
    try std.testing.expect(m.pasting);
    try std.testing.expect(key_mod.inPaste());
    try std.testing.expectEqualStrings(case.middle, m.input.getValue());
    try std.testing.expectEqual(app.Overlay.help, m.overlay);
    try std.testing.expect(m.sel.active and m.sel.pressed);
    try std.testing.expectEqual(@as(theme_mod.Id, .night), m.theme_id);
    try std.testing.expectEqual(case.held, key_mod.held);
    try std.testing.expect(!m.cancel_requested);
    try std.testing.expect(!m.quit_requested);
    try std.testing.expectEqual(@as(usize, 0), m.steer_queue.items.len);
    if (trajectory == .live_turn) try std.testing.expect(m.pending != null);
    if (isBackground(trajectory)) try std.testing.expect(m.bg != null and !fixture.bg.?.cancelled);
}

// Complete controls and every possible read split have identical inert
// semantics inside a paste. Kitty text remains text, while mouse/background,
// modifier, CSI, and SS3 events cannot reach TUI actions or parser latches.
test "parsed controls inside paste are inert at every split on every TUI trajectory (#537)" {
    for (all_trajectories) |trajectory| {
        for (parsed_paste_cases) |case| {
            var cut: usize = 0;
            while (cut <= case.bytes.len) : (cut += 1) {
                var fixture = try Fixture.init(trajectory);
                defer fixture.deinit();
                _ = fixture.term.feed("\x1b[200~left");
                fixture.term.model.overlay = .help;
                fixture.term.model.sel.active = true;
                fixture.term.model.sel.pressed = true;
                fixture.term.model.theme_id = .night;
                key_mod.held = case.held;

                try expectParsedPasteSafe(&fixture, trajectory, case, cut);
                _ = fixture.term.feed("right\x1b[201~");
                try std.testing.expectEqualStrings(case.final, fixture.term.model.input.getValue());
                try std.testing.expect(!fixture.term.model.pasting);
                try std.testing.expect(!key_mod.inPaste());
                try std.testing.expectEqual(@as(u32, 0), key_mod.held);
            }
        }
    }
}

test "Escape remains the intentional bracketed paste hatch (#536/#548)" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    key_mod.held = 8;
    _ = term.feed("\x1b[200~draft");
    try std.testing.expectEqual(@as(u32, 0), key_mod.held);
    key_mod.held = 8;
    _ = term.press(.escape);
    try std.testing.expect(!term.model.pasting);
    try std.testing.expect(!key_mod.inPaste());
    try std.testing.expectEqual(@as(u32, 0), key_mod.held);
    try std.testing.expectEqualStrings("draft", term.model.input.getValue());
    // Once Escape intentionally closes the paste, a subsequent Ctrl-Q is an
    // ordinary key again; the hatch is not a permanent suppression switch.
    try std.testing.expectEqual(Effect.quit, term.feed("\x11"));
}

const ParserLoop = struct {
    inbuf: [256]u8 = undefined,
    pending: usize = 0,
    typed: std.array_list.Managed(u8),
    mice: usize = 0,
    arrows: usize = 0,

    fn init() ParserLoop {
        key_mod.resetInputState();
        return .{ .typed = std.array_list.Managed(u8).init(std.testing.allocator) };
    }

    fn deinit(self: *ParserLoop) void {
        self.typed.deinit();
        key_mod.resetInputState();
    }

    fn read(self: *ParserLoop, bytes: []const u8) !void {
        @memcpy(self.inbuf[self.pending .. self.pending + bytes.len], bytes);
        var i: usize = 0;
        const n = self.pending + bytes.len;
        while (key_mod.next(self.inbuf[0..n], &i)) |k| switch (k) {
            .char => |c| try self.typed.append(c),
            .mouse => self.mice += 1,
            .left, .right, .up, .down => self.arrows += 1,
            else => {},
        };
        self.pending = if (i < n) blk: {
            const rest = n - i;
            std.mem.copyForwards(u8, self.inbuf[0..rest], self.inbuf[i..n]);
            break :blk rest;
        } else 0;
    }
};

const EmbeddedEscapeCase = struct {
    name: []const u8,
    bytes: []const u8,
    mice: usize = 0,
    arrows: usize = 0,
};

const embedded_escape_cases = [_]EmbeddedEscapeCase{
    .{ .name = "CSI then SGR", .bytes = "left\x1b[99;\x1b[<35;2;2Mright", .mice = 1 },
    .{ .name = "X10 then CSI", .bytes = "left\x1b[M \x1b[Aright", .arrows = 1 },
    .{ .name = "CSI then CSI", .bytes = "left\x1b[99;\x1b[Aright", .arrows = 1 },
    .{ .name = "SS3 then SS3", .bytes = "left\x1bO\x1bOAright", .arrows = 1 },
    .{ .name = "SS3 then CSI", .bytes = "left\x1bO\x1b[Aright", .arrows = 1 },
};

// An ESC embedded in a truncated CSI/SS3 is a new event head. Only the old
// prefix is discarded; the new event is reparsed and its body never becomes
// composer text, regardless of the tty read boundary.
test "50-250ms ESC splits preserve state on every TUI trajectory (#537)" {
    const protected = [_]struct { tail: []const u8, ticks: usize }{
        .{ .tail = "[A", .ticks = 2 }, // exact CSI at about 50ms
        .{ .tail = "OA", .ticks = 10 }, // exact SS3 at about 250ms
        .{ .tail = "[57350;1u", .ticks = 10 }, // parameterized kitty
    };
    // Pre-arm two-Escape clear: a phantom Escape would visibly erase the draft.
    for (all_trajectories) |trajectory| for (protected) |case| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("draft survives");
        _ = fixture.term.press(.escape);
        _ = fixture.term.feed("\x1b");
        for (0..case.ticks) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        _ = fixture.term.feed(case.tail);
        try std.testing.expectEqualStrings("draft survives", fixture.term.model.input.getValue());
        try expectOperationAlive(&fixture, trajectory);
    };

    // The ambiguity remains bounded: an actual idle Escape lands on poll 12.
    var idle = try Fixture.init(.idle);
    defer idle.deinit();
    try idle.term.model.input.setValue("clear me");
    _ = idle.term.press(.escape);
    _ = idle.term.feed("\x1b");
    for (0..11) |_| try std.testing.expectEqual(stall.StallVerdict.wait, idle.term.stallTimeout());
    try std.testing.expectEqual(stall.StallVerdict.escape_key, idle.term.stallTimeout());
    try std.testing.expectEqualStrings("", idle.term.model.input.getValue());
}

const x10_report = "\x1b[M !!";

// X10's final-looking `M` is only the introducer for three payload bytes. Every
// read boundary and every reported 50–250ms delay must retain that whole body.
test "X10 mouse survives every split on every TUI trajectory and in paste (#537)" {
    const stalls = [_]usize{ 2, 4, 6, 8, 10 };
    for (all_trajectories) |trajectory| {
        for ([_]bool{ false, true }) |pasting| {
            for (stalls) |ticks| {
                for (0..x10_report.len + 1) |cut| {
                    var fixture = try Fixture.init(trajectory);
                    defer fixture.deinit();
                    errdefer std.debug.print("X10 failure [{s} / paste={} / split {d} / stalls {d}]\n", .{ trajectoryName(trajectory), pasting, cut, ticks });
                    if (pasting) {
                        _ = fixture.term.feed("\x1b[200~left");
                    } else if (trajectory == .idle) {
                        try fixture.term.model.input.setValue("draft survives");
                        _ = fixture.term.press(.escape); // a phantom Escape would clear it
                    }
                    try std.testing.expectEqual(Effect.stay, fixture.term.feed(x10_report[0..cut]));
                    for (0..ticks) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
                    try std.testing.expectEqual(Effect.stay, fixture.term.feed(x10_report[cut..]));
                    try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
                    if (pasting) {
                        try std.testing.expect(key_mod.inPaste() and fixture.term.model.pasting);
                        try std.testing.expectEqualStrings("left", fixture.term.model.input.getValue());
                        _ = fixture.term.feed("right\x1b[201~");
                        try std.testing.expectEqualStrings("leftright", fixture.term.model.input.getValue());
                    } else if (trajectory == .idle) {
                        try std.testing.expectEqualStrings("draft survives", fixture.term.model.input.getValue());
                    } else try std.testing.expectEqualStrings("", fixture.term.model.input.getValue());
                    try expectOperationAlive(&fixture, trajectory);
                }
            }
        }
    }
}

test "carry-expired mouse bodies recover at every split on every trajectory (#537)" {
    const bodies = [_][]const u8{ x10_report[1..], "[<35;80;24M" };
    for (all_trajectories) |trajectory| for (bodies) |body| for (0..body.len + 1) |cut| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("seed");
        try armCarryExpiredEscape(&fixture.term);
        _ = fixture.term.feed(body[0..cut]);
        _ = fixture.term.feed(body[cut..]);
        errdefer std.debug.print("late mouse failure [{s} / split {d}]\n", .{ trajectoryName(trajectory), cut });
        try std.testing.expectEqualStrings("seed", fixture.term.model.input.getValue());
        try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
        try expectOperationAlive(&fixture, trajectory);
    };
}

test "an ESC inside X10 payload reparses a paste terminator at every split (#537)" {
    const broken = "\x1b[M \x1b[201~";
    for (all_trajectories) |trajectory| for (0..broken.len + 1) |cut| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        _ = fixture.term.feed("\x1b[200~left");
        try std.testing.expectEqual(Effect.stay, fixture.term.feed(broken[0..cut]));
        for (0..10) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        try std.testing.expectEqual(Effect.stay, fixture.term.feed(broken[cut..]));
        errdefer std.debug.print("X10 paste terminator failure [{s} / split {d}]\n", .{ trajectoryName(trajectory), cut });
        try std.testing.expect(!key_mod.inPaste() and !fixture.term.model.pasting);
        try std.testing.expectEqualStrings("left", fixture.term.model.input.getValue());
        try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
        try expectOperationAlive(&fixture, trajectory);
    };
}

test "live state is latched at the ESC head across fast completion (#537)" {
    for (all_trajectories[1..]) |trajectory| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("draft survives");
        _ = fixture.term.press(.escape);
        _ = fixture.term.feed("\x1b");

        // The worker finishes before the first quiet tick. Restore the owned
        // fixture pointers only for teardown; policy must use the arrival-time
        // latch rather than these now-idle model fields.
        const pending = fixture.term.model.pending;
        const bg = fixture.term.model.bg;
        fixture.term.model.pending = null;
        fixture.term.model.bg = null;
        defer {
            fixture.term.model.pending = pending;
            fixture.term.model.bg = bg;
        }
        for (0..12) |_| try std.testing.expectEqual(stall.StallVerdict.wait, fixture.term.stallTimeout());
        _ = fixture.term.feed("[A");
        try std.testing.expectEqualStrings("draft survives", fixture.term.model.input.getValue());
        if (fixture.bg) |op| try std.testing.expect(!op.cancelled);
    }
}

test "carry-expired paste start latches parser and model before same-read controls (#537)" {
    for (all_trajectories) |trajectory| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("seed:");
        const history_len = fixture.term.model.history.items.len;
        try armCarryExpiredEscape(&fixture.term);

        const effect = fixture.term.feed("[200~left\x11\x03\nright");
        errdefer std.debug.print("late paste failure [{s}]\n", .{trajectoryName(trajectory)});
        try std.testing.expectEqual(Effect.stay, effect);
        try std.testing.expect(key_mod.inPaste());
        try std.testing.expect(fixture.term.model.pasting);
        try std.testing.expectEqualStrings("seed:left\nright", fixture.term.model.input.getValue());
        try std.testing.expect(!fixture.term.model.quit_requested);
        try std.testing.expectEqual(history_len, fixture.term.model.history.items.len);
        try expectOperationAlive(&fixture, trajectory);

        _ = fixture.term.feed("\x1b[201~");
        try std.testing.expect(!key_mod.inPaste());
        try std.testing.expect(!fixture.term.model.pasting);
    }
}

test "carry-expired exact tails stay text while kitty and OSC remain events (#537)" {
    const exact = [_]struct { tail: []const u8, expected: []const u8 }{
        .{ .tail = "[D", .expected = "ab[D" },
        .{ .tail = "OD", .expected = "abOD" },
    };
    for (all_trajectories) |trajectory| {
        for (exact) |case| {
            var fixture = try Fixture.init(trajectory);
            defer fixture.deinit();
            try fixture.term.model.input.setValue("ab");
            try armCarryExpiredEscape(&fixture.term);
            _ = fixture.term.feed(case.tail);
            try std.testing.expectEqualStrings(case.expected, fixture.term.model.input.getValue());
            try expectOperationAlive(&fixture, trajectory);
        }
        var kitty = try Fixture.init(trajectory);
        defer kitty.deinit();
        try kitty.term.model.input.setValue("ab");
        try armCarryExpiredEscape(&kitty.term);
        _ = kitty.term.feed("[57350;1uX");
        try std.testing.expectEqualStrings("aXb", kitty.term.model.input.getValue());
        try expectOperationAlive(&kitty, trajectory);

        var osc = try Fixture.init(trajectory);
        defer osc.deinit();
        try osc.term.model.input.setValue("osc:");
        osc.term.model.theme_explicit = false;
        osc.term.model.theme_id = .night;
        try armCarryExpiredEscape(&osc.term);
        _ = osc.term.feed("]11;rgb:f6/f6/f6\x07X");
        try std.testing.expectEqualStrings("osc:X", osc.term.model.input.getValue());
        try std.testing.expectEqual(theme_mod.Id.day, osc.term.model.theme_id);
        try expectOperationAlive(&osc, trajectory);
    }
}

test "50ms byte-read human text survives carry-expired Escape on every trajectory (#537)" {
    const human = [_][]const u8{ "[Alice]", "[Home]", "[Down]", "3u apples", "[3~ apples" };
    for (all_trajectories) |trajectory| for (human) |text| {
        var fixture = try Fixture.init(trajectory);
        defer fixture.deinit();
        try fixture.term.model.input.setValue("seed:");
        try armCarryExpiredEscape(&fixture.term);
        for (text) |c| {
            _ = fixture.term.feed(&[_]u8{c});
            fixture.term.now_ms += 50;
        }
        const value = fixture.term.model.input.getValue();
        errdefer std.debug.print("human text failure [{s} / {s}]: {s}\n", .{ trajectoryName(trajectory), text, value });
        try std.testing.expect(std.mem.startsWith(u8, value, "seed:"));
        try std.testing.expectEqualStrings(text, value["seed:".len..]);
        try std.testing.expectEqual(@as(usize, 0), fixture.term.pending);
        try expectOperationAlive(&fixture, trajectory);
    };
}

test "abandoned kitty releases clear Super before a bare DEL (#537)" {
    const super_down = "\x1b[57444;1:1u";
    {
        var term: Term = undefined;
        term.init(std.testing.allocator, 80, 24);
        defer term.deinit();
        _ = term.typeText("draft");
        _ = term.feed(super_down);
        try std.testing.expectEqual(@as(u32, 8), key_mod.held);
        // The release lost its final `u`; a new ESC replaces that truncated
        // sequence and must also clear the modifier it can no longer release.
        _ = term.feed("\x1b[57444;1:3\x1b[A");
        try std.testing.expectEqual(@as(u32, 0), key_mod.held);
        _ = term.feed("\x7f");
        try std.testing.expectEqualStrings("draf", term.model.input.getValue());
    }
    {
        var term: Term = undefined;
        term.init(std.testing.allocator, 80, 24);
        defer term.deinit();
        _ = term.typeText("draft");
        _ = term.feed(super_down);
        var wedge: [16 * 1024]u8 = undefined;
        const lost_release = "\x1b[57444;1:3";
        @memcpy(wedge[0..lost_release.len], lost_release);
        @memset(wedge[lost_release.len..], '1');
        _ = term.feed(&wedge);
        try std.testing.expectEqual(wedge.len, term.pending);
        try std.testing.expectEqual(@as(u32, 8), key_mod.held);
        // The next read abandons the full production-sized pending wedge, but
        // keeps scoped orphan recovery alive while DEL reparses as Backspace.
        _ = term.feed("\x7f");
        try std.testing.expectEqual(@as(u32, 0), key_mod.held);
        try std.testing.expectEqual(@as(usize, 0), term.pending);
        try std.testing.expectEqualStrings("draf", term.model.input.getValue());
    }
    {
        var term: Term = undefined;
        term.init(std.testing.allocator, 80, 24);
        defer term.deinit();
        _ = term.feed("\x1b[200~left");
        var wedge: [16 * 1024]u8 = undefined;
        @memcpy(wedge[0..2], "\x1b[");
        @memset(wedge[2..], '1');
        _ = term.feed(&wedge);
        key_mod.held = 8;
        // Full-wedge cleanup is scoped: Ctrl-Q stays inert inside the paste,
        // and the real terminator still owns both parser and model teardown.
        try std.testing.expectEqual(Effect.stay, term.feed("\x11"));
        try std.testing.expect(key_mod.inPaste() and term.model.pasting);
        try std.testing.expectEqual(@as(u32, 0), key_mod.held);
        _ = term.feed("\x1b[201~");
        try std.testing.expect(!key_mod.inPaste() and !term.model.pasting);
        try std.testing.expectEqualStrings("left", term.model.input.getValue());
    }
}

test "CSI and SS3 reparse embedded Escape at every split (#537)" {
    for (embedded_escape_cases) |case| {
        var cut: usize = 0;
        while (cut <= case.bytes.len) : (cut += 1) {
            var loop = ParserLoop.init();
            defer loop.deinit();
            errdefer std.debug.print("embedded Escape failure [{s} / split {d}]\n", .{ case.name, cut });
            try loop.read(case.bytes[0..cut]);
            try loop.read(case.bytes[cut..]);
            try std.testing.expectEqualStrings("leftright", loop.typed.items);
            try std.testing.expectEqual(case.mice, loop.mice);
            try std.testing.expectEqual(case.arrows, loop.arrows);
            try std.testing.expectEqual(@as(usize, 0), loop.pending);
        }
    }
}
