//! Small pure helpers shared across modules — currently the two JSON
//! ObjectMap getters used by the gateway/cube CLI, the OAuth flows, and the
//! trajectory renderer, plus utf8Prefix (UTF-8-safe truncation, used nearly
//! everywhere for capping strings before they hit JSON/telemetry) and
//! unixMs (wall-clock milliseconds). Leaf module: std only. Split out of
//! main.zig (#123).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

/// Read a string field from a JSON object, or null if absent/non-string.
pub fn strFieldObj(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// Read an integer field from a JSON object, or `default` if absent/non-integer.
pub fn intFieldObj(obj: std.json.ObjectMap, name: []const u8, default: i64) i64 {
    const v = obj.get(name) orelse return default;
    return if (v == .integer) v.integer else default;
}

test "strFieldObj/intFieldObj: object-map variants with defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = std.json.parseFromSliceLeaky(Value, a, "{\"s\":\"hi\",\"n\":42}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("hi", strFieldObj(v.object, "s").?);
    try std.testing.expect(strFieldObj(v.object, "n") == null);
    try std.testing.expectEqual(@as(i64, 42), intFieldObj(v.object, "n", -1));
    try std.testing.expectEqual(@as(i64, -1), intFieldObj(v.object, "s", -1)); // wrong type -> default
    try std.testing.expectEqual(@as(i64, -1), intFieldObj(v.object, "missing", -1));
}

/// Largest prefix of `s` up to `max` bytes that doesn't split a UTF-8
/// codepoint (std.json would otherwise serialize the slice as an int array).
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var p = s[0..max];
    var strips: usize = 0;
    while (strips < 3 and p.len > 0 and !std.unicode.utf8ValidateSlice(p)) : (strips += 1)
        p = p[0 .. p.len - 1];
    return p;
}

/// Wall-clock unix milliseconds (OTLP timestamps need real time; the
/// harness otherwise only uses the monotonic Io clock).
pub fn unixMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
}

test "utf8Prefix truncates without splitting codepoints" {
    try std.testing.expectEqualStrings("abc", utf8Prefix("abc", 10));
    const s = [_]u8{ 'a', 'b', 0xC3, 0xA9, 'c' }; // "abéc"
    try std.testing.expectEqualStrings("ab", utf8Prefix(&s, 3)); // é would split
    try std.testing.expectEqualStrings("ab\xC3\xA9", utf8Prefix(&s, 4));
}
