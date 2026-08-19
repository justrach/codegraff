//! Client-side path normalization for CodeDB Pro's resident daemon.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const PreparedInput = struct {
    value: std.json.Value,
    owned_object: ?std.json.ObjectMap = null,
    owned_path: ?[]u8 = null,

    pub fn deinit(self: *PreparedInput, gpa: Allocator) void {
        if (self.owned_object) |*obj| obj.deinit(gpa);
        if (self.owned_path) |path| gpa.free(path);
    }
};

fn companionPathKey(tool: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, tool, "mcp__codedbpro__read") or
        std.mem.eql(u8, tool, "mcp__codedbpro__edit") or
        std.mem.eql(u8, tool, "mcp__codedbpro__lint") or
        std.mem.eql(u8, tool, "mcp__codedbpro__diff"))
        return "file";
    if (std.mem.eql(u8, tool, "mcp__codedbpro__search") or
        std.mem.eql(u8, tool, "mcp__codedbpro__faster_search") or
        std.mem.eql(u8, tool, "mcp__codedbpro__meta_search"))
        return "path";
    return null;
}

/// Errors caused by model arguments or session path context should open the
/// native fallback but must not generate upstream CodeDB Pro bug reports.
pub fn callerError(text: []const u8) bool {
    for ([_][]const u8{
        "file not found",
        "path not found",
        "no content provided",
        "missing content",
        "missing 'hash'",
        "is a directory",
        "permission denied",
        "path too long",
        // Transport / client-cap names from `reg.call catch |err| @errorName(err)`.
        // Dead daemon (binary replaced mid-session) or a line past graff's
        // 1 MiB stdio reader — not a CodeDB Pro tool bug (#527, #528, #552).
        "WriteFailed",
        "StreamTooLong",
        "McpClosed",
        "McpResponseTooLarge",
        "McpHandshakeTimeout",
        "BrokenPipe",
    }) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

/// CodeDB Pro's resident daemon has one launch cwd that can outlive and differ
/// from the Graff session using it. Normalize path-bearing calls at the client
/// boundary so relative model arguments keep their documented session-cwd
/// meaning instead of accidentally resolving inside the daemon's first repo.
pub fn prepareInput(gpa: Allocator, io: Io, agent_cwd: ?[]const u8, tool: []const u8, input: std.json.Value) !PreparedInput {
    const key = companionPathKey(tool) orelse return .{ .value = input };
    if (input != .object) return .{ .value = input };
    const path_value = input.object.get(key) orelse return .{ .value = input };
    if (path_value != .string or std.fs.path.isAbsolute(path_value.string)) return .{ .value = input };

    var cwd_buf: [4096]u8 = undefined;
    const base = if (agent_cwd) |worktree|
        worktree
    else blk: {
        const n = try Io.Dir.cwd().realPathFile(io, ".", &cwd_buf);
        break :blk cwd_buf[0..n];
    };
    const absolute = try std.fs.path.resolve(gpa, &.{ base, path_value.string });
    errdefer gpa.free(absolute);

    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(gpa);
    var it = input.object.iterator();
    while (it.next()) |entry| try object.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
    try object.put(gpa, key, .{ .string = absolute });
    return .{
        .value = .{ .object = object },
        .owned_object = object,
        .owned_path = absolute,
    };
}

test "prepareInput resolves CodeDB Pro paths against the agent cwd" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"file\":\"src/main.zig\",\"mode\":\"full\"}", .{});
    var prepared_read = try prepareInput(std.testing.allocator, std.testing.io, "/tmp/graff-worktree", "mcp__codedbpro__read", read_input);
    defer prepared_read.deinit(std.testing.allocator);
    const expected_read = if (@import("builtin").os.tag == .windows) "\\tmp\\graff-worktree\\src\\main.zig" else "/tmp/graff-worktree/src/main.zig";
    try std.testing.expectEqualStrings(expected_read, prepared_read.value.object.get("file").?.string);
    try std.testing.expectEqualStrings("src/main.zig", read_input.object.get("file").?.string);

    const search_input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"pattern\":\"needle\",\"path\":\"src\"}", .{});
    var prepared_search = try prepareInput(std.testing.allocator, std.testing.io, "/tmp/graff-worktree", "mcp__codedbpro__faster_search", search_input);
    defer prepared_search.deinit(std.testing.allocator);
    const expected_search = if (@import("builtin").os.tag == .windows) "\\tmp\\graff-worktree\\src" else "/tmp/graff-worktree/src";
    try std.testing.expectEqualStrings(expected_search, prepared_search.value.object.get("path").?.string);
}

test "caller errors are not filed as CodeDB Pro defects" {
    try std.testing.expect(callerError("{\"ok\":false,\"error\":\"path not found\"}"));
    try std.testing.expect(callerError("{\"ok\":false,\"error\":\"no content provided\"}"));
    try std.testing.expect(callerError("{\"ok\":false,\"error\":\"memo get: missing 'hash'\"}"));
    try std.testing.expect(callerError("WriteFailed"));
    try std.testing.expect(callerError("McpResponseTooLarge"));
    try std.testing.expect(callerError("McpClosed"));
    try std.testing.expect(!callerError("lint: failed to spawn eslint"));
}
