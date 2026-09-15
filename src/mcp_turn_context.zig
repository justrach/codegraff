//! Opaque caller-owned correlation IDs for the computer-use MCP bridge.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Snapshot = struct { session: [36]u8, turn: [36]u8 };
pub const State = struct {
    value: ?Snapshot = null,
    pub fn begin(self: *State, io: std.Io) void {
        const session = if (self.value) |v| v.session else uuid(io);
        self.value = .{ .session = session, .turn = uuid(io) };
    }
};
fn uuid(io: std.Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var result: [36]u8 = undefined;
    var offset: usize = 0;
    for (&result, 0..) |*c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) c.* = '-' else {
            c.* = hex[offset];
            offset += 1;
        }
    }
    return result;
}

/// Metadata is host-owned and scoped to the computer-use adapter, never
/// merged from model arguments or sent to unrelated MCP servers.
pub fn params(a: Allocator, server: []const u8, name: []const u8, input: std.json.Value, context: ?Snapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("arguments");
    try s.write(input);
    if (std.mem.eql(u8, server, "cua_repl") or std.mem.eql(u8, server, "node_repl")) {
        if (context) |ctx| {
            try s.objectField("_meta");
            try s.beginObject();
            try s.objectField("x-codex-turn-metadata");
            try s.write(.{ .session_id = ctx.session[0..], .turn_id = ctx.turn[0..] });
            try s.endObject();
        }
    }
    try s.endObject();
    return out.toOwnedSlice();
}

test "turn context is stable within a turn, rotates between turns and differs by caller" {
    var first: State = .{};
    var second: State = .{};
    first.begin(std.testing.io);
    const before = first.value.?;
    second.begin(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &before.session, &second.value.?.session));
    first.begin(std.testing.io);
    try std.testing.expectEqualStrings(&before.session, &first.value.?.session);
    try std.testing.expect(!std.mem.eql(u8, &before.turn, &first.value.?.turn));
    try std.testing.expectEqual(@as(u8, '4'), before.session[14]);
    try std.testing.expectEqual(@as(u8, '-'), before.turn[8]);
}

test "computer bridge metadata stays outside arguments and unrelated MCP calls" {
    const a = std.testing.allocator;
    var state: State = .{};
    state.begin(std.testing.io);
    const input = try std.json.parseFromSlice(std.json.Value, a, "{\"_meta\":{\"x-codex-turn-metadata\":\"untrusted\"}}", .{});
    defer input.deinit();
    for ([_][]const u8{ "cua_repl", "node_repl", "ordinary" }) |server| {
        const text = try params(a, server, "js", input.value, state.value);
        defer a.free(text);
        const decoded = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer decoded.deinit();
        const object = decoded.value.object;
        try std.testing.expectEqualStrings("untrusted", object.get("arguments").?.object.get("_meta").?.object.get("x-codex-turn-metadata").?.string);
        if (std.mem.eql(u8, server, "ordinary")) {
            try std.testing.expect(object.get("_meta") == null);
        } else {
            const context = object.get("_meta").?.object.get("x-codex-turn-metadata").?.object;
            try std.testing.expectEqualStrings(&state.value.?.session, context.get("session_id").?.string);
            try std.testing.expectEqualStrings(&state.value.?.turn, context.get("turn_id").?.string);
        }
    }
}
