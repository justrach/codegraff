//! MCP protocol negotiation and tool JSON Schema normalization.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// Recursively rewrite the JSON Schema keyword `oneOf` to `anyOf` (graff's
/// rewrite_one_of_to_any_of). OpenAI's tool-schema validator — including the
/// chatgpt.com /codex/responses endpoint — rejects `oneOf` outright with
/// "'oneOf' is not permitted"; `anyOf` is accepted by both OpenAI and
/// Anthropic and is equivalent for the discriminated unions MCP servers emit
/// in practice. When both keywords are present (rare, ambiguous to merge),
/// the existing `anyOf` wins and `oneOf` is dropped. Runs once per tool at
/// discovery, so the rendered tools JSON stays KV-cache-stable.
pub fn rewriteOneOf(a: Allocator, v: *Value) Allocator.Error!void {
    switch (v.*) {
        .object => |*obj| {
            if (obj.get("oneOf")) |branches| {
                if (obj.get("anyOf") == null) try obj.put(a, "anyOf", branches);
                _ = obj.swapRemove("oneOf");
            }
            var it = obj.iterator();
            while (it.next()) |e| try rewriteOneOf(a, e.value_ptr);
        },
        .array => |*arr| for (arr.items) |*item| try rewriteOneOf(a, item),
        else => {},
    }
}

/// Latest MCP revision advertised during initialization.
pub const latest_protocol = "2025-11-25";

/// Revisions whose initialize, tools, and content schemas are compatible with
/// the subset implemented by this client.
pub const supported_protocols = [_][]const u8{
    latest_protocol,
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

pub const Transport = enum {
    stdio,
    streamable_http,
};

fn supportsProtocol(transport: Transport, version: []const u8) bool {
    for (supported_protocols) |supported| {
        if (!std.mem.eql(u8, version, supported)) continue;
        // Streamable HTTP replaced the legacy HTTP+SSE transport in
        // 2025-03-26. The older revision remains compatible over stdio only.
        return transport == .stdio or !std.mem.eql(u8, version, "2024-11-05");
    }
    return false;
}

pub fn negotiatedProtocol(response: Value, transport: Transport) ![]const u8 {
    if (response != .object) return error.BadMcpInitializeResponse;
    const result = response.object.get("result") orelse return error.BadMcpInitializeResponse;
    if (result != .object) return error.BadMcpInitializeResponse;
    const version = result.object.get("protocolVersion") orelse return error.MissingMcpProtocolVersion;
    if (version != .string) return error.InvalidMcpProtocolVersion;
    if (supportsProtocol(transport, version.string)) return version.string;
    return error.UnsupportedMcpProtocolVersion;
}

test "rewriteOneOf: converts oneOf to anyOf, recursively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"oneOf":[{"type":"string"}],"properties":{"x":{"oneOf":[{"type":"number"},{"type":"null"}]}}}
    , .{});
    try rewriteOneOf(a, &v);
    try std.testing.expect(v.object.get("oneOf") == null);
    try std.testing.expectEqual(@as(usize, 1), v.object.get("anyOf").?.array.items.len);
    const x = v.object.get("properties").?.object.get("x").?;
    try std.testing.expect(x.object.get("oneOf") == null);
    try std.testing.expectEqual(@as(usize, 2), x.object.get("anyOf").?.array.items.len);
}

test "rewriteOneOf: existing anyOf wins when both are present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"anyOf":[{"type":"string"}],"oneOf":[{"type":"number"},{"type":"boolean"}]}
    , .{});
    try rewriteOneOf(a, &v);
    try std.testing.expect(v.object.get("oneOf") == null);
    // the pre-existing single-branch anyOf survives, the oneOf is dropped
    try std.testing.expectEqual(@as(usize, 1), v.object.get("anyOf").?.array.items.len);
}

test "rewriteOneOf: arrays and scalars pass through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"items":[{"oneOf":[1,2]},"plain",42]}
    , .{});
    try rewriteOneOf(a, &v);
    const first = v.object.get("items").?.array.items[0];
    try std.testing.expect(first.object.get("oneOf") == null);
    try std.testing.expect(first.object.get("anyOf") != null);
}

test "initialize negotiation accepts transport-compatible protocol versions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for (supported_protocols) |version| {
        const json = try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"{s}"}}}}
        , .{version});
        const response = try std.json.parseFromSliceLeaky(Value, a, json, .{});
        try std.testing.expectEqualStrings(version, try negotiatedProtocol(response, .stdio));
        if (std.mem.eql(u8, version, "2024-11-05")) {
            try std.testing.expectError(error.UnsupportedMcpProtocolVersion, negotiatedProtocol(response, .streamable_http));
        } else {
            try std.testing.expectEqualStrings(version, try negotiatedProtocol(response, .streamable_http));
        }
    }
}

test "initialize negotiation rejects missing, non-string, and unsupported versions" {
    const cases = [_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "{\"result\":{}}", .expected = error.MissingMcpProtocolVersion },
        .{ .json = "{\"result\":{\"protocolVersion\":20251125}}", .expected = error.InvalidMcpProtocolVersion },
        .{ .json = "{\"result\":{\"protocolVersion\":\"2099-01-01\"}}", .expected = error.UnsupportedMcpProtocolVersion },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.expected, negotiatedProtocol(parsed.value, .streamable_http));
    }
}
