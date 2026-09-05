//! Keyboard tokens. Understands classic CSI, SS3, and kitty CSI-u (Ghostty).

const std = @import("std");
const orphan = @import("key_orphan.zig");
const recover = @import("key_recover.zig");
const paste = @import("key_paste.zig");

/// Super/alt currently held, from kitty modifier-key events (Ghostty Cmd+Delete
/// often arrives as a bare DEL after Super-down).
pub var held: u32 = 0;

/// Inside `CSI 200~ … CSI 201~`. Every byte between them is literal text by
/// definition, and a long paste spans several reads — so the debris guard must
/// stay out of it or a chunk that happens to start `39;7;32M` gets eaten.
var in_paste: bool = false;
// A terminator makes subsequent keys in this read explicit user input.
var paste_ended_in_read = false;

pub fn inPaste() bool {
    return in_paste;
}

/// Close paste and ignored modifiers, also on lost-terminator recovery (#548).
pub fn endPaste() void {
    in_paste = false;
    abandonSequence("", .none);
}

/// Arm/disarm broad orphan recovery after the read loop drops a sequence.
pub fn armOrphan(on: bool) void {
    if (on) orphan.armDropped() else orphan.disarm();
}

/// Expire the short genuine-Escape carry without discarding a dropped head.
pub fn expireOrphanHead() void {
    orphan.expireHead();
}

/// Prepend a completing stashed head; every read spends this one-shot.
pub fn joinOrphanHead(buf: []u8, n: usize) usize {
    return orphan.joinHead(buf, n);
}

pub const SequenceRecovery = enum { none, escape, dropped };
/// Clear stale modifiers, changing orphan state only as requested by recovery.
pub fn abandonSequence(bytes: []const u8, recovery: SequenceRecovery) void {
    held = 0;
    if (recovery != .none) orphan.stashHead(bytes);
    switch (recovery) {
        .none => {},
        .escape => orphan.armEscape(),
        .dropped => orphan.armDropped(),
    }
}
/// A fresh input loop must not inherit any parser latch from the previous one.
pub fn resetInputState() void {
    abandonSequence("", .none);
    in_paste = false;
    paste.resetBurst();
    orphan.reset();
}

pub const Key = union(enum) {
    char: u8,
    /// Non-ASCII codepoint delivered via kitty CSI-u (é and friends).
    codepoint: u21,
    /// OSC 11 reply: the terminal's background RGB (auto light/dark).
    bg_report: [3]u8,
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
    if (i.* == 0) paste_ended_in_read = false;
    // Full reads recover orphan events ahead of their buffered payload.
    if (i.* == 0) if (orphan.takeRecoveredEvent()) |event| {
        orphan.end = std.math.maxInt(usize);
        return event;
    };
    if (i.* >= bytes.len) return null;
    // Orphan debris is only a read HEAD after a lost ESC. Digit runs elsewhere
    // are text: swallowing them ate `0x1f`, `[12]`, `1e5` and version strings.
    if (!in_paste and (i.* == 0 or i.* == orphan.end)) {
        switch (orphan.take(bytes, i)) {
            .took => |k| {
                orphan.end = i.*;
                // The arm covers exactly ONE lost head. Leaving it latched let
                // the sweeper keep eating whatever the user typed next — `3u
                // apples` reached the composer as ` apples`, and a lone `3`
                // was held pending until the stall path dropped it (#531).
                orphan.disarm();
                return k;
            },
            // Debris cut short at the read boundary: hold the bytes so the loop
            // carries them into the next read instead of typing the digits. The
            // arm must SURVIVE that carry — the rejoined fragment is the same
            // one lost head, and disarming here made `3` + `u` read as typed
            // text and type itself (#546).
            .partial => return null,
            .none => {},
        }
    }
    orphan.end = std.math.maxInt(usize);
    orphan.disarm();
    const b = bytes[i.*];
    i.* += 1;
    if (paste.takeSplitLf(b)) return .ignore;
    if (b == 0x1b) return escapeSeq(bytes, i);
    if (b == 0x0d or b == 0x0a) {
        // Newlines inside a paste are text, not the Enter/send key: bracketed,
        // a multiline dump in this read, or a run spanning reads (#643/#737).
        if (in_paste or (!paste_ended_in_read and (paste.burstActive() or paste.looksLikeBurst(bytes)))) {
            if (paste.pasteNewline(bytes, i, b)) |nl| return .{ .char = nl };
        }
        return .enter;
    }
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
    const double_esc = c0 == 0x1b;
    if (double_esc) {
        // Legacy Alt arrows are ESC ESC CSI. Keep both ESC bytes ambiguous
        // until the CSI is complete, otherwise the first one cancels work.
        if (i.* + 1 >= bytes.len) {
            i.* -= 1;
            return null;
        }
        if (bytes[i.* + 1] != '[') return .escape;
        i.* += 2;
    } else {
        if (c0 == 'O') return ss3(bytes, i);
        if (c0 == ']' or c0 == 'P' or c0 == '_' or c0 == '^' or c0 == 'X') return stringSeq(bytes, i);
        if (c0 != '[') {
            // Unbound Alt+<char> chord: swallow both bytes so the char is not
            // typed into the composer behind a phantom Escape.
            i.* += 1;
            return .ignore;
        }
        i.* += 1;
    }
    const start = i.*;
    while (i.* < bytes.len) : (i.* += 1) {
        const c = bytes[i.*];
        if (c == 0x1b) {
            abandonSequence("", .none);
            return .ignore; // reparse this event head
        }
        if (c >= 0x40 and c <= 0x7e) {
            const final = c;
            const params = bytes[start..i.*];
            i.* += 1;
            if (final == 'M' and params.len == 0) return x10Mouse(bytes, i, start);
            if (double_esc and !recover.legacyCsiBoundary(params, final, bytes, i.*)) return recover.legacyDoubleEscape(i, start);
            return decodeCsi(params, final);
        }
    }
    // Incomplete CSI (split paste / arrow) — rewind so the next read can finish it.
    i.* = start - @as(usize, if (double_esc) 3 else 2);
    return null;
}

/// OSC/DCS/APC/PM/SOS reply on stdin (e.g. a color query answer) — consume
/// through BEL or ST so the payload is never typed into the prompt.
/// Longest stdin reply we ever solicit (OSC 10/11 color answers are ~25
/// bytes; kitty acks are shorter). Anything bigger behind an unterminated
/// introducer is typed text, not a reply (#516).
const max_reply_pending = 128;

fn stringSeq(bytes: []const u8, i: *usize) ?Key {
    const start = i.*; // bytes[start] is ']' for OSC
    var j = i.* + 1;
    while (j < bytes.len) : (j += 1) {
        if (bytes[j] == 0x07) {
            const body = bytes[start + 1 .. j];
            i.* = j + 1;
            return oscReply(bytes[start], body);
        }
        if (bytes[j] == 0x1b) {
            if (j + 1 < bytes.len) {
                // ST (ESC \) ends the string; any other ESC starts a new
                // sequence — leave it for the next parse.
                if (bytes[j + 1] == '\\') {
                    const body = bytes[start + 1 .. j];
                    i.* = j + 2;
                    return oscReply(bytes[start], body);
                }
                abandonSequence("", .none);
                i.* = j;
                return .ignore;
            }
            break; // ST split across reads — wait for the backslash
        }
        if (bytes[j] == 0x0d or bytes[j] == 0x0a) {
            // Replies never carry CR/LF: this is typed text behind an
            // Alt+]/P/X/^/_ chord. Swallow only the introducer — like any
            // unbound alt-chord — so the text reparses instead of the
            // keyboard wedging until it is destroyed (#516).
            abandonSequence("", .none);
            i.* += 1;
            return .ignore;
        }
    }
    if (bytes.len - i.* > max_reply_pending) {
        abandonSequence("", .none);
        i.* += 1; // over any real reply's size — same chord recovery (#516)
        return .ignore;
    }
    i.* -= 1; // rewind to the ESC; the terminator is still in flight
    return null;
}

/// A terminated OSC body. The only reply we act on is OSC 11 (background
/// color, answering run.zig's startup query) — everything else stays inert.
pub fn oscReply(kind: u8, body: []const u8) Key {
    if (kind != ']') return .ignore;
    if (!std.mem.startsWith(u8, body, "11;")) return .ignore;
    const rgb = parseXColor(body[3..]) orelse return .ignore;
    return .{ .bg_report = rgb };
}

/// `rgb:RRRR/GGGG/BBBB` (high byte) or `rgb:RR/GG/BB`.
fn parseXColor(s: []const u8) ?[3]u8 {
    if (!std.mem.startsWith(u8, s, "rgb:")) return null;
    var out: [3]u8 = undefined;
    var it = std.mem.splitScalar(u8, s[4..], '/');
    for (0..3) |n| {
        const part = it.next() orelse return null;
        if (part.len != 2 and part.len != 4) return null;
        const v = std.fmt.parseInt(u16, part, 16) catch return null;
        out[n] = if (part.len == 4) @intCast(v >> 8) else @intCast(v);
    }
    if (it.next() != null) return null;
    return out;
}

/// ESC O <final> — SS3 application keys (tmux/screen, macOS Terminal).
fn ss3(bytes: []const u8, i: *usize) ?Key {
    if (i.* + 1 >= bytes.len) {
        i.* -= 1; // rewind to the ESC; the final byte is still in flight
        return null;
    }
    const final = bytes[i.* + 1];
    i.* += if (final == 0x1b) 1 else 2;
    if (final == 0x1b) {
        abandonSequence("", .none);
        return .ignore;
    }
    return decodeSs3(final);
}

pub fn decodeSs3(final: u8) Key {
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

/// CSI M b x y — X10 fallback when the terminal ignores SGR 1006.
fn x10Mouse(bytes: []const u8, i: *usize, start: usize) ?Key {
    const available_end = @min(i.* + 3, bytes.len);
    if (std.mem.indexOfScalar(u8, bytes[i.*..available_end], 0x1b)) |at| {
        i.* += at;
        abandonSequence("", .none);
        return .ignore;
    }
    if (i.* + 3 > bytes.len) {
        i.* = start - 2;
        return null;
    }
    const event = decodeX10(bytes[i.* .. i.* + 3]);
    i.* += 3;
    return event;
}

pub fn decodeX10(payload: []const u8) Key {
    std.debug.assert(payload.len == 3);
    const b = payload[0] -| 32;
    return .{ .mouse = .{
        .btn = b,
        .x = payload[1] -| 32,
        .y = payload[2] -| 32,
        .down = (b & 3) != 3,
    } };
}

pub fn decodeCsi(params: []const u8, final: u8) Key {
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
            200 => blk: {
                in_paste = true;
                abandonSequence("", .none);
                break :blk .paste_start;
            },
            201 => blk: {
                endPaste();
                paste.resetBurst(); // an explicit terminator ends the read heuristic too (#737)
                paste_ended_in_read = true;
                break :blk .paste_end;
            },
            27 => fixterms(params),
            // 2 (Insert), 13-24 (F3-F12) and friends: inert, never Escape.
            else => .ignore,
        },
        'u' => kitty(params),
        'P' => .f1,
        'Q' => .f2,
        'M', 'm' => if (std.mem.count(u8, params, ";") == 2) sgrMouse(params, final == 'M') else .ignore,
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
///
/// It lives in the MODIFIER field and nowhere else. Scanning the whole tail for
/// the first ':' read field 3 instead — the associated-text codepoints, which
/// are ':'-separated too — so `CSI 97;2;65:66u` reported event 66, and a text
/// field ending `:3` silently swallowed a real keypress as a release (#549).
fn eventOf(params: []const u8) u32 {
    const s = std.mem.indexOfScalar(u8, params, ';') orelse return 1;
    var field = params[s + 1 ..];
    if (std.mem.indexOfScalar(u8, field, ';')) |e| field = field[0..e];
    const c = std.mem.indexOfScalar(u8, field, ':') orelse return 1;
    return leadingInt(field[c + 1 ..]);
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
    // Outside paste, a live key is ground truth — resync so a missed
    // release can't latch alt/super forever. The ABSENT mods field is ground
    // truth too: kitty omits it exactly when no modifiers are down, so a
    // plain keypress must clear the latch. Before this, Cmd+Tab-ing away
    // mid-composition latched super (the release went to the other app) and
    // the next plain Backspace became Cmd+Backspace = delete-to-start,
    // silently wiping the composer.
    if (!in_paste) held = if (has_mods) mods & 10 else 0;
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
        if (!in_paste) held = if (ev == 3) held & ~bit else held | bit;
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
        // Numeric keypad. With `>11u` on, kitty reports these INSTEAD of the
        // plain ASCII byte, so leaving them unmapped dropped every keypad
        // digit and operator on the floor (#549).
        57399...57408 => .{ .char = '0' + @as(u8, @intCast(code - 57399)) },
        57409 => .{ .char = '.' },
        57410 => .{ .char = '/' },
        57411 => .{ .char = '*' },
        57412 => .{ .char = '-' },
        57413 => .{ .char = '+' },
        57415 => .{ .char = '=' },
        57416 => .{ .char = ',' },
        // KP_Insert (57425) and KP_Begin (57427) have no binding here and stay
        // inert exactly like CSI 2~ — never a phantom Escape. Locks,
        // PrintScreen, media and F13+ likewise.
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
    if (code == 13 or code == 10) {
        if (in_paste) return .{ .char = '\n' };
        return if (shift or alt) .shift_enter else .enter;
    }
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
    if (params.len < 6 or params[0] != '<' or params[1] == ';' or params[params.len - 1] == ';' or
        std.mem.indexOf(u8, params, ";;") != null or std.mem.indexOfScalar(u8, params, ':') != null) return .ignore;
    for (params[1..]) |c| if ((c < '0' or c > '9') and c != ';') return .ignore;
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

pub fn leadingInt(s: []const u8) u32 {
    // Saturating (#545): hostile 10+-digit params used to abort the TUI;
    // maxInt safely decodes as ignore/clamped coords. Used by key_orphan too.
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
    }
    return n;
}
