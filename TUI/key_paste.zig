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

/// A paste larger than one tty read arrives as several reads back to back.
/// `looksLikeBurst` only ever sees one of them, so a chunk that happens to
/// end at a line boundary looks like a typed line plus Enter and submits
/// mid-paste — one pasted message became several prompts (#737, a return of
/// #643 by another route). A burst therefore latches for a short window, and
/// every read that still looks like one pushes the window out.
var burst_until_ms: u64 = 0;

/// Reads this close together are the same paste. Terminals deliver the
/// chunks with no gap; a person reaching for Enter takes far longer.
pub const burst_window_ms: u64 = 150;

pub fn armBurst(now_ms: u64) void {
    burst_until_ms = now_ms + burst_window_ms;
}

pub fn inBurst(now_ms: u64) bool {
    return now_ms < burst_until_ms;
}

pub fn resetBurst() void {
    burst_until_ms = 0;
    active = false;
    split_cr = false;
}

/// Whether the read the parser is walking belongs to a paste. The read loop
/// decides (it holds the clock); the parser only asks.
var active: bool = false;

pub fn setBurstRead(on: bool) void {
    active = on;
}

pub fn burstActive() bool {
    return active;
}

/// True when this read is part of a paste: it looks like one on its own, or
/// it arrived inside the window opened by the read before it. Arms the
/// window either way so the next chunk is covered too.
pub fn burstRead(bytes: []const u8, now_ms: u64) bool {
    const carried = inBurst(now_ms);
    if (!looksLikeBurst(bytes) and !carried) return false;
    armBurst(now_ms);
    return true;
}

var split_cr = false;

/// Consume only the immediately following LF, including across tty reads.
/// Any other byte (notably a paste terminator) clears this one-byte carry.
pub fn takeSplitLf(b: u8) bool {
    const skip = split_cr and b == '\n';
    split_cr = false;
    return skip;
}

/// CR/LF inside a bracketed paste or a wrap-less burst is a literal newline,
/// never the Enter/send key. Collapses `\r\n` to one `\n`.
pub fn pasteNewline(bytes: []const u8, i: *usize, b: u8) ?u8 {
    if (b != 0x0d and b != 0x0a) return null;
    if (b == 0x0d) {
        split_cr = i.* == bytes.len;
        if (i.* < bytes.len and bytes[i.*] == 0x0a) i.* += 1;
    }
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

test "a paste split across reads stays one prompt (#737)" {
    resetBurst();
    // The terminal hands over a long paste in chunks. The first is plainly a
    // burst; the second ends at a line boundary and, judged alone, reads as a
    // typed line plus Enter — which is what submitted mid-paste.
    try std.testing.expect(!looksLikeBurst("tail of the paragraph\n"));
    try std.testing.expect(burstRead("first paragraph\nsecond paragraph\n", 1_000));
    try std.testing.expect(burstRead("tail of the paragraph\n", 1_010));
    try std.testing.expect(burstRead("and the last line\n", 1_100));
}

test "a typed Enter after the paste settles still sends" {
    resetBurst();
    try std.testing.expect(burstRead("pasted line one\npasted line two\n", 1_000));
    // Long enough after the last chunk to be a person, not the terminal.
    try std.testing.expect(!burstRead("now my own line\n", 1_000 + burst_window_ms + 1));
}

test "an ordinary typed line never opens the window" {
    resetBurst();
    try std.testing.expect(!burstRead("hello\r", 5_000));
    try std.testing.expect(!inBurst(5_000));
    try std.testing.expect(!burstRead("\r", 5_010));
}
