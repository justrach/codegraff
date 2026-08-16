//! OSC 52 — the clipboard channel that survives SSH.
//!
//! `pbcopy`/`xclip` write the clipboard of the machine graff RUNS on. Over SSH
//! that is the server, which nobody is looking at, so the local-tool path
//! silently copies into a void. OSC 52 asks the TERMINAL to set its own
//! clipboard instead: the escape travels back over the same connection the
//! frame does, and it lands on the laptop in front of the user.
//!
//! Wire shape: `ESC ] 5 2 ; c ; <base64> BEL`. `c` is the CLIPBOARD selection
//! (not the X primary), and BEL terminates the string — ST (`ESC \`) is equally
//! legal but BEL is what tmux, iTerm2, kitty and Ghostty all accept without a
//! passthrough wrapper.
//!
//! Two properties this module exists to hold.
//!
//!   * **Chunk safety.** Base64 is only concatenable on 3-byte input
//!     boundaries: encode 4 bytes, then the next 4, and the padding in the
//!     middle corrupts everything after it. `encode` therefore consumes the
//!     input in multiples of THREE, so an implementation that streams it (or a
//!     terminal that reads it in pieces) can never see interior padding.
//!   * **A cap.** Terminals bound the sequence they will buffer, and a
//!     multi-megabyte escape is a way to wedge one rather than to copy
//!     anything. Past `max_bytes` the emission is REFUSED — never truncated,
//!     because a clipboard that silently holds half a selection is worse than
//!     one that says it holds nothing.
//!
//! Presentation only: nothing here reaches a provider or the engine.

const std = @import("std");

pub const prefix = "\x1b]52;c;";
pub const terminator = "\x07";

/// Largest selection that gets an OSC 52 emission. 100 KB of transcript is far
/// more than a drag can plausibly want and still well inside what terminals
/// accept.
pub const max_bytes: usize = 100 * 1024;

/// Input bytes per encoding step. A multiple of 3, which is the whole point:
/// each step emits complete base64 quanta, so the pieces concatenate.
pub const chunk_bytes: usize = 3 * 1024;

/// True when `text` is small enough to send. The caller decides what to tell
/// the user about a refusal — see selection.zig's toast.
pub fn fits(text: []const u8) bool {
    return text.len > 0 and text.len <= max_bytes;
}

/// The complete escape sequence for `text`, or null when it does not fit.
/// Caller owns the result.
pub fn sequence(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (!fits(text)) return null;
    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice(prefix);
    try encode(&out, text);
    try out.appendSlice(terminator);
    return try out.toOwnedSlice();
}

/// Standard base64 with padding, appended in `chunk_bytes` steps. Only the
/// FINAL step can be short, so only the final step can emit '=' — which is
/// exactly what makes the output the same bytes a one-shot encode would give.
pub fn encode(out: *std.array_list.Managed(u8), text: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    var i: usize = 0;
    while (i < text.len) {
        const n = @min(chunk_bytes, text.len - i);
        const piece = text[i .. i + n];
        const room = enc.calcSize(piece.len);
        const at = out.items.len;
        try out.resize(at + room);
        _ = enc.encode(out.items[at..][0..room], piece);
        i += n;
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "the sequence is OSC 52, clipboard selection, BEL terminated" {
    const a = testing.allocator;
    const got = (try sequence(a, "hi")).?;
    defer a.free(got);
    try testing.expectEqualStrings("\x1b]52;c;aGk=\x07", got);
}

test "base64 matches a one-shot encode at every length around a chunk edge" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    // Lengths that straddle the chunk boundary in both directions, plus the
    // three residues mod 3 — the only places a streamed encoder can drift.
    const lens = [_]usize{
        1,               2,               3,
        4,               5,               6,
        1023,            1024,            1025,
        chunk_bytes - 2, chunk_bytes - 1, chunk_bytes,
        chunk_bytes + 1, chunk_bytes + 2, chunk_bytes * 2 + 1,
    };
    for (lens) |n| {
        const src = try ar.alloc(u8, n);
        for (src, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
        var out = std.array_list.Managed(u8).init(ar);
        try encode(&out, src);
        const enc = std.base64.standard.Encoder;
        const want = try ar.alloc(u8, enc.calcSize(n));
        _ = enc.encode(want, src);
        try testing.expectEqualStrings(want, out.items);
        // ...and it decodes back to the original bytes.
        const dec = std.base64.standard.Decoder;
        const back = try ar.alloc(u8, try dec.calcSizeForSlice(out.items));
        try dec.decode(back, out.items);
        try testing.expectEqualSlices(u8, src, back);
    }
}

test "no interior padding: '=' can only appear in the last four characters" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    // A length whose FIRST chunk is a whole number of quanta and whose tail is
    // not: a chunker that split anywhere else would pad mid-stream.
    const src = try ar.alloc(u8, chunk_bytes + 2);
    @memset(src, 'q');
    var out = std.array_list.Managed(u8).init(ar);
    try encode(&out, src);
    const first_pad = std.mem.indexOfScalar(u8, out.items, '=') orelse out.items.len;
    try testing.expect(first_pad >= out.items.len - 4);
}

test "the cap refuses rather than truncating" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const big = try ar.alloc(u8, max_bytes + 1);
    @memset(big, 'x');
    try testing.expect(!fits(big));
    try testing.expect((try sequence(ar, big)) == null);
    // Exactly at the cap still goes.
    const edge = big[0..max_bytes];
    try testing.expect(fits(edge));
    const seq = (try sequence(ar, edge)).?;
    try testing.expect(std.mem.startsWith(u8, seq, prefix));
    try testing.expect(std.mem.endsWith(u8, seq, terminator));
    // Empty is not a copy.
    try testing.expect(!fits(""));
    try testing.expect((try sequence(ar, "")) == null);
}

test "the payload is the selection verbatim, newlines and all" {
    const a = testing.allocator;
    // The text-only capture contract from #529: whatever selection.zig
    // captured is what the terminal's clipboard gets, byte for byte.
    const text = "first row\nsecond row\n\nfourth row";
    const got = (try sequence(a, text)).?;
    defer a.free(got);
    const body = got[prefix.len .. got.len - terminator.len];
    const dec = std.base64.standard.Decoder;
    const back = try a.alloc(u8, try dec.calcSizeForSlice(body));
    defer a.free(back);
    try dec.decode(back, body);
    try testing.expectEqualStrings(text, back);
}
