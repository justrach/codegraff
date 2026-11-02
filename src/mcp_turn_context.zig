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

var fallback: State = .{};

/// cua_repl / node_repl require host metadata. If a caller forgot to pass
/// turn context, mint a process-local pair rather than sending a request
/// the adapter will reject.
pub fn effective(context: ?Snapshot, io: std.Io, server: []const u8) ?Snapshot {
    if (context) |ctx| return ctx;
    if (!(std.mem.eql(u8, server, "cua_repl") or std.mem.eql(u8, server, "node_repl"))) return null;
    fallback.begin(io);
    return fallback.value;
}
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
    // #1511: `_meta` leads, so the protocol envelope and the progress token
    // merge into this one object (mcp_protocol.buildRequest,
    // mcp_notify.withProgressToken) instead of adding a second `_meta` key.
    if (std.mem.eql(u8, server, "cua_repl") or std.mem.eql(u8, server, "node_repl")) {
        if (context) |ctx| {
            try s.objectField("_meta");
            try s.beginObject();
            try s.objectField("x-codex-turn-metadata");
            try s.write(.{ .session_id = ctx.session[0..], .turn_id = ctx.turn[0..] });
            try s.endObject();
        }
    }
    try s.objectField("name");
    try s.write(name);
    try s.objectField("arguments");
    try s.write(input);
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

test "computer adapters still get turn metadata when the caller omitted it" {
    const a = std.testing.allocator;
    const input = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer input.deinit();
    const ctx = effective(null, std.testing.io, "cua_repl");
    try std.testing.expect(ctx != null);
    const text = try params(a, "cua_repl", "js", input.value, ctx);
    defer a.free(text);
    const decoded = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer decoded.deinit();
    const meta = decoded.value.object.get("_meta").?.object.get("x-codex-turn-metadata").?.object;
    try std.testing.expect(meta.get("session_id").?.string.len == 36);
    try std.testing.expect(meta.get("turn_id").?.string.len == 36);
    try std.testing.expect(effective(null, std.testing.io, "ordinary") == null);
}

test "#1511: a computer-use tools/call carries one _meta with the turn context and progress token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    state.begin(std.testing.io);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"code\":\"await createBrowserTab()\"}", .{});
    const p = try params(a, "cua_repl", "js", input, state.value);
    for ([_]bool{ false, true }) |modern| {
        // The same steps as mcp_rpc.request for a tools/call.
        const built = try @import("mcp_protocol.zig").buildRequest(a, 9, "tools/call", p, modern);
        const line = try @import("mcp_notify.zig").withProgressToken(a, built, 9);
        // A duplicate key is a parse error here, as it is for a strict server.
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .duplicate_field_behavior = .@"error" });
        const params_obj = v.object.get("params").?.object;
        try std.testing.expectEqualStrings("js", params_obj.get("name").?.string);
        const meta = params_obj.get("_meta").?.object;
        try std.testing.expectEqual(@as(i64, 9), meta.get("progressToken").?.integer);
        try std.testing.expectEqualStrings(&state.value.?.turn, meta.get("x-codex-turn-metadata").?.object.get("turn_id").?.string);
        try std.testing.expectEqual(modern, meta.get("io.modelcontextprotocol/protocolVersion") != null);
    }
}

test "#1580: the first computer-use call reaches a server that exits on a duplicate key" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Registry = @import("mcp.zig").Registry;
    var reg = Registry.empty(gpa, io);
    defer reg.deinit();
    reg.stdio_probe = false;
    reg.lazy_stdio = false;
    // Like the real adapter's JSON-RPC reader: a request line with a
    // duplicate `_meta` does not parse, and the server stops reading and
    // exits. graff saw that as McpClosed on the first call (#1580).
    const script =
        \\while read -r l; do
        \\  case "$l" in *'"_meta":'*'"_meta":'*) exit 0 ;; esac
        \\  id=$(printf '%s' "$l" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
        \\  [ -z "$id" ] && continue
        \\  case "$l" in
        \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"f","version":"1"}}}\n' "$id" ;;
        \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"js","description":"d","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
        \\    *'"method":"tools/call"'*'"x-codex-turn-metadata"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"state"}]}}\n' "$id" ;;
        \\    *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"missing turn metadata"}}\n' "$id" ;;
        \\  esac
        \\done
    ;
    try std.testing.expectEqual(@as(usize, 1), try reg.addServer("cua_repl", "/bin/sh", &.{ "-c", script }));
    var state: State = .{};
    state.begin(io);
    const input = try std.json.parseFromSlice(std.json.Value, gpa, "{\"code\":\"await cua.getState();\"}", .{});
    defer input.deinit();
    const first = try reg.callWithContext(gpa, "mcp__cua_repl__js", input.value, state.value);
    defer gpa.free(first.text);
    try std.testing.expectEqualStrings("state", first.text);
    try std.testing.expect(!first.is_error);
    // The process that answered is the one that started: no close, no restart.
    try std.testing.expect(reg.servers[0].transport == .stdio);
    try std.testing.expectEqual(@as(u8, 0), reg.servers[0].transport.stdio.relaunch.?.restarts);
}
