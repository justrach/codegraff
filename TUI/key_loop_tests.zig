//! The read-loop half of key.zig's battery: everything that only shows up
//! ACROSS a read boundary. Parked out of key_tests.zig under the 600-line
//! ceiling.

const std = @import("std");
const key = @import("key.zig");
const Key = key.Key;
const next = key.next;

/// run.zig's read loop, minus the terminal: fixed input buffer, parse to
/// exhaustion, carry the unparsed tail into the next read. Regressions in the
/// carry/rewind contract only show up across a read boundary, so the debris
/// tests have to drive the real thing.
const Loop = struct {
    inbuf: [4096]u8 = undefined,
    pending: usize = 0,
    typed: std.array_list.Managed(u8),
    mice: usize = 0,
    paste_ends: usize = 0,
    bg_reports: usize = 0,

    fn init(a: std.mem.Allocator) Loop {
        key.resetInputState();
        return .{ .typed = std.array_list.Managed(u8).init(a) };
    }
    fn deinit(self: *Loop) void {
        self.typed.deinit();
    }

    fn read(self: *Loop, bytes: []const u8) !void {
        @memcpy(self.inbuf[self.pending .. self.pending + bytes.len], bytes);
        const n = key.joinOrphanHead(&self.inbuf, self.pending + bytes.len);
        var i: usize = 0;
        while (next(self.inbuf[0..n], &i)) |k| switch (k) {
            .char => |c| try self.typed.append(c),
            .codepoint => try self.typed.append('?'),
            .mouse => self.mice += 1,
            .escape => try self.typed.append('E'), // a phantom Escape cancels the turn
            .paste_end => self.paste_ends += 1,
            .bg_report => self.bg_reports += 1,
            else => {},
        };
        self.pending = if (i < n) blk: {
            const rest = n - i;
            std.mem.copyForwards(u8, self.inbuf[0..rest], self.inbuf[i..n]);
            break :blk rest;
        } else 0;
    }

    /// run.zig's `.escape_key` verdict: a lone pending ESC outlived the #94
    /// grace, so a real Escape is delivered — but the byte is carried, not
    /// thrown away.
    fn stallEscape(self: *Loop) !void {
        key.stashOrphanHead(self.inbuf[0..self.pending]);
        self.pending = 0;
        try self.typed.append('E');
    }

    /// run.zig's `.drop` verdict: carry the head, arm the sweeper, and close
    /// out a paste that can no longer be closed by its own marker.
    fn stallDrop(self: *Loop) void {
        key.stashOrphanHead(self.inbuf[0..self.pending]);
        self.pending = 0;
        key.armOrphan(true);
        if (key.inPaste()) {
            key.endPaste();
            self.paste_ends += 1;
        }
    }
};

test "SGR motion flood chopped at every byte offset never types a character" {
    key.armOrphan(false);
    // The exact bytes the user saw on the bottom row, plus one hover report.
    const flood = "\x1b[<39;7;32M\x1b[<39;4;32M\x1b[<39;3;33M\x1b[<39;1;33M\x1b[<35;80;24M";
    var cut: usize = 0;
    while (cut <= flood.len) : (cut += 1) {
        var loop = Loop.init(std.testing.allocator);
        defer loop.deinit();
        try loop.read(flood[0..cut]);
        try loop.read(flood[cut..]);
        try std.testing.expectEqualStrings("", loop.typed.items);
        try std.testing.expectEqual(@as(usize, 5), loop.mice);
        try std.testing.expectEqual(@as(usize, 0), loop.pending);
    }
}

test "debris after a dropped ESC head is consumed, not typed — even split again" {
    // run.zig drops a pending head that never completed and arms us; the tail
    // arrives alone, and may itself straddle the next read boundary.
    const tail = "39;7;32M\x1b[<39;4;32M";
    var cut: usize = 0;
    while (cut <= tail.len) : (cut += 1) {
        var loop = Loop.init(std.testing.allocator);
        defer loop.deinit();
        key.armOrphan(true);
        defer key.armOrphan(false);
        try loop.read(tail[0..cut]);
        try loop.read(tail[cut..]);
        try std.testing.expectEqualStrings("", loop.typed.items);
        try std.testing.expectEqual(@as(usize, 2), loop.mice);
    }
}

test "typed and pasted text survives the debris guard (0x1f, [12], 1e5)" {
    key.armOrphan(false);
    const cases = [_][]const u8{
        "const x = 0x1f;",
        "v1e5 [12] 2xM",
        "1.5]",
        "0x1f",
        "[12]",
        "1e5",
        "grep -n '39;7;32M' log", // debris-shaped text, but not at a read head
        "step 3 of 10 (2m30s)",
    };
    for (cases) |text| {
        var loop = Loop.init(std.testing.allocator);
        defer loop.deinit();
        try loop.read(text);
        try std.testing.expectEqualStrings(text, loop.typed.items);
        try std.testing.expectEqual(@as(usize, 0), loop.mice);
    }
    // Byte-at-a-time typing is the same string.
    var slow = Loop.init(std.testing.allocator);
    defer slow.deinit();
    for ("0x1f + [12] = 1e5") |c| try slow.read(&[_]u8{c});
    try std.testing.expectEqualStrings("0x1f + [12] = 1e5", slow.typed.items);
}

test "bracketed paste of debris-shaped code reaches the composer intact" {
    key.armOrphan(false);
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    try loop.read("\x1b[200~");
    try loop.read("39;7;32M and 0x1f");
    try loop.read("\x1b[201~");
    try std.testing.expectEqualStrings("39;7;32M and 0x1f", loop.typed.items);
}

test "a body that arrives after the escape_key verdict rejoins its ESC (#530)" {
    // ssh/tmux cuts right after the 0x1b of a sequence and the next segment is
    // >50ms late. run.zig delivers Escape (the E below) — but throwing the ESC
    // away typed the whole body into the composer on top of that.
    const bodies = [_][]const u8{ "[<35;80;24M", "[A", "[3~", "OA", "]11;rgb:14/14/14\x07" };
    for (bodies) |body| {
        var loop = Loop.init(std.testing.allocator);
        defer loop.deinit();
        try loop.read("\x1b");
        try loop.stallEscape();
        try loop.read(body);
        try std.testing.expectEqualStrings("E", loop.typed.items);
        try std.testing.expectEqual(@as(usize, 0), loop.pending);
    }
    // ...and the rejoined sequences are the real events, not merely swallowed.
    var mouse = Loop.init(std.testing.allocator);
    defer mouse.deinit();
    try mouse.read("\x1b");
    try mouse.stallEscape();
    try mouse.read("[<35;80;24M");
    try std.testing.expectEqual(@as(usize, 1), mouse.mice);
    var osc = Loop.init(std.testing.allocator);
    defer osc.deinit();
    try osc.read("\x1b");
    try osc.stallEscape();
    try osc.read("]11;rgb:14/14/14\x07");
    try std.testing.expectEqual(@as(usize, 1), osc.bg_reports);
}

test "a dropped head rejoins its tail whatever the split (#531/#546)" {
    // Every shape takeOrphanCsi structurally cannot sweep: a split ON the
    // separator, a non-mouse final, an OSC body.
    const cases = [_]struct { head: []const u8, tail: []const u8, mice: usize }{
        .{ .head = "\x1b[<35;80", .tail = ";24M", .mice = 1 },
        .{ .head = "\x1b[", .tail = "A", .mice = 0 },
        .{ .head = "\x1b[3", .tail = "~", .mice = 0 },
        .{ .head = "\x1b]11;rgb:1c", .tail = "1c/1c1c/1c1c\x07", .mice = 0 },
        .{ .head = "\x1b[<39;7;32", .tail = "M", .mice = 1 },
    };
    for (cases) |c| {
        var loop = Loop.init(std.testing.allocator);
        defer loop.deinit();
        try loop.read(c.head);
        loop.stallDrop();
        try loop.read(c.tail);
        try std.testing.expectEqualStrings("", loop.typed.items);
        try std.testing.expectEqual(c.mice, loop.mice);
        try std.testing.expectEqual(@as(usize, 0), loop.pending);
    }
}

test "a head whose tail never comes never eats the keystrokes that follow" {
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    try loop.read("\x1b[<35;80");
    loop.stallDrop();
    // The user gave up waiting and resumed typing: nothing is glued on, and
    // the armed sweeper must not swallow the words either.
    try loop.read("hello world");
    try std.testing.expectEqualStrings("hello world", loop.typed.items);
    try std.testing.expectEqual(@as(usize, 0), loop.pending);
}

test "the orphan arm covers exactly one lost head (#531)" {
    // Latched, the sweeper kept eating: `3u apples` reached the composer as
    // ` apples`, and a lone `3` was held pending until the loop dropped it.
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    key.armOrphan(true);
    try loop.read("39;7;32M");
    try std.testing.expectEqual(@as(usize, 1), loop.mice);
    try loop.read("3u apples");
    try std.testing.expectEqualStrings("3u apples", loop.typed.items);
    try std.testing.expectEqual(@as(usize, 0), loop.pending);

    var slow = Loop.init(std.testing.allocator);
    defer slow.deinit();
    key.armOrphan(true);
    try slow.read("39;7;32M");
    try slow.read("3");
    try std.testing.expectEqual(@as(usize, 0), slow.pending);
    try std.testing.expectEqualStrings("3", slow.typed.items);
    key.armOrphan(false);
}

test "a headless debris tail that opens on a separator is eaten, not typed (#546)" {
    // The head is gone for good (no carry): the sweeper is the only guard
    // left, and it must accept the `;`-led continuation while armed.
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    key.armOrphan(true);
    try loop.read(";24M");
    try std.testing.expectEqualStrings("", loop.typed.items);
    // Never a phantom click at (1,1): the coordinates cannot be reconstructed.
    try std.testing.expectEqual(@as(usize, 0), loop.mice);
    // Split again, on the final byte this time.
    var split = Loop.init(std.testing.allocator);
    defer split.deinit();
    key.armOrphan(true);
    try split.read("3");
    try split.read("u");
    try std.testing.expectEqualStrings("", split.typed.items);
    key.armOrphan(false);
    // Unarmed, the very same bytes are the user typing.
    var typed = Loop.init(std.testing.allocator);
    defer typed.deinit();
    try typed.read(";24M");
    try std.testing.expectEqualStrings(";24M", typed.typed.items);
}

test "a paste whose end marker is lost still closes (#532/#536/#548)" {
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    try loop.read("\x1b[200~");
    try loop.read("hello");
    try loop.read("\x1b[201");
    try std.testing.expect(key.inPaste());
    loop.stallDrop(); // ~2s of silence: give up on the marker
    try std.testing.expect(!key.inPaste());
    try std.testing.expectEqual(@as(usize, 1), loop.paste_ends);
    // The late `~` rejoins its head, so it is never typed either.
    try loop.read("~");
    try std.testing.expectEqualStrings("hello", loop.typed.items);
    // And the debris guard is live again, because the paste really did close.
    try loop.read("\x1b[<39;7;32M");
    try std.testing.expectEqualStrings("hello", loop.typed.items);
    try std.testing.expectEqual(@as(usize, 1), loop.mice);
}

test "an unterminated paste releases on the idle timeout (#548)" {
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    try loop.read("\x1b[200~body");
    try std.testing.expect(key.inPaste());
    key.endPaste(); // run.zig's paste_idle_ms sweep
    try std.testing.expect(!key.inPaste());
    // Back to a normal composer: debris is eaten again instead of typed.
    try loop.read("\x1b[<39;7;32M");
    try std.testing.expectEqualStrings("body", loop.typed.items);
    try std.testing.expectEqual(@as(usize, 1), loop.mice);
}

test "a real multi-read paste is untouched by any of the recovery paths" {
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    try loop.read("\x1b[200~");
    try loop.read("39;7;32M and 0x1f ");
    try loop.read("second chunk ;24M");
    try loop.read("\x1b[201~");
    try std.testing.expectEqualStrings("39;7;32M and 0x1f second chunk ;24M", loop.typed.items);
    try std.testing.expectEqual(@as(usize, 1), loop.paste_ends);
    try std.testing.expectEqual(@as(usize, 0), loop.mice);
    try std.testing.expect(!key.inPaste());
}
