//! Small pure helpers shared across modules — currently the two JSON
//! ObjectMap getters used by the gateway/cube CLI, the OAuth flows, and the
//! trajectory renderer, plus utf8Prefix (UTF-8-safe truncation, used nearly
//! everywhere for capping strings before they hit JSON/telemetry) and
//! unixMs (wall-clock milliseconds). Leaf module: std only. Split out of
//! main.zig (#123).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

/// Case-insensitive ASCII substring search. Zig 0.17 removed
/// std.ascii.indexOfIgnoreCase, so keep the small operation local.
pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Comptime byte-string repetition replacing Zig's removed `**` operator.
pub fn repeatBytes(comptime bytes: []const u8, comptime count: usize) [bytes.len * count]u8 {
    var out: [bytes.len * count]u8 = undefined;
    for (0..count) |i| @memcpy(out[i * bytes.len ..][0..bytes.len], bytes);
    return out;
}

test "Zig 0.17 compatibility helpers" {
    try std.testing.expectEqual(@as(?usize, 2), indexOfIgnoreCase("aBcDe", "CD"));
    try std.testing.expect(indexOfIgnoreCase("abc", "z") == null);
    try std.testing.expectEqualStrings("xyxyxy", &repeatBytes("xy", 3));
}

/// Byte offset where a secret begins in an interactive command, or null when
/// the line is safe to render/store verbatim. `/key` with no value remains a
/// useful history entry; `/key <provider> <secret>` is masked and forgotten.
pub fn sensitiveInputStart(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (!std.mem.startsWith(u8, line[i..], "/key")) return null;
    i += "/key".len;
    if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return if (i < line.len) i else null;
}

pub fn rememberInput(line: []const u8) bool {
    return sensitiveInputStart(line) == null;
}

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

test "sensitiveInputStart: masks key values but keeps status/partial commands" {
    try std.testing.expect(sensitiveInputStart("/key") == null);
    try std.testing.expect(sensitiveInputStart("/key openai") == null);
    try std.testing.expectEqual(@as(usize, 12), sensitiveInputStart("/key openai sk-secret").?);
    try std.testing.expectEqual(@as(usize, 15), sensitiveInputStart("  /key codex   token").?);
    try std.testing.expect(!rememberInput("/key openai sk-secret"));
    try std.testing.expect(rememberInput("/key"));
    try std.testing.expect(rememberInput("explain /key openai sk-secret"));
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

/// Preferred split offset for an over-wide atom (a table cell token that
/// cannot fit its column whole): the LAST identifier/path punctuation
/// (`/ _ - . : = > ) ]`) at or before `hi`, so `foo/bar__baz` breaks after
/// a punctuation run instead of mid-word. Keeps at least the first third
/// of the budget on the line; returns `hi` when no such break exists.
pub fn softCut(s: []const u8, lo: usize, hi: usize) usize {
    if (hi <= lo or hi > s.len) return hi;
    const min_keep = lo + (hi - lo) / 3;
    var i: usize = hi;
    while (i > min_keep) {
        i -= 1;
        const brk = switch (s[i]) {
            '/', '_', '-', '.', ':', '=', '>', ')', ']' => true,
            else => false,
        };
        if (brk) return i + 1;
    }
    return hi;
}

test "softCut: break after punctuation, keep the floor, else hard-split" {
    // "mcp__codedbpro" in a 12-col cell: the '_' run at index 4 is inside
    // the keep-floor's reach from the right, and the cut lands after it.
    try std.testing.expectEqual(@as(usize, 5), softCut("mcp__codedbpro", 0, 12));
    // A later '/' wins over an earlier '_'.
    try std.testing.expectEqual(@as(usize, 15), softCut("aa/bb/cc/dd/ee/ff", 0, 15));
    // No punctuation in reach: hard-split unchanged.
    try std.testing.expectEqual(@as(usize, 8), softCut("abcdefghij", 0, 8));
}

const json_bytes_max_depth = 32;

/// Serialized byte count of a JSON value, near enough for a budget decision
/// (escapes and float formatting are approximated). Depth-capped: values may
/// come from an MCP server, so they are untrusted input. Lives here (not
/// mcp_schema_gate.zig, at the 600-line cap); that module re-exports it.
pub fn jsonBytes(v: Value, depth: u8) usize {
    if (depth >= json_bytes_max_depth) return 0;
    return switch (v) {
        .null => 4,
        .bool => |b| if (b) @as(usize, 4) else 5,
        .integer => |i| blk: {
            var buf: [24]u8 = undefined;
            const printed = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk 1;
            break :blk printed.len;
        },
        .float => 8,
        .number_string => |s| s.len,
        .string => |s| s.len + 2,
        .array => |a| blk: {
            var n: usize = 2;
            for (a.items, 0..) |item, i| n += jsonBytes(item, depth + 1) + @intFromBool(i > 0);
            break :blk n;
        },
        .object => |o| blk: {
            var n: usize = 2;
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                n += e.key_ptr.len + 3 + jsonBytes(e.value_ptr.*, depth + 1);
                if (!first) n += 1;
                first = false;
            }
            break :blk n;
        },
    };
}

test "utf8Prefix truncates without splitting codepoints" {
    try std.testing.expectEqualStrings("abc", utf8Prefix("abc", 10));
    const s = [_]u8{ 'a', 'b', 0xC3, 0xA9, 'c' }; // "abéc"
    try std.testing.expectEqualStrings("ab", utf8Prefix(&s, 3)); // é would split
    try std.testing.expectEqualStrings("ab\xC3\xA9", utf8Prefix(&s, 4));
}

/// Deep-copy a std.json.Value (keys and strings included) onto `arena` (#124).
/// Detaches a subtree that must outlive a per-request scratch parse — e.g. a
/// Responses output item or an assembled Anthropic message that gets appended
/// to history — from the parse tree it aliases, so the scratch arena can be
/// reset at the next request() without a use-after-free.
pub fn dupeJsonValue(arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error!Value {
    switch (v) {
        .null, .bool, .integer, .float => return v,
        .number_string => |s| return .{ .number_string = try arena.dupe(u8, s) },
        .string => |s| return .{ .string = try arena.dupe(u8, s) },
        .array => |arr| {
            var out = std.json.Array.init(arena);
            try out.ensureTotalCapacityPrecise(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try dupeJsonValue(arena, item));
            return .{ .array = out };
        },
        .object => |obj| {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(arena, obj.count());
            var it = obj.iterator();
            while (it.next()) |e|
                out.putAssumeCapacity(try arena.dupe(u8, e.key_ptr.*), try dupeJsonValue(arena, e.value_ptr.*));
            return .{ .object = out };
        },
    }
}

test "dupeJsonValue: copy survives the source arena being reset and clobbered" {
    var src_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer src_state.deinit();
    var dst_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer dst_state.deinit();
    const src = std.json.parseFromSliceLeaky(Value, src_state.allocator(),
        \\{"type":"message","content":[{"type":"output_text","text":"hello"}],"n":42,"big":123456789012345678901234567890}
    , .{ .allocate = .alloc_always }) catch unreachable;
    const copy = try dupeJsonValue(dst_state.allocator(), src);
    // Simulate the per-request scratch reset + the next request overwriting it.
    _ = src_state.reset(.retain_capacity);
    const junk = try src_state.allocator().alloc(u8, 64 * 1024);
    @memset(junk, 0xAA);
    try std.testing.expectEqualStrings("message", copy.object.get("type").?.string);
    const blocks = copy.object.get("content").?.array;
    try std.testing.expectEqualStrings("hello", blocks.items[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 42), copy.object.get("n").?.integer);
    try std.testing.expectEqualStrings("123456789012345678901234567890", copy.object.get("big").?.number_string);
}
