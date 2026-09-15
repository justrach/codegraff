//! Stable wire names, independent of server discovery order. Raw identities
//! stay on Tool/Server for configuration and MCP tools/call routing.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn serverOf(qualified: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, qualified, "mcp__")) return "";
    const rest = qualified[5..];
    return rest[0 .. std.mem.indexOf(u8, rest, "__") orelse rest.len];
}

fn allowed(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

// Escape unsafe UTF-8 bytes, literal escape markers and server delimiters.
// Unlike replacing punctuation with underscores, this keeps short names
// distinct without depending on which server finishes its handshake first.
fn component(a: Allocator, raw: []const u8, limit: usize, server: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (raw, 0..) |c, i| {
        const next: ?u8 = if (i + 1 < raw.len) raw[i + 1] else null;
        const reserved = c == '_' and if (next) |n|
            n == 'x' or (i == 0 and n == 'h') or (server and (n == '_' or !allowed(n)))
        else
            server;
        if (!allowed(c) or reserved) {
            try out.writer.print("_x{x:0>2}", .{c});
        } else try out.writer.writeByte(c);
    }
    const encoded = out.writer.buffered();
    if (encoded.len > 0 and encoded.len <= limit) return a.dupe(u8, encoded);
    // Reserve _h for bounded identities (literal _h prefixes are escaped).
    // 96 hash bits fit even when both server and tool names are oversized.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    return std.fmt.allocPrint(a, "_h{s}", .{std.fmt.bytesToHex(digest[0..12], .lower)});
}

pub fn qualify(a: Allocator, server: []const u8, tool: []const u8) ![]const u8 {
    const sv = try component(a, server, 26, true);
    defer a.free(sv);
    const name = try component(a, tool, 57 - sv.len, false);
    defer a.free(name);
    return std.fmt.allocPrint(a, "mcp__{s}__{s}", .{ sv, name });
}

test "#930 wire names escape punctuation and preserve ordinary names" {
    const a = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "wiki", "read_file", "mcp__wiki__read_file" },
        .{ "docs server", "room.for_branch", "mcp__docs_x20server__room_x2efor_branch" },
        .{ "docs_server", "read-file", "mcp__docs_server__read-file" },
        .{ "a__b", "read", "mcp__a_x5f_b__read" },
        .{ "a_ b", "read", "mcp__a_x5f_x20b__read" },
        .{ "a_", "read", "mcp__a_x5f__read" },
        .{ "docs_x20server", "read", "mcp__docs_x5fx20server__read" },
    };
    for (cases) |c| {
        const name = try qualify(a, c[0], c[1]);
        defer a.free(name);
        try std.testing.expectEqualStrings(c[2], name);
    }
}

test "#930 raw server identity controls eager policy search and schema loading" {
    const gate = @import("mcp_schema_gate.zig");
    const select = @import("mcp_select.zig");
    const mcp = @import("mcp.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved = gate.g_policy;
    defer gate.g_policy = saved;
    gate.reset();
    defer gate.reset();
    gate.g_policy = .{ .budget = 0 };
    const tools = [_]mcp.Tool{.{
        .server_index = 0,
        .server_name = "docs server",
        .original_name = "room.for_branch",
        .qualified_name = try qualify(a, "docs server", "room.for_branch"),
        .description = "Find a room",
        .input_schema = .{ .object = .empty },
    }};
    try std.testing.expect(gate.isDeferred(&tools, tools[0]));
    gate.g_policy.eager = &.{"docs server"};
    try std.testing.expect(!gate.isDeferred(&tools, tools[0]));
    gate.g_policy.eager = &.{};
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"server\":\"docs server\",\"query\":\"room\"}", .{});
    const found = try select.searchInto(a, &tools, input);
    try std.testing.expect(!found.is_error);
    try std.testing.expect(std.mem.indexOf(u8, found.text, tools[0].qualified_name) != null);
    const loaded = try gate.loadInto(a, &tools, input);
    try std.testing.expectEqual(@as(usize, 1), loaded.loaded);
    try std.testing.expect(gate.isLoaded(tools[0].qualified_name));
    try std.testing.expectEqualStrings("room.for_branch", tools[0].original_name);
}

test "#930 names remain distinct for escaping Unicode empty and oversized identities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long: [200]u8 = @splat('z');
    var other = long;
    other[199] = 'y';
    const inputs = [_][]const u8{ "a b", "a.b", "a_b", "a_x20b", "_h", "", "日本語", &long, &other, "a__b" };
    var names: std.StringHashMap(void) = .init(a);
    for (inputs) |server| for (inputs) |tool| {
        const name = try qualify(a, server, tool);
        try std.testing.expect(name.len <= 64);
        for (name) |c| try std.testing.expect(allowed(c));
        try std.testing.expect(!(try names.getOrPut(name)).found_existing);
        try std.testing.expectEqualStrings(name, try qualify(a, server, tool));
        try std.testing.expect(serverOf(name).len > 0);
    };
}
