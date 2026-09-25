//! #1271: over-cap output keeps its head AND its tail. Test summaries, final
//! errors and exit reasons sit at the END of a build or test run, so a cap that
//! kept only the first bytes threw away exactly the part the model needed — and
//! a subagent has no spill file to go back to.
//!
//! Split policy: the head gets a third of the budget and the tail the other two
//! thirds. The head still shows which command ran and how it started; the tail
//! is biased larger because that is where failures and summaries land.
//!
//! Shared by the capped subprocess capture (process_runner.zig, bounded by
//! `TailRing` so an overflowing child never costs more than its cap) and the
//! per-result cap (tool_spill.truncateStrField). The gap wording follows
//! handle_preview's `[... N bytes omitted ...]` excerpt marker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utf8Prefix = @import("util.zig").utf8Prefix;

pub const gap_fmt = "[... {d} bytes truncated ...]";

/// Worst case for "\n" ++ gap ++ "\n" with a 20-digit count.
pub const gap_reserve: usize = 2 + gap_fmt.len - 3 + 20;

/// Below this, a head/tail split leaves too little of either to be useful and
/// callers keep the old plain prefix.
pub const min_budget: usize = 128;

/// Bytes of a `budget` (already net of the gap) that go to the head.
pub fn headShare(budget: usize) usize {
    return budget / 3;
}

/// The last <= `max` bytes of `s`, never starting inside a UTF-8 sequence.
pub fn utf8Suffix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return dropLeadingContinuation(s[s.len - max ..]);
}

/// `t` without the (at most 3) continuation bytes a cut left at its start.
pub fn dropLeadingContinuation(t: []const u8) []const u8 {
    var out = t;
    var skips: usize = 0;
    while (skips < 3 and out.len > 0 and (out[0] & 0xC0) == 0x80) : (skips += 1) out = out[1..];
    return out;
}

/// `head ++ "\n" ++ gap ++ "\n" ++ tail`, where `dropped` is what `full`
/// loses between the two. Never longer than head + tail + gap_reserve.
pub fn join(gpa: Allocator, head: []const u8, tail: []const u8, dropped: usize) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\n" ++ gap_fmt ++ "\n{s}", .{ head, dropped, tail });
}

/// `s` cut to at most `budget` bytes, keeping head and tail around a gap
/// marker. Returns `s` itself when it already fits, and a plain UTF-8 prefix
/// when `budget` is too small for a useful split. Only the split is allocated,
/// so pass an arena (tool_spill does).
pub fn headTail(gpa: Allocator, s: []const u8, budget: usize) ![]const u8 {
    if (s.len <= budget) return s;
    if (budget < min_budget) return utf8Prefix(s, budget);
    const avail = budget - gap_reserve;
    const head = utf8Prefix(s, headShare(avail));
    const tail = utf8Suffix(s, avail - head.len);
    return join(gpa, head, tail, s.len - head.len - tail.len);
}

/// The capture's version of `join`: `head`, the gap, and what `ring` retained
/// of the `after_head` bytes that arrived once the head was full.
pub fn joinRing(gpa: Allocator, head: []const u8, ring: *const TailRing, after_head: usize) ![]u8 {
    const tmp = try gpa.alloc(u8, ring.len);
    defer gpa.free(tmp);
    const tail = dropLeadingContinuation(ring.copyTo(tmp));
    return join(gpa, head, tail, after_head - tail.len);
}

/// Fixed-size ring holding the most recent `buf.len` bytes pushed through it.
/// Memory is allocated once up front; pushing never grows it.
pub const TailRing = struct {
    buf: []u8,
    start: usize = 0,
    len: usize = 0,

    pub fn init(gpa: Allocator, size: usize) !TailRing {
        return .{ .buf = try gpa.alloc(u8, size) };
    }

    pub fn deinit(self: *TailRing, gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn push(self: *TailRing, bytes: []const u8) void {
        const n = self.buf.len;
        if (n == 0) return;
        if (bytes.len >= n) {
            @memcpy(self.buf, bytes[bytes.len - n ..]);
            self.start = 0;
            self.len = n;
            return;
        }
        const end = (self.start + self.len) % n;
        const first = @min(bytes.len, n - end);
        @memcpy(self.buf[end..][0..first], bytes[0..first]);
        @memcpy(self.buf[0 .. bytes.len - first], bytes[first..]);
        const total = self.len + bytes.len;
        if (total > n) {
            self.start = (self.start + total - n) % n;
            self.len = n;
        } else self.len = total;
    }

    /// The retained bytes in order, copied into `out` (at least `len` long).
    pub fn copyTo(self: TailRing, out: []u8) []u8 {
        const n = self.buf.len;
        const first = @min(self.len, n - self.start);
        @memcpy(out[0..first], self.buf[self.start..][0..first]);
        @memcpy(out[first..self.len], self.buf[0 .. self.len - first]);
        return out[0..self.len];
    }
};

test "#1271: headTail keeps the sentinel at the end of 3 MB and stays in budget" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, 3 * 1024 * 1024);
    defer a.free(big);
    @memset(big, 'x');
    @memcpy(big[0..5], "START");
    const sentinel = "FINAL-SENTINEL-1271";
    @memcpy(big[big.len - sentinel.len ..], sentinel);
    const got = try headTail(a, big, 4096);
    defer a.free(got);
    try std.testing.expect(got.len <= 4096);
    try std.testing.expect(std.mem.startsWith(u8, got, "START"));
    try std.testing.expect(std.mem.endsWith(u8, got, sentinel));
    try std.testing.expect(std.mem.indexOf(u8, got, "bytes truncated ...]") != null);
}

test "#1271: headTail never splits a UTF-8 sequence and small budgets keep a prefix" {
    const a = std.testing.allocator;
    const s = &@import("util.zig").repeatBytes("é", 400); // 800 bytes of 2-byte sequences
    const got = try headTail(a, s, 301);
    defer a.free(got);
    try std.testing.expect(got.len <= 301);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    try std.testing.expectEqualStrings(&@import("util.zig").repeatBytes("é", 10), try headTail(a, s, 21)); // prefix, not allocated
    try std.testing.expectEqualStrings("é", utf8Suffix("aé", 1 + 1)); // skips nothing: 'é' is 2 bytes
    try std.testing.expectEqualStrings("", utf8Suffix("é", 1)); // lone continuation byte dropped
}

test "#1271: TailRing keeps only the most recent bytes across wraps" {
    const a = std.testing.allocator;
    var ring = try TailRing.init(a, 8);
    defer ring.deinit(a);
    var out: [8]u8 = undefined;
    ring.push("abc");
    try std.testing.expectEqualStrings("abc", ring.copyTo(&out));
    ring.push("defgh");
    try std.testing.expectEqualStrings("abcdefgh", ring.copyTo(&out));
    ring.push("ijk");
    try std.testing.expectEqualStrings("defghijk", ring.copyTo(&out));
    ring.push("0123456789");
    try std.testing.expectEqualStrings("23456789", ring.copyTo(&out));
}
