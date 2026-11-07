//! MCP form elicitation. graff shows no forms, so a server that asks for
//! input mid-call gets a decline rather than a call that never finishes:
//! `elicitation/create` on the stdio request-scoped channel here, and the
//! modern multi round-trip form in mcp_mrtr.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");

/// Legacy `initialize` `capabilities` object. `{form:{}}` is the 2025-11-25
/// form-only shape.
pub const client_capabilities = "{\"elicitation\":{\"form\":{}},\"extensions\":{\"io.modelcontextprotocol/ui\":{\"mimeTypes\":[\"text/html;profile=mcp-app\"]}}}";

pub const initialize_params =
    "{\"protocolVersion\":\"" ++ mcp_protocol.legacy_protocol ++
    "\",\"capabilities\":" ++ client_capabilities ++
    ",\"clientInfo\":{\"name\":\"simple-harness\",\"version\":\"0.1\"}}";

fn incomingMethod(msg: Value) ?[]const u8 {
    if (msg != .object) return null;
    if (msg.object.get("result") != null or msg.object.get("error") != null) return null;
    const method = msg.object.get("method") orelse return null;
    return if (method == .string) method.string else null;
}

fn incomingId(msg: Value) ?i64 {
    if (msg != .object) return null;
    const id = msg.object.get("id") orelse return null;
    return if (id == .integer) id.integer else null;
}

/// If `line` is `elicitation/create`, write a decline and return true.
pub fn replyStdio(w: *Io.Writer, arena: Allocator, line: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return false;
    const msg = std.json.parseFromSliceLeaky(Value, arena, trimmed, .{ .allocate = .alloc_always }) catch return false;
    const method = incomingMethod(msg) orelse return false;
    const id = incomingId(msg) orelse return false;
    if (!std.mem.eql(u8, method, "elicitation/create")) return false;
    const body = try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"action":"decline"}}}}
    , .{id});
    try mcp_stdio.writeRequest(w, body);
    return true;
}

const testing = std.testing;

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "client capabilities advertise form elicitation" {
    try testing.expect(contains(client_capabilities, "\"elicitation\""));
    try testing.expect(contains(client_capabilities, "\"form\""));
    try testing.expect(contains(initialize_params, client_capabilities));
    try testing.expect(contains(initialize_params, mcp_protocol.legacy_protocol));
}

test "replyStdio declines every form, even one with defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const line =
        \\{"jsonrpc":"2.0","id":3,"method":"elicitation/create","params":{"message":"read-only inspect","requestedSchema":{"type":"object","properties":{"ok":{"type":"boolean","default":true}}}}}
    ;
    try testing.expect(try replyStdio(&w, a, line));
    try testing.expect(contains(w.buffered(), "\"id\":3"));
    try testing.expect(contains(w.buffered(), "\"action\":\"decline\""));
}

test "replyStdio ignores notifications and ordinary results" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expect(!try replyStdio(&w, a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}"));
    try testing.expect(!try replyStdio(&w, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}
