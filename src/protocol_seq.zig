//! Monotonic sequence ids for the `--json` / `graff serve` protocol (#330).
//!
//! Every structured event a `graff --json` process emits carries a `seq`: a
//! per-session counter that starts at 1 and is stamped as the FIRST field of
//! the event object, so a bridge can read it off a short prefix even when the
//! rest of the line is a multi-MiB tool_result. Gaps are impossible in normal
//! operation — the counter is bumped exactly once per emitted line, inside the
//! same lock that already serializes the shared `--json` stdout.
//!
//! The counter outlives the process: session.zig persists `event_seq` next to
//! the conversation and loadSession restores it, so a REPLACEMENT graff picking
//! a run up on a fresh host continues the numbering instead of reissuing ids a
//! supervisor has already seen.

const std = @import("std");
const Io = std.Io;

var g_seq: std.atomic.Value(u64) = .init(0);

/// Reserve the next id. Monotonic and gap-free within a process.
pub fn next() u64 {
    return g_seq.fetchAdd(1, .monotonic) + 1;
}

/// Highest id handed out so far; 0 before the first event.
pub fn current() u64 {
    return g_seq.load(.monotonic);
}

/// Continue a restored session's numbering. Only ever RAISES the counter: a
/// stale or rolled-back session file must never make this process reissue ids
/// that are already on the wire.
pub fn restore(n: u64) void {
    var seen = g_seq.load(.monotonic);
    while (n > seen) {
        seen = g_seq.cmpxchgWeak(seen, n, .monotonic, .monotonic) orelse return;
    }
}

/// Tests only: back to a fresh session.
pub fn resetForTest() void {
    g_seq.store(0, .monotonic);
}

/// Serialize one protocol event as a single JSON object with `seq` first.
/// `ev` must be a struct; its own fields follow in declaration order, so the
/// `"type":"…"` prefix scans elsewhere still hit inside their window.
/// Does NOT write the trailing newline — the caller owns line framing (and,
/// for stdout, the lock that keeps two writers from interleaving).
pub fn writeEvent(w: *Io.Writer, ev: anytype) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("seq");
    try s.write(next());
    inline for (comptime std.meta.fieldNames(@TypeOf(ev))) |name| {
        comptime {
            if (std.mem.eql(u8, name, "seq"))
                @compileError("protocol event field collides with the envelope: seq");
        }
        try s.objectField(name);
        try s.write(@field(ev, name));
    }
    try s.endObject();
}

/// The envelope prefix every stamped line opens with. Matching the POSITION,
/// not merely the field name, is what makes this both O(1) on a megabyte-long
/// tool_result and impossible to fool with a payload field that happens to be
/// called "seq".
const envelope_prefix = "{\"seq\":";

/// Read the `seq` a producer stamped on an event line, or null when the line
/// carries none (an older child, or an unstamped bridge line).
pub fn seqOf(line: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, envelope_prefix)) return null;
    var i = envelope_prefix.len;
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, line[start..i], 10) catch null;
}

test "seq counter is monotonic and gap-free" {
    resetForTest();
    defer resetForTest();
    try std.testing.expectEqual(@as(u64, 0), current());
    var prev: u64 = 0;
    for (0..64) |_| {
        const n = next();
        try std.testing.expectEqual(prev + 1, n); // no gaps, ever
        prev = n;
    }
    try std.testing.expectEqual(prev, current());
}

test "restore only raises the counter, so a stale session cannot reissue ids" {
    resetForTest();
    defer resetForTest();
    restore(100);
    try std.testing.expectEqual(@as(u64, 100), current());
    try std.testing.expectEqual(@as(u64, 101), next());
    restore(7); // a stale/rolled-back session file
    try std.testing.expectEqual(@as(u64, 101), current());
    try std.testing.expectEqual(@as(u64, 102), next());
    restore(0);
    try std.testing.expectEqual(@as(u64, 102), current());
}

test "writeEvent stamps seq first and keeps every field of the event" {
    resetForTest();
    defer resetForTest();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeEvent(&w, .{ .type = "turn", .text = "hi", .context_tokens = @as(u64, 42) });
    const line = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, line, "{\"seq\":1,\"type\":\"turn\""));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"text\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"context_tokens\":42") != null);
    try std.testing.expectEqual(@as(u64, 1), seqOf(line).?);

    // The next event takes the next id; the counter is shared, not per-writer.
    var buf2: [256]u8 = undefined;
    var w2: Io.Writer = .fixed(&buf2);
    try writeEvent(&w2, .{ .type = "finalizing" });
    try std.testing.expectEqual(@as(u64, 2), seqOf(w2.buffered()).?);
}

test "seqOf reads the envelope off a prefix and refuses to guess" {
    try std.testing.expectEqual(@as(u64, 9), seqOf("{\"seq\":9,\"type\":\"text\"}").?);
    try std.testing.expectEqual(@as(u64, 1234567), seqOf("{\"seq\":1234567,\"type\":\"text\",\"text\":\"x\"}").?);
    // Unstamped lines (an older child, a bridge-generated error) report null
    // rather than a fabricated position.
    try std.testing.expect(seqOf("{\"type\":\"error\",\"message\":\"gone\"}") == null);
    try std.testing.expect(seqOf("") == null);
    try std.testing.expect(seqOf("{\"seq\":}") == null);
    // A payload field named "seq" is NOT the envelope, however close it sits.
    try std.testing.expect(seqOf("{\"type\":\"tool_result\",\"seq\":5}") == null);
    try std.testing.expect(seqOf(" {\"seq\":5}") == null); // callers trim first
}
