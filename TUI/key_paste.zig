//! Multiline paste burst: a single tty read that carries more than one
//! prompt line. Bracketed paste already latches `in_paste`; this catches
//! the wrap-less dump (clipboard `\r\n` without `CSI 200~/201~`) so each
//! newline cannot fire Enter/send (#643).

const std = @import("std");

/// True when `bytes` is a multi-line paste, not a typed line plus Enter.
/// A lone trailing CR/LF (submit) and a double-Enter mash (force-interrupt)
/// stay false.
pub fn looksLikeBurst(bytes: []const u8) bool {
    var breaks: usize = 0;
    var text: usize = 0;
    var text_after_break = false;
    var seen_break = false;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 0x0d) {
            breaks += 1;
            seen_break = true;
            if (i + 1 < bytes.len and bytes[i + 1] == 0x0a) i += 1;
        } else if (bytes[i] == 0x0a) {
            breaks += 1;
            seen_break = true;
        } else if (bytes[i] >= 32) {
            text += 1;
            if (seen_break) text_after_break = true;
        }
    }
    return text_after_break or (breaks >= 2 and text > 0);
}

/// CR/LF inside a bracketed paste or a wrap-less burst is a literal newline,
/// never the Enter/send key. Collapses `\r\n` to one `\n`.
pub fn pasteNewline(bytes: []const u8, i: *usize, b: u8) ?u8 {
    if (b != 0x0d and b != 0x0a) return null;
    if (b == 0x0d and i.* < bytes.len and bytes[i.*] == 0x0a) i.* += 1;
    return '\n';
}

test "a typed line plus Enter is not a paste burst" {
    try std.testing.expect(!looksLikeBurst("hello\r"));
    try std.testing.expect(!looksLikeBurst("hello\n"));
    try std.testing.expect(!looksLikeBurst("hello\r\n"));
    try std.testing.expect(!looksLikeBurst("\r"));
    try std.testing.expect(!looksLikeBurst("\r\r")); // double-enter force
}

test "text after a newline is a paste burst (#643)" {
    try std.testing.expect(looksLikeBurst("line1\nline2"));
    try std.testing.expect(looksLikeBurst("line1\r\nline2\r\nline3"));
    try std.testing.expect(looksLikeBurst("line1\nline2\n"));
}

test "blank-line-only dumps are not a burst" {
    try std.testing.expect(!looksLikeBurst("\n\n"));
}
