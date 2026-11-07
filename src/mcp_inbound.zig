//! Request-scoped server-to-client MCP ping replies over stdio.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp_stdio = @import("mcp_stdio.zig");

/// Answer only valid JSON-RPC ping requests; leave all other messages alone.
pub fn replyStdio(writer: *Io.Writer, allocator: Allocator, line: []const u8) !bool {
    const parsed = std.json.parseFromSlice(Value, allocator, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    const msg = parsed.value;
    if (msg != .object) return false;
    const version = msg.object.get("jsonrpc") orelse return false;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return false;
    const method = msg.object.get("method") orelse return false;
    if (method != .string or !std.mem.eql(u8, method.string, "ping")) return false;
    if (msg.object.contains("result") or msg.object.contains("error")) return false;
    const id = msg.object.get("id") orelse return false;
    if (id != .integer and id != .string) return false;
    if (msg.object.get("params")) |params| {
        if (params != .object and params != .array) return false;
    }

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.write(id);
    try out.writer.writeAll(",\"result\":{}}");
    try mcp_stdio.writeRequest(writer, out.writer.buffered());
    return true;
}

const testing = std.testing;

test "MCP inbound ping: numeric ids receive an empty result" {
    const cases = [_]struct { request: []const u8, response: []const u8 }{
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"ping\"}", .response = "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}\n" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":-17,\"method\":\"ping\",\"params\":{}}", .response = "{\"jsonrpc\":\"2.0\",\"id\":-17,\"result\":{}}\n" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":9223372036854775807,\"method\":\"ping\"}", .response = "{\"jsonrpc\":\"2.0\",\"id\":9223372036854775807,\"result\":{}}\n" },
    };
    for (cases) |case| {
        var buf: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&buf);
        try testing.expect(try replyStdio(&writer, testing.allocator, case.request));
        try testing.expectEqualStrings(case.response, writer.buffered());
    }
}

test "MCP inbound ping: string ids are JSON escaped and preserved" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try testing.expect(try replyStdio(&writer, testing.allocator,
        \\{"jsonrpc":"2.0","id":"ping\"\\\n\t雪","method":"ping"}
    ));
    const response = try std.json.parseFromSlice(Value, testing.allocator, writer.buffered(), .{});
    defer response.deinit();
    try testing.expectEqualStrings("ping\"\\\n\t雪", response.value.object.get("id").?.string);
    try testing.expectEqualStrings("2.0", response.value.object.get("jsonrpc").?.string);
    try testing.expectEqual(@as(usize, 0), response.value.object.get("result").?.object.count());
    try testing.expectEqual(@as(usize, 3), response.value.object.count());
    try testing.expectEqual(@as(u8, '\n'), writer.buffered()[writer.buffered().len - 1]);
}

test "MCP inbound ping: notifications and unrelated messages receive no reply" {
    const lines = [_][]const u8{
        \\{"jsonrpc":"2.0","method":"ping"}
        ,
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"roots/list"}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        ,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"unknown"}}
        ,
    };
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    for (lines) |line| try testing.expect(!try replyStdio(&writer, testing.allocator, line));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "MCP inbound ping: malformed requests receive no reply" {
    const lines = [_][]const u8{
        "", "not json", "{", "[]", "null",
        \\{"id":1,"method":"ping"}
        ,
        \\{"jsonrpc":"1.0","id":1,"method":"ping"}
        ,
        \\{"jsonrpc":2,"id":1,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":null,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":true,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":1.5,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":{},"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":7}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"ping","params":null}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"ping","params":3}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"ping","result":{}}
        ,
        \\{"jsonrpc":"2.0","id":1,"method":"ping","error":null}
        ,
    };
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    for (lines) |line| try testing.expect(!try replyStdio(&writer, testing.allocator, line));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
