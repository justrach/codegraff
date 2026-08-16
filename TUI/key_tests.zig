//! key.zig's test battery, parked here under the 600-line ceiling.

const std = @import("std");
const key = @import("key.zig");
const Key = key.Key;
const next = key.next;

test "next: letters, enter, ctrl-c, arrows, kitty ctrl-p" {
    var i: usize = 0;
    try std.testing.expectEqual(Key{ .char = 'a' }, next("a", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.enter, next("\r", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .ctrl = 'c' }, next("\x03", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.up, next("\x1b[A", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.shift_tab, next("\x1b[Z", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .ctrl = 'p' }, next("\x1b[112;5u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '/' }, next("/", &i).?);
    i = 0;
    const click = next("\x1b[<0;12;8M", &i).?;
    try std.testing.expect(click == .mouse);
    try std.testing.expectEqual(@as(u8, 0), click.mouse.btn);
    try std.testing.expectEqual(@as(u16, 12), click.mouse.x);
    try std.testing.expectEqual(@as(u16, 8), click.mouse.y);
    try std.testing.expect(click.mouse.down);
    i = 0;
    try std.testing.expectEqual(Key.paste_start, next("\x1b[200~", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.paste_end, next("\x1b[201~", &i).?);
    i = 0;
    try std.testing.expect(next("\x1b[20", &i) == null);
    try std.testing.expectEqual(@as(usize, 0), i);
    i = 0;
    try std.testing.expectEqual(Key{ .char = 0xc3 }, next("\xc3\xa9", &i).?);
    try std.testing.expectEqual(Key{ .char = 0xa9 }, next("\xc3\xa9", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.delete_to_start, next("\x1b[127;9u", &i).?);
    key.held = 0;
    i = 0;
    try std.testing.expectEqual(Key.delete_word, next("\x1b\x7f", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.prev_turn, next("\x1b[1;2D", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.next_turn, next("\x1b[1;2C", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.word_left, next("\x1b[1;3D", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.home, next("\x1b[1;9D", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.shift_enter, next("\x1b[13;2u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.shift_enter, next("\x1b\r", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.delete_to_start, next("\x1b[27;9;127~", &i).?);
    i = 0;
    key.held = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57444;1:1u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.delete_to_start, next("\x7f", &i).?);
    key.held = 0;
}

test "lone trailing ESC stays pending, not an instant Escape" {
    var i: usize = 0;
    try std.testing.expect(next("\x1b", &i) == null);
    try std.testing.expectEqual(@as(usize, 0), i);
}

test "ESC ESC delivers an Escape and leaves the second pending" {
    var i: usize = 0;
    try std.testing.expectEqual(Key.escape, next("\x1b\x1b", &i).?);
    try std.testing.expectEqual(@as(usize, 1), i);
    try std.testing.expect(next("\x1b\x1b", &i) == null);
    try std.testing.expectEqual(@as(usize, 1), i);
}

test "kitty release events never fire keys" {
    var i: usize = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[1;1:3A", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[3;1:3~", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[5;1:3~", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[97;1:3u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.up, next("\x1b[1;1:2A", &i).?); // repeat acts
}

test "right-side modifiers follow the real kitty table, never Escape" {
    key.held = 0;
    var i: usize = 0;
    // Right-Shift (57447) and Right-Ctrl (57448) must not latch key.held bits.
    try std.testing.expectEqual(Key.ignore, next("\x1b[57447;1:1u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57448;1:1u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.backspace, next("\x7f", &i).?);
    // Right-Alt (57449) latches alt; its release clears it.
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57449;1:1u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.delete_word, next("\x7f", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57449;1:3u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.backspace, next("\x7f", &i).?);
    key.held = 0;
}

test "unknown keys and replies are inert, never Escape" {
    var i: usize = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57376u", &i).?); // F13
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[17~", &i).?); // F6
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[2~", &i).?); // Insert
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[?1;2c", &i).?); // DA reply
}

test "kitty functional arrows and keypad map; a stale super latch resyncs" {
    key.held = 8; // pretend we missed the Super release
    var i: usize = 0;
    try std.testing.expectEqual(Key.up, next("\x1b[57352u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = 'a' }, next("\x1b[97;1u", &i).?);
    try std.testing.expectEqual(@as(u32, 0), key.held);
    i = 0;
    try std.testing.expectEqual(Key.backspace, next("\x7f", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.enter, next("\x1b[57414u", &i).?); // KP_ENTER
    key.held = 0;
}

test "SS3 application keys and unbound alt-chords" {
    var i: usize = 0;
    try std.testing.expectEqual(Key.up, next("\x1bOA", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.f1, next("\x1bOP", &i).?);
    i = 0;
    // Split SS3 stays pending.
    try std.testing.expect(next("\x1bO", &i) == null);
    try std.testing.expectEqual(@as(usize, 0), i);
    i = 0;
    // Unbound Alt+p swallows both bytes — no phantom Escape, no stray 'p'.
    try std.testing.expectEqual(Key.ignore, next("\x1bp", &i).?);
    try std.testing.expectEqual(@as(usize, 2), i);
    try std.testing.expect(next("\x1bp", &i) == null);
}

test "X10 mouse fallback consumes its payload instead of typing it" {
    var i: usize = 0;
    const ev = next("\x1b[M\x20\x2c\x28", &i).?;
    try std.testing.expect(ev == .mouse);
    try std.testing.expectEqual(@as(u8, 0), ev.mouse.btn);
    try std.testing.expectEqual(@as(u16, 12), ev.mouse.x);
    try std.testing.expectEqual(@as(u16, 8), ev.mouse.y);
    try std.testing.expect(ev.mouse.down);
    try std.testing.expectEqual(@as(usize, 6), i);
    i = 0;
    // Split short — wait for the rest.
    try std.testing.expect(next("\x1b[M\x20", &i) == null);
    try std.testing.expectEqual(@as(usize, 0), i);
}

test "non-ASCII CSI-u codepoints type text instead of Escape" {
    var i: usize = 0;
    try std.testing.expectEqual(Key{ .codepoint = 0xe9 }, next("\x1b[233;1u", &i).?);
    key.held = 0;
}

test "OSC and APC replies on stdin are consumed, never typed" {
    var i: usize = 0;
    // OSC 11 replies now carry the terminal background (auto light/dark).
    try std.testing.expectEqual(Key{ .bg_report = .{ 0x14, 0x14, 0x14 } }, next("\x1b]11;rgb:14/14/14\x07", &i).?);
    try std.testing.expectEqual(@as(usize, 18), i);
    i = 0;
    // 4-digit form takes the high byte; other OSC bodies stay inert.
    try std.testing.expectEqual(Key{ .bg_report = .{ 0xf6, 0xf6, 0xf6 } }, next("\x1b]11;rgb:f6f6/f6f6/f6f6\x1b\\", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b]10;rgb:14/14/14\x07", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b_Gi=1;OK\x1b\\", &i).?);
    try std.testing.expectEqual(@as(usize, 11), i);
    i = 0;
    // Unterminated reply stays pending until the rest arrives.
    try std.testing.expect(next("\x1b]11;rgb:14", &i) == null);
    try std.testing.expectEqual(@as(usize, 0), i);
}

test "orphan SGR mouse is never inserted as letters" {
    var i: usize = 0;
    const k = next("39;33;23M", &i).?;
    try std.testing.expect(k == .mouse);
    try std.testing.expectEqual(@as(u8, 39), k.mouse.btn);
    try std.testing.expectEqual(@as(u16, 33), k.mouse.x);
    try std.testing.expectEqual(@as(usize, 9), i);
    i = 0;
    const k2 = next("<64;4;8Mhi", &i).?;
    try std.testing.expect(k2 == .mouse);
    try std.testing.expectEqual(@as(u8, 64), k2.mouse.btn);
    try std.testing.expectEqual(Key{ .char = 'h' }, next("<64;4;8Mhi", &i).?);
}

test "SGR mouse flood does not leak digits" {
    const seq = "\x1b[<39;33;23M\x1b[<39;26;20M\x1b[<39;25;19M";
    var i: usize = 0;
    var n: usize = 0;
    while (next(seq, &i)) |k| {
        try std.testing.expect(k == .mouse);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(seq.len, i);
}

test "orphan kitty CSI-u is ignore, never letters or Escape" {
    var i: usize = 0;
    const seq = "3u7444;9u7441;10u";
    // `3u` carries neither a `<` nor a `;`, so on its own it reads as somebody
    // typing. The loop arms us when it drops a truncated sequence — which is
    // the only way this tail can exist.
    key.orphan_armed = true;
    defer key.orphan_armed = false;
    var n: usize = 0;
    while (next(seq, &i)) |k| {
        try std.testing.expect(k == .ignore);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(seq.len, i);
    i = 0;
    try std.testing.expectEqual(Key{ .char = 'h' }, next("hi", &i).?);
}

/// run.zig's read loop, minus the terminal: fixed input buffer, parse to
/// exhaustion, carry the unparsed tail into the next read. Regressions in the
/// carry/rewind contract only show up across a read boundary, so the debris
/// tests have to drive the real thing.
const Loop = struct {
    inbuf: [4096]u8 = undefined,
    pending: usize = 0,
    typed: std.array_list.Managed(u8),
    mice: usize = 0,

    fn init(a: std.mem.Allocator) Loop {
        key.resetInputState();
        return .{ .typed = std.array_list.Managed(u8).init(a) };
    }
    fn deinit(self: *Loop) void {
        self.typed.deinit();
    }

    fn read(self: *Loop, bytes: []const u8) !void {
        @memcpy(self.inbuf[self.pending .. self.pending + bytes.len], bytes);
        const n = self.pending + bytes.len;
        var i: usize = 0;
        while (next(self.inbuf[0..n], &i)) |k| switch (k) {
            .char => |c| try self.typed.append(c),
            .codepoint => try self.typed.append('?'),
            .mouse => self.mice += 1,
            .escape => try self.typed.append('E'), // a phantom Escape cancels the turn
            else => {},
        };
        self.pending = if (i < n) blk: {
            const rest = n - i;
            std.mem.copyForwards(u8, self.inbuf[0..rest], self.inbuf[i..n]);
            break :blk rest;
        } else 0;
    }
};

test "SGR motion flood chopped at every byte offset never types a character" {
    key.orphan_armed = false;
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
        key.orphan_armed = true;
        defer key.orphan_armed = false;
        try loop.read(tail[0..cut]);
        try loop.read(tail[cut..]);
        try std.testing.expectEqualStrings("", loop.typed.items);
        try std.testing.expectEqual(@as(usize, 2), loop.mice);
    }
}

test "typed and pasted text survives the debris guard (0x1f, [12], 1e5)" {
    key.orphan_armed = false;
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
    key.orphan_armed = false;
    var loop = Loop.init(std.testing.allocator);
    defer loop.deinit();
    try loop.read("\x1b[200~");
    try loop.read("39;7;32M and 0x1f");
    try loop.read("\x1b[201~");
    try std.testing.expectEqualStrings("39;7;32M and 0x1f", loop.typed.items);
}

test "Shift+9 is open-paren, Shift+0 is close-paren" {
    var i: usize = 0;
    try std.testing.expectEqual(Key{ .char = '(' }, next("\x1b[57;2u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = ')' }, next("\x1b[48;2u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '(' }, next("\x1b[57:40;2u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '(' }, next("\x1b[57;2;40u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '!' }, next("\x1b[49;2u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = 'A' }, next("\x1b[97;2u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '(' }, next("\x1b[27;2;57~", &i).?);
}

test "a plain CSI-u keypress clears a stale super latch — Backspace stays Backspace" {
    // Cmd+Tab mid-composition: the super PRESS arrives, focus leaves, the
    // RELEASE goes to the other app. Typing resumes with plain CSI-u keys
    // (no mods field). Those must resync held to 0, or the next Backspace
    // reads as Cmd+Backspace = delete_to_start and wipes the composer.
    key.held = 8; // stale Super
    var i: usize = 0;
    try std.testing.expectEqual(Key{ .char = 'h' }, next("\x1b[104u", &i).?);
    try std.testing.expectEqual(@as(u32, 0), key.held);
    i = 0;
    try std.testing.expectEqual(Key.backspace, next("\x7f", &i).?);
    // Stale alt is the same class of bug (backspace -> delete_word).
    key.held = 2;
    i = 0;
    try std.testing.expectEqual(Key{ .char = 'a' }, next("\x1b[97u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.backspace, next("\x7f", &i).?);
    key.held = 0;
}

test "typed text behind an Alt+] chord recovers instead of wedging (#516)" {
    // CR proves it is not a reply: the introducer is swallowed as a chord
    // and the sentence reparses as ordinary keys, Enter included.
    var i: usize = 0;
    const bytes = "\x1b]fix it\r";
    try std.testing.expectEqual(Key.ignore, next(bytes, &i).?);
    try std.testing.expectEqual(Key{ .char = 'f' }, next(bytes, &i).?);
    var last: Key = .ignore;
    while (next(bytes, &i)) |k| last = k;
    try std.testing.expectEqual(Key.enter, last);
    // Longer than any real reply — recover even without CR/LF.
    var big: [140]u8 = undefined;
    big[0] = 0x1b;
    big[1] = 'P';
    @memset(big[2..], 'a');
    i = 0;
    try std.testing.expectEqual(Key.ignore, next(&big, &i).?);
    try std.testing.expectEqual(Key{ .char = 'a' }, next(&big, &i).?);
}
