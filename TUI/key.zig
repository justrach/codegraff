//! Keyboard tokens. Understands classic CSI, SS3, and kitty CSI-u (Ghostty).

const std = @import("std");

/// Super/alt currently held, from kitty modifier-key events (Ghostty Cmd+Delete
/// often arrives as a bare DEL after Super-down).
var held: u32 = 0;

pub const Key = union(enum) {
    char: u8,
    /// Non-ASCII codepoint delivered via kitty CSI-u (é and friends).
    codepoint: u21,
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
    if (i.* >= bytes.len) {
        // Trailing lone ESC: the Esc key, or a sequence split across reads —
        // we can't know yet. Rewind; run.zig delivers a real .escape only if
        // nothing follows within its grace poll (#94).
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
    if (c0 == 0x1b) return .escape; // ESC ESC — deliver one, reparse the rest
    if (c0 == 'O') return ss3(bytes, i);
    if (c0 == ']' or c0 == 'P' or c0 == '_' or c0 == '^' or c0 == 'X') return stringSeq(bytes, i);
    if (c0 != '[') {
        // Unbound Alt+<char> chord: swallow both bytes so the char is not
        // typed into the composer behind a phantom Escape.
        i.* += 1;
        return .ignore;
    }
    i.* += 1;
    const start = i.*;
    while (i.* < bytes.len) : (i.* += 1) {
        const c = bytes[i.*];
        if (c >= 0x40 and c <= 0x7e) {
            const final = c;
            const params = bytes[start..i.*];
            i.* += 1;
            if (final == 'M' and params.len == 0) return x10Mouse(bytes, i, start);
            return decodeCsi(params, final);
        }
    }
    // Incomplete CSI (split paste / arrow) — rewind so the next read can finish it.
    i.* = start - 2;
    return null;
}

/// OSC/DCS/APC/PM/SOS reply on stdin (e.g. a color query answer) — consume
/// through BEL or ST so the payload is never typed into the prompt.
fn stringSeq(bytes: []const u8, i: *usize) ?Key {
    var j = i.* + 1;
    while (j < bytes.len) : (j += 1) {
        if (bytes[j] == 0x07) {
            i.* = j + 1;
            return .ignore;
        }
        if (bytes[j] == 0x1b) {
            if (j + 1 < bytes.len) {
                // ST (ESC \) ends the string; any other ESC starts a new
                // sequence — leave it for the next parse.
                i.* = if (bytes[j + 1] == '\\') j + 2 else j;
                return .ignore;
            }
            break; // ST split across reads — wait for the backslash
        }
    }
    i.* -= 1; // rewind to the ESC; the terminator is still in flight
    return null;
}

/// ESC O <final> — SS3 application keys (tmux/screen, macOS Terminal).
fn ss3(bytes: []const u8, i: *usize) ?Key {
    if (i.* + 1 >= bytes.len) {
        i.* -= 1; // rewind to the ESC; the final byte is still in flight
        return null;
    }
    const final = bytes[i.* + 1];
    i.* += 2;
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .f1,
        'Q' => .f2,
        'M' => .enter,
        else => .ignore,
    };
}

/// CSI M b x y — X10 mouse fallback when the terminal ignores SGR 1006.
/// Without this the three payload bytes are typed into the prompt as garbage
/// on every click and pointer move.
fn x10Mouse(bytes: []const u8, i: *usize, start: usize) ?Key {
    if (i.* + 3 > bytes.len) {
        i.* = start - 2;
        return null;
    }
    const b = bytes[i.*] -| 32;
    const x = bytes[i.* + 1] -| 32;
    const y = bytes[i.* + 2] -| 32;
    i.* += 3;
    return .{ .mouse = .{ .btn = b, .x = x, .y = y, .down = (b & 3) != 3 } };
}

fn decodeCsi(params: []const u8, final: u8) Key {
    const mods = csiMods(params);
    const alt = mods & 2 != 0;
    const ctrl = mods & 4 != 0;
    const super = mods & 8 != 0;
    // With kitty report-event-types on, releases arrive as `CSI 1;1:3 A` etc.
    // Acting on them double-fires every arrow / PgUp / Delete.
    if (final != 'u' and final != 'M' and final != 'm' and eventOf(params) == 3) return .ignore;
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
            11 => .f1,
            12 => .f2,
            200 => .paste_start,
            201 => .paste_end,
            27 => fixterms(params),
            // 2 (Insert), 13-24 (F3-F12) and friends: inert, never Escape.
            else => .ignore,
        },
        'u' => kitty(params),
        'P' => .f1,
        'Q' => .f2,
        'M', 'm' => sgrMouse(params, final == 'M'),
        // Unknown final — a stray reply or unsupported key, not the Esc key.
        else => .ignore,
    };
}

fn csiMods(params: []const u8) u32 {
    const s = std.mem.indexOfScalar(u8, params, ';') orelse return 0;
    var mods = leadingInt(params[s + 1 ..]);
    if (mods > 0) mods -= 1;
    return mods;
}

/// kitty event-type sub-param (field 2 after ':'): 1 press, 2 repeat, 3 release.
fn eventOf(params: []const u8) u32 {
    const s = std.mem.indexOfScalar(u8, params, ';') orelse return 1;
    const rest = params[s + 1 ..];
    const c = std.mem.indexOfScalar(u8, rest, ':') orelse return 1;
    return leadingInt(rest[c + 1 ..]);
}

/// CSI unicode ; mods u  — kitty/ghostty. mods bit 2 = ctrl, 1 = shift.
fn kitty(params: []const u8) Key {
    const code = leadingInt(params);
    var mods: u32 = 0;
    var has_mods = false;
    if (std.mem.indexOfScalar(u8, params, ';')) |s| {
        has_mods = true;
        mods = leadingInt(params[s + 1 ..]);
        if (mods > 0) mods -= 1; // kitty encodes mods+1
    }
    const ev = eventOf(params);
    if (code >= 57344 and code <= 57454) return functional(code, mods, ev);
    if (ev == 3) return .ignore;
    // A live key with an explicit mods field is ground truth for held
    // modifiers — resync so a missed release can't latch alt/super forever.
    if (has_mods) held = mods & 10;
    return mapCode(code, mods);
}

/// kitty functional block (57344-57454): modifiers, locks, F13+, media, keypad.
fn functional(code: u32, mods: u32, ev: u32) Key {
    // Real kitty table: 57443/57449 = L/R Alt, 57444/57450 = L/R Super.
    // (57447/57448 are Right-Shift/Right-Ctrl — NOT alt/super.)
    const bit: u32 = switch (code) {
        57443, 57449 => 2,
        57444, 57450 => 8,
        else => 0,
    };
    if (bit != 0) {
        if (ev == 3) held &= ~bit else held |= bit;
        return .ignore;
    }
    if (ev == 3) return .ignore;
    return switch (code) {
        57344 => .escape,
        57345, 57414 => if (mods & 3 != 0) .shift_enter else .enter,
        57346 => if (mods & 1 != 0) .shift_tab else .tab,
        57347 => mapCode(127, mods),
        57349, 57426 => .delete,
        57350, 57417 => .left,
        57351, 57418 => .right,
        57352, 57419 => .up,
        57353, 57420 => .down,
        57354, 57421 => .page_up,
        57355, 57422 => .page_down,
        57356, 57423 => .home,
        57357, 57424 => .end,
        // Locks, PrintScreen, remaining keypad, media, F13+: inert.
        else => .ignore,
    };
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
        return .{ .char = ch };
    }
    if (code >= 57344 and code <= 57454) return .ignore; // functional block, handled upstream
    if (code >= 128 and code <= 0x10ffff) return .{ .codepoint = @intCast(code) };
    // Unknown code: inert. Only a real Esc (27) may become .escape.
    return .ignore;
}

fn sgrMouse(params: []const u8, down: bool) Key {
    if (params.len == 0 or params[0] != '<') return .ignore;
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
    held = 0;
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
    held = 0;
    var i: usize = 0;
    // Right-Shift (57447) and Right-Ctrl (57448) must not latch held bits.
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
    held = 0;
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
    held = 8; // pretend we missed the Super release
    var i: usize = 0;
    try std.testing.expectEqual(Key.up, next("\x1b[57352u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = 'a' }, next("\x1b[97;1u", &i).?);
    try std.testing.expectEqual(@as(u32, 0), held);
    i = 0;
    try std.testing.expectEqual(Key.backspace, next("\x7f", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.enter, next("\x1b[57414u", &i).?); // KP_ENTER
    held = 0;
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
    held = 0;
}

test "OSC and APC replies on stdin are consumed, never typed" {
    var i: usize = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b]11;rgb:14/14/14\x07", &i).?);
    try std.testing.expectEqual(@as(usize, 18), i);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b_Gi=1;OK\x1b\\", &i).?);
    try std.testing.expectEqual(@as(usize, 11), i);
    i = 0;
    // Unterminated reply stays pending until the rest arrives.
    try std.testing.expect(next("\x1b]11;rgb:14", &i) == null);
    try std.testing.expectEqual(@as(usize, 0), i);
}
