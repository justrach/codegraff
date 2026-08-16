//! Escape-sequence debris recovery, parked out of key.zig under the 600-line
//! ceiling.
//!
//! Two halves of one problem: the read loop gives up on a truncated escape
//! head once the terminal goes quiet (an ssh/tmux hiccup mid-sequence), and
//! that sequence's tail can still land on a LATER read with its introducer
//! gone.
//!
//!   * `stashHead`/`joinHead` keep the abandoned head for exactly one more
//!     read and re-attach it when the new bytes really do complete it. The
//!     tail then parses as the thing it always was — mouse report, arrow,
//!     OSC-11 reply — with no shape guessing at all (#530/#531).
//!   * `take` is the fallback sweeper for tails whose head is gone for good,
//!     so `;24M` is eaten instead of typed into the composer (#546).

const std = @import("std");
const key = @import("key.zig");
const Key = key.Key;

/// Set by the read loop when it abandons a truncated escape head: the NEXT
/// read may legitimately open with that sequence's orphaned tail.
pub var armed: bool = false;

/// End offset of the last fragment consumed from the buffer currently being
/// parsed, so back-to-back debris keeps being eaten while a digit run that
/// follows real input never is. `maxInt` = no run in progress.
pub var end: usize = std.math.maxInt(usize);

/// Longest head worth carrying. Real CSI/OSC heads are far shorter; anything
/// bigger is a parser wedge, not a sequence.
const max_head = 64;
var head: [max_head]u8 = undefined;
var head_len: usize = 0;

pub fn reset() void {
    armed = false;
    end = std.math.maxInt(usize);
    head_len = 0;
}

/// Keep the head the loop just gave up on. One shot: `joinHead` spends it on
/// the very next read whether or not it is used.
pub fn stashHead(bytes: []const u8) void {
    head_len = 0;
    if (bytes.len == 0 or bytes.len > max_head) return;
    @memcpy(head[0..bytes.len], bytes);
    head_len = bytes.len;
}

/// Re-attach a stashed head to the front of `buf[0..n]` when the new bytes
/// complete it, returning the new length. Spending the head unconditionally is
/// the point: a head whose tail never came can never glue itself onto a later
/// keystroke.
pub fn joinHead(buf: []u8, n: usize) usize {
    const h = head_len;
    head_len = 0;
    if (h == 0 or n == 0 or h + n > buf.len) return n;
    if (!completes(head[0..h], buf[0..n])) return n;
    std.mem.copyBackwards(u8, buf[h .. h + n], buf[0..n]);
    @memcpy(buf[0..h], head[0..h]);
    return n + h;
}

fn at(h: []const u8, t: []const u8, k: usize) u8 {
    return if (k < h.len) h[k] else t[k - h.len];
}

/// Does `t` finish the truncated escape `h`? Only a join that yields a
/// COMPLETE sequence is worth making: after a give-up stall the next bytes are
/// just as likely to be a human resuming typing, and gluing a stale head onto
/// those would eat a keystroke.
pub fn completes(h: []const u8, t: []const u8) bool {
    const n = h.len + t.len;
    if (h.len == 0 or t.len == 0 or h[0] != 0x1b or n < 2) return false;
    switch (at(h, t, 1)) {
        0x1b => return true, // ESC ESC — a real Escape either way
        'O' => return n >= 3, // SS3 is exactly one more byte
        '[' => {
            var k: usize = 2;
            while (k < n) : (k += 1) {
                const c = at(h, t, k);
                if (c >= 0x20 and c <= 0x3f) continue; // params + intermediates
                return isInputFinal(c);
            }
            return false;
        },
        ']', 'P', '_', '^', 'X' => {
            var k: usize = 2;
            while (k < n) : (k += 1) {
                const c = at(h, t, k);
                if (c == 0x07) return true; // BEL
                if (c == 0x1b) return k + 1 < n and at(h, t, k + 1) == '\\'; // ST
                if (c == 0x0d or c == 0x0a) return false; // typed text, not a reply
            }
            return false;
        },
        // A lone ESC in front of ordinary text is an Alt chord, and joining it
        // would SWALLOW that character. Typing it is the lesser harm.
        else => return false,
    }
}

/// CSI finals a terminal actually sends on stdin. Deliberately narrow: the
/// whole 0x40..0x7e range would let a stale head glue itself onto the first
/// letter a human types after the stall.
fn isInputFinal(c: u8) bool {
    return switch (c) {
        'A'...'F', 'H', 'M', 'P'...'S', 'Z', 'm', 'u', '~' => true,
        else => false,
    };
}

pub const Orphan = union(enum) {
    /// Not debris — hand the bytes to the normal parser (typed text).
    none,
    /// Debris shape, cut short by the read boundary: hold, do not type it.
    partial,
    took: Key,
};

/// CSI debris after a lost ESC (`7444;9u`, `39;33;23M`, `<35;80;24M`). Never a
/// letter and never Escape/Ctrl-C — those cancel or kill the turn.
///
/// Strictly shaped, because this runs against text a human may have typed: an
/// optional `<`, then digits with `;`/`:` separators, then a MOUSE or CSI-u
/// final (`M`/`m`/`u`/`~`). Any other terminator is text — accepting the whole
/// 0x40..0x7e range ate `0x1f` (final `x`), `[12]` (final `]`) and `1e5`
/// (final `e`). A run with neither `<` nor a separator (`3u`) is debris only
/// while `armed` says the loop really did drop a truncated sequence.
pub fn take(bytes: []const u8, i: *usize) Orphan {
    const start = i.*;
    if (start >= bytes.len) return .none;
    var j = start;
    const lt = bytes[j] == '<';
    if (lt) j += 1;
    var sep = false;
    // A dropped head can split ON a separator (`\x1b[<35;80` + `;24M`), so the
    // tail opens with `;`/`:`. That is never typed text at the head of a read,
    // but it is only debris once the loop has told us a head was lost (#546).
    var headless = false;
    if (j < bytes.len and (bytes[j] == ';' or bytes[j] == ':') and armed) {
        sep = true;
        headless = true;
        j += 1;
    }
    if (j >= bytes.len) return if (headless) .partial else .none;
    if (bytes[j] < '0' or bytes[j] > '9') return .none;
    var k = j;
    while (k < bytes.len) : (k += 1) {
        const c = bytes[k];
        if (c >= '0' and c <= '9') continue;
        if (c == ';' or c == ':') {
            sep = true;
            continue;
        }
        if (c == 'M' or c == 'm' or c == 'u' or c == '~') {
            if (!lt and !sep and !armed) return .none;
            i.* = k + 1;
            // A fragment that opened on a separator lost its leading fields:
            // the coordinates cannot be reconstructed, and inventing a click
            // at (1,1) is worse than dropping the report.
            if (!headless and (c == 'M' or c == 'm')) {
                const body = bytes[j..k];
                var it = std.mem.splitScalar(u8, body, ';');
                const btn = key.leadingInt(it.next() orelse "0");
                const x = key.leadingInt(it.next() orelse "1");
                const y = key.leadingInt(it.next() orelse "1");
                return .{ .took = .{ .mouse = .{
                    .btn = @intCast(@min(btn, 255)),
                    .x = @intCast(@min(x, 999)),
                    .y = @intCast(@min(y, 999)),
                    .down = c == 'M',
                } } };
            }
            return .{ .took = .ignore };
        }
        return .none;
    }
    // Ran off the end mid-fragment. Hold it when it already reads as a CSI
    // parameter list, or when the loop armed us; a bare unarmed digit run is
    // somebody typing, and holding it would strand the keystrokes.
    return if (lt or sep or armed) .partial else .none;
}

test "a join only happens when the tail really completes the head" {
    // The shapes run.zig drops mid-flight, rejoined.
    try std.testing.expect(completes("\x1b", "[<35;80;24M"));
    try std.testing.expect(completes("\x1b", "[A"));
    try std.testing.expect(completes("\x1b", "[3~"));
    try std.testing.expect(completes("\x1b", "OA"));
    try std.testing.expect(completes("\x1b", "]11;rgb:14/14/14\x07"));
    try std.testing.expect(completes("\x1b[<35;80", ";24M"));
    try std.testing.expect(completes("\x1b[201", "~"));
    try std.testing.expect(completes("\x1b]11;rgb:1c", "1c/1c1c/1c1c\x07"));
    // ...and never onto a human who simply resumed typing.
    try std.testing.expect(!completes("\x1b", "hello"));
    try std.testing.expect(!completes("\x1b", ""));
    try std.testing.expect(!completes("\x1b[<35;80", "hello"));
    try std.testing.expect(!completes("\x1b[", "3")); // still incomplete
    try std.testing.expect(!completes("\x1b]11;rgb:1c", "fix it\r"));
    try std.testing.expect(!completes("", "[A"));
    try std.testing.expect(!completes("39;7", ";32M")); // headless debris is take()'s job
}

test "joinHead spends the head on the next read either way" {
    reset();
    var buf: [32]u8 = undefined;
    stashHead("\x1b[<35;80");
    @memcpy(buf[0..4], ";24M");
    try std.testing.expectEqual(@as(usize, 12), joinHead(&buf, 4));
    try std.testing.expectEqualStrings("\x1b[<35;80;24M", buf[0..12]);
    // Second read: the head is spent, nothing is glued on.
    @memcpy(buf[0..4], ";24M");
    try std.testing.expectEqual(@as(usize, 4), joinHead(&buf, 4));
    // A head whose tail never came never corrupts the keystroke that follows.
    stashHead("\x1b[<35;80");
    @memcpy(buf[0..5], "hello");
    try std.testing.expectEqual(@as(usize, 5), joinHead(&buf, 5));
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    reset();
}
