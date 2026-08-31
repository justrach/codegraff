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

test "ESC ESC CSI is Alt+arrow, not Escape (#524)" {
    var i: usize = 0;
    try std.testing.expectEqual(Key.left, next("\x1b\x1b[D", &i).?);
    try std.testing.expectEqual(@as(usize, 4), i);
    i = 0;
    try std.testing.expectEqual(Key.right, next("\x1b\x1b[C", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.up, next("\x1b\x1b[A", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.down, next("\x1b\x1b[B", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.up, next("\x1b\x1bOA", &i).?);
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

test "orphan SGR needs field-zero framing before it can become a mouse" {
    var i: usize = 0;
    // A digit-led tail may begin at button, x, or y. Consume it as debris, but
    // never fabricate a click or wheel direction from guessed alignment.
    const k = next("39;33;23M", &i).?;
    try std.testing.expectEqual(Key.ignore, k);
    try std.testing.expectEqual(@as(usize, 9), i);
    i = 0;
    // `<` proves this is field zero, so all three exact fields are actionable.
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
    key.armOrphan(true);
    defer key.armOrphan(false);
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
test "kitty numeric keypad types instead of vanishing (#549)" {
    var i: usize = 0;
    try std.testing.expectEqual(Key{ .char = '0' }, next("\x1b[57399u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '7' }, next("\x1b[57406u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '9' }, next("\x1b[57408u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '.' }, next("\x1b[57409u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '/' }, next("\x1b[57410u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '*' }, next("\x1b[57411u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '-' }, next("\x1b[57412u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '+' }, next("\x1b[57413u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = '=' }, next("\x1b[57415u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = ',' }, next("\x1b[57416u", &i).?);
    // Releases stay inert, and the unbound keypad keys are still never Escape.
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57406;1:3u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57425u", &i).?); // KP_Insert
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[57427u", &i).?); // KP_Begin
    key.held = 0;
}

test "the event type is read from the modifier field, not the text field (#549)" {
    // `CSI code ; mods:event ; text:text u` — the associated-text codepoints in
    // field 3 are ':'-separated too, and scanning the whole tail found those.
    var i: usize = 0;
    try std.testing.expectEqual(Key{ .char = 'A' }, next("\x1b[97;2;65:66u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key{ .char = 'a' }, next("\x1b[97;1;97:3u", &i).?);
    // A genuine release, in field 2, is still ignored.
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[97;1:3u", &i).?);
    i = 0;
    try std.testing.expectEqual(Key.ignore, next("\x1b[1;1:3A", &i).?);
    key.held = 0;
}

test "next: embedded paste newlines are chars, not Enter (#643)" {
    key.resetInputState();
    defer key.resetInputState();
    var i: usize = 0;
    const p = "\x1b[200~a\r\nb\x1b[201~";
    try std.testing.expectEqual(Key.paste_start, next(p, &i).?);
    try std.testing.expectEqual(Key{ .char = 'a' }, next(p, &i).?);
    try std.testing.expectEqual(Key{ .char = '\n' }, next(p, &i).?);
    try std.testing.expectEqual(Key{ .char = 'b' }, next(p, &i).?);
    try std.testing.expectEqual(Key.paste_end, next(p, &i).?);
}

test "next: wrap-less multiline burst is not Enter (#643)" {
    key.resetInputState();
    defer key.resetInputState();
    var i: usize = 0;
    const p = "a\r\nb";
    try std.testing.expectEqual(Key{ .char = 'a' }, next(p, &i).?);
    try std.testing.expectEqual(Key{ .char = '\n' }, next(p, &i).?);
    try std.testing.expectEqual(Key{ .char = 'b' }, next(p, &i).?);
    i = 0;
    try std.testing.expectEqual(Key.enter, next("\r", &i).?);
}

test "#545: 10+-digit CSI params saturate instead of aborting the TUI" {
    try std.testing.expectEqual(std.math.maxInt(u32), key.leadingInt("99999999999999999999"));
    try std.testing.expectEqual(std.math.maxInt(u32), key.leadingInt("9999999999"));
    try std.testing.expectEqual(@as(u32, 4294967295), key.leadingInt("4294967295"));
    try std.testing.expectEqual(@as(u32, 200), key.leadingInt("200~tail"));
    key.resetInputState();
    defer key.resetInputState();
    const payloads = [_][]const u8{
        "\x1b[99999999999999999999;1u",
        "\x1b[9999999999;1u",
        "\x1b[<0;9999999999;5M",
        "\x1b[200~hello \x1b[99999999999999999999;1u world\x1b[201~",
    };
    for (payloads) |p| {
        var i: usize = 0;
        while (i < p.len) {
            const before = i;
            _ = next(p, &i);
            if (i <= before) break;
        }
    }
}
