//! Bundled Smolify tool metadata. Startup advertises these schemas without
//! dialing the hosted MCP; the transport initializes only after an approved
//! tool call. Refresh the generated JSON with update-smolify-manifest.py.

const std = @import("std");
const mcp_protocol = @import("mcp_protocol.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const manifest_json = @embedFile("smolify-tools.json");

pub const bundled_protocol = mcp_protocol.legacy_protocol;

const public_read_tools = [_][]const u8{
    "discover_public_projects",
    "read_docs_structure",
    "search_docs",
    "get_doc_page",
    "build_docs_context",
    "resolve_public_symbols",
    "inspect_public_symbols",
    "read_public_source",
};

pub fn isPublicReadName(name: []const u8) bool {
    for (public_read_tools) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

pub fn isPublicReadQualified(name: []const u8) bool {
    const prefix = "mcp__smolify__";
    return std.mem.startsWith(u8, name, prefix) and isPublicReadName(name[prefix.len..]);
}

/// Append bundled Smolify tools to an MCP-compatible Tool list. Keeping this
/// generic makes this leaf module independent from mcp.zig's Registry type.
pub fn appendTools(
    comptime Tool: type,
    a: Allocator,
    out: *std.ArrayList(Tool),
    server_index: usize,
    full_access: bool,
) !usize {
    const parsed = try std.json.parseFromSliceLeaky(Value, a, manifest_json, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.BadSmolifyManifest;
    const protocol = parsed.object.get("protocolVersion") orelse return error.BadSmolifyManifest;
    if (protocol != .string or !std.mem.eql(u8, protocol.string, bundled_protocol)) return error.StaleSmolifyManifestProtocol;
    const tools = parsed.object.get("tools") orelse return error.BadSmolifyManifest;
    if (tools != .array) return error.BadSmolifyManifest;
    const before = out.items.len;
    for (tools.array.items) |tool| {
        if (tool != .object) return error.BadSmolifyManifest;
        const name_v = tool.object.get("name") orelse return error.BadSmolifyManifest;
        if (name_v != .string or name_v.string.len == 0) return error.BadSmolifyManifest;
        if (!full_access and !isPublicReadName(name_v.string)) continue;
        const description = if (tool.object.get("description")) |v|
            (if (v == .string) v.string else "")
        else if (tool.object.get("title")) |v|
            (if (v == .string) v.string else "")
        else
            "";
        var schema = tool.object.get("inputSchema") orelse Value{ .object = .empty };
        try mcp_protocol.rewriteOneOf(a, &schema);
        try out.append(a, .{
            .server_index = server_index,
            .original_name = try a.dupe(u8, name_v.string),
            .qualified_name = try std.fmt.allocPrint(a, "mcp__smolify__{s}", .{name_v.string}),
            .description = try a.dupe(u8, description),
            .input_schema = schema,
        });
    }
    if (out.items.len == before) return error.EmptySmolifyManifest;
    return out.items.len - before;
}

const TestTool = struct {
    server_index: usize,
    original_name: []const u8,
    qualified_name: []const u8,
    description: []const u8,
    input_schema: Value,
};

test "bundled default exposes only anonymous public-read tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tools: std.ArrayList(TestTool) = .empty;
    try std.testing.expectEqual(@as(usize, public_read_tools.len), try appendTools(TestTool, a, &tools, 3, false));
    for (tools.items) |tool| {
        try std.testing.expectEqual(@as(usize, 3), tool.server_index);
        try std.testing.expect(isPublicReadQualified(tool.qualified_name));
        try std.testing.expect(tool.input_schema == .object);
    }
}

test "full opt-in exposes the complete generated manifest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tools: std.ArrayList(TestTool) = .empty;
    try std.testing.expectEqual(@as(usize, 13), try appendTools(TestTool, a, &tools, 0, true));
    try std.testing.expect(!isPublicReadQualified("mcp__smolify__publish_docs"));
}
