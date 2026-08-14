//! Keyboard tokens. Understands classic CSI and kitty CSI-u (Ghostty).

const std = @import("std");

/// Super/alt currently held, from kitty modifier-key events (Ghostty Cmd+Delete
/// often arrives as a bare DEL after Super-down).
var held: u32 = 0;

pub const Key = union(enum) {
    char: u8,
    ctrl: u8,
    ignore,
    enter,
    shift_enter,
    tab,
    shift_tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    f1,
    f2,
    paste_start,
    paste_end,
    delete_word,
    delete_to_start,
    delete_to_end,
    word_left,
    word_right,
    prev_turn,
    next_turn,
    delete,
    undo,
    mouse: Mouse,
};

pub const Mouse = struct {
    btn: u8,
    x: u16,
    y: u16,
    down: bool,
};

pub fn next(bytes: []const u8, i: *usize) ?Key {
    if (i.* >= bytes.len) return null;
    if (takeOrphanCsi(bytes, i)) |k| return k;
    const b = bytes[i.*];
    i.* += 1;
    if (b == 0x1b) return escapeSeq(bytes, i);
    if (b == 0x0d or b == 0x0a) return .enter;
    if (b == 0x09) return .tab;
    if (b == 0x7f or b == 0x08) {
        if (held & 8 != 0) return .delete_to_start;
        if (held & 2 != 0) return .delete_word;
        return .backspace;
    }
    if (b >= 1 and b <= 26) return .{ .ctrl = 'a' + (b - 1) };
    if (b >= 32) return .{ .char = b };
    return next(bytes, i);
}

fn escapeSeq(bytes: []const u8, i: *usize) ?Key {
    // Lone ESC at the end of a read is almost always a split CSI (mouse
    // flood, arrow). Do not treat it as the Escape key or the rest of the
    // sequence is inserted as letters on the next read.
    if (i.* >= bytes.len) {
        i.* -= 1;
        return null;
    }
    const c0 = bytes[i.*];
    if (c0 == 0x7f or c0 == 0x08) {
        i.* += 1;
        return .delete_word;
    }
    if (c0 == 'b') {
        i.* += 1;
        return .word_left;
    }
    if (c0 == 'f') {
        i.* += 1;
        return .word_right;
    }
    if (c0 == 0x0d or c0 == 0x0a) {
        i.* += 1;
        return .shift_enter;
    }
    if (c0 != '[') return .escape;
    i.* += 1;
    // X10 mouse (1000h without 1006): CSI M + 3 raw bytes.
    if (i.* < bytes.len and bytes[i.*] == 'M' and (i.* + 1 >= bytes.len or bytes[i.* + 1] != ';')) {
        if (i.* + 3 >= bytes.len) {
            i.* -= 2;
            return null;
        }
        i.* += 1;
        const btn = bytes[i.*];
        i.* += 1;
        const x = bytes[i.*];
        i.* += 1;
        const y = bytes[i.*];
        i.* += 1;
        return .{ .mouse = .{
            .btn = if (btn >= 32) btn - 32 else btn,
            .x = if (x >= 32) @as(u16, x) - 32 else x,
            .y = if (y >= 32) @as(u16, y) - 32 else y,
            .down = true,
        } };
    }
    const start = i.*;
    while (i.* < bytes.len) : (i.* += 1) {
        const c = bytes[i.*];
        if (c >= 0x40 and c <= 0x7e) {
            const final = c;
            const params = bytes[start..i.*];
            i.* += 1;
            return decodeCsi(params, final);
        }
    }
    // Incomplete CSI (split paste / arrow) — rewind so the next read can finish it.
    i.* = start - 2;
    return null;
}

fn decodeCsi(params: []const u8, final: u8) Key {
    const mods = csiMods(params);
    const alt = mods & 2 != 0;
    const ctrl = mods & 4 != 0;
    const super = mods & 8 != 0;
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => if (mods & 1 != 0) .next_turn else if (alt or ctrl) .word_right else if (super) .end else .right,
        'D' => if (mods & 1 != 0) .prev_turn else if (alt or ctrl) .word_left else if (super) .home else .left,
        'H' => .home,
        'F' => .end,
        'Z' => .shift_tab,
        '~' => switch (leadingInt(params)) {
            1, 7 => .home,
            3 => if (super) .delete_to_end else .delete,
            4, 8 => .end,
            5 => .page_up,
            6 => .page_down,
            200 => .paste_start,
            201 => .paste_end,
            27 => fixterms(params),
            else => .escape,
        },
        'u' => kitty(params),
        'P' => .f1,
        'Q' => .f2,
        'M', 'm' => sgrMouse(params, final == 'M'),
        else => .escape,
    };
}

fn csiMods(params: []const u8) u32 {
    const s = std.mem.indexOfScalar(u8, params, ';') orelse return 0;
    var mods = leadingInt(params[s + 1 ..]);
    if (mods > 0) mods -= 1;
    return mods;
}

/// CSI unicode[:shifted[:base]] ; mods[:event] ; text u
fn kitty(params: []const u8) Key {
    var it = std.mem.splitScalar(u8, params, ';');
    const keys = it.next() orelse "";
    const code = leadingInt(keys);
    var shifted: u32 = 0;
    if (std.mem.indexOfScalar(u8, keys, ':')) |c| shifted = leadingInt(keys[c + 1 ..]);
    var mods: u32 = 0;
    if (it.next()) |m| {
        mods = leadingInt(m);
        if (mods > 0) mods -= 1;
    }
    const text = leadingInt(it.next() orelse "");
    const ev = kittyEvent(params);
    if (code == 57444 or code == 57448) {
        if (ev == 3) held &= ~@as(u32, 8) else held |= 8;
        return .ignore;
    }
    if (code == 57443 or code == 57447) {
        if (ev == 3) held &= ~@as(u32, 2) else held |= 2;
        return .ignore;
    }
    if (code >= 57441 and code <= 57448) return .ignore;
    if (ev == 3) return .ignore;
    const shift = mods & 1 != 0;
    if (text >= 32 and text < 127) return mapCode(text, mods & ~@as(u32, 1));
    if (shift and shifted >= 32 and shifted < 127) return mapCode(shifted, mods & ~@as(u32, 1));
    return mapCode(code, mods);
}

fn kittyEvent(params: []const u8) u32 {
    const s = std.mem.indexOfScalar(u8, params, ';') orelse return 1;
    const rest = params[s + 1 ..];
    const c = std.mem.indexOfScalar(u8, rest, ':') orelse return 1;
    return leadingInt(rest[c + 1 ..]);
}

fn fixterms(params: []const u8) Key {
    var it = std.mem.splitScalar(u8, params, ';');
    _ = it.next();
    var mods = leadingInt(it.next() orelse "1");
    if (mods > 0) mods -= 1;
    return mapCode(leadingInt(it.next() orelse "0"), mods);
}

fn mapCode(code: u32, mods: u32) Key {
    const ctrl = mods & 4 != 0;
    const shift = mods & 1 != 0;
    const alt = mods & 2 != 0;
    const super = mods & 8 != 0 or held & 8 != 0;
    if (code == 13 or code == 10) return if (shift or alt) .shift_enter else .enter;
    if (code == 9) return if (shift) .shift_tab else .tab;
    if (code == 27) return .escape;
    if (code == 127 or code == 8) {
        if (super or ctrl) return .delete_to_start;
        if (alt or held & 2 != 0) return .delete_word;
        return .backspace;
    }
    if (code >= 1 and code <= 26) return .{ .ctrl = 'a' + @as(u8, @intCast(code - 1)) };
    if (code >= 32 and code < 127) {
        const ch: u8 = @intCast(code);
        if ((ctrl or super) and !shift and (ch == 'z' or ch == 'Z')) return .undo;
        if (ctrl and ch >= 'a' and ch <= 'z') return .{ .ctrl = ch };
        if (ctrl and ch >= 'A' and ch <= 'Z') return .{ .ctrl = ch + 32 };
        if (shift) return .{ .char = shiftedAscii(ch) };
        return .{ .char = ch };
    }
    return .escape;
}

/// Kitty/modifyOtherKeys report the unshifted key + Shift. US layout.
fn shiftedAscii(ch: u8) u8 {
    return switch (ch) {
        'a'...'z' => ch - 32,
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        '`' => '~',
        else => ch,
    };
}

fn sgrMouse(params: []const u8, down: bool) Key {
    if (params.len == 0 or params[0] != '<') return .escape;
    var it = std.mem.splitScalar(u8, params[1..], ';');
    const btn = leadingInt(it.next() orelse "0");
    const x = leadingInt(it.next() orelse "1");
    const y = leadingInt(it.next() orelse "1");
    return .{ .mouse = .{
        .btn = @intCast(@min(btn, 255)),
        .x = @intCast(@min(x, 999)),
        .y = @intCast(@min(y, 999)),
        .down = down,
    } };
}

/// CSI debris after a split ESC (`7444;9u`, `39;33;23M`, `3u`). Never a
/// letter and never Escape/Ctrl-C — those cancel or kill the turn.
fn takeOrphanCsi(bytes: []const u8, i: *usize) ?Key {
    const start = i.*;
    if (start >= bytes.len) return null;
    var j = start;
    if (bytes[j] == '<') j += 1;
    if (j >= bytes.len or bytes[j] < '0' or bytes[j] > '9') return null;
    var k = j;
    while (k < bytes.len) : (k += 1) {
        const c = bytes[k];
        if (c >= '0' and c <= '9') continue;
        if (c == ';' or c == ':') continue;
        if (c >= 0x40 and c <= 0x7e) {
            i.* = k + 1;
            if (c == 'M' or c == 'm') {
                const body = bytes[j..k];
                var it = std.mem.splitScalar(u8, body, ';');
                const btn = leadingInt(it.next() orelse "0");
                const x = leadingInt(it.next() orelse "1");
                const y = leadingInt(it.next() orelse "1");
                return .{ .mouse = .{
                    .btn = @intCast(@min(btn, 255)),
                    .x = @intCast(@min(x, 999)),
                    .y = @intCast(@min(y, 999)),
                    .down = c == 'M',
                } };
            }
            return .ignore;
        }
        return null;
    }
    return null;
}

fn leadingInt(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n * 10 + (c - '0');
    }
    return n;
}

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
    held = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57444;1:1u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.delete_to_start, next("\x7f", &i).?);
    held = 0;
}

test "split ESC does not become Escape" {
    var i: usize = 0;
    try std.testing.expect(next("\x1b", &i) == null);
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
