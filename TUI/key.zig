//! Keyboard tokens. Understands classic CSI, SS3, and kitty CSI-u (Ghostty).

const std = @import("std");

/// Super/alt currently held, from kitty modifier-key events (Ghostty Cmd+Delete
/// often arrives as a bare DEL after Super-down).
pub var held: u32 = 0;

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
    var it = std.mem.splitScalar(u8, params, ';');
    const keys = it.next() orelse "";
    const code = leadingInt(keys);
    var shifted: u32 = 0;
    if (std.mem.indexOfScalar(u8, keys, ':')) |c| shifted = leadingInt(keys[c + 1 ..]);
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
        if (shift) return .{ .char = shiftedAscii(ch) };
        return .{ .char = ch };
    }
    if (code >= 57344 and code <= 57454) return .ignore; // functional block, handled upstream
    if (code >= 128 and code <= 0x10ffff) return .{ .codepoint = @intCast(code) };
    // Unknown code: inert. Only a real Esc (27) may become .escape.
    return .ignore;
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
