//! The last start failure of each MCP server, kept across sessions so
//! `graff mcp status` (the desktop app's MCP servers page, the fullscreen
//! client's `/mcp`) can say a server is broken, and why, without starting it.
//!
//! The desktop app starts a new graff for every turn. Without this, a server
//! that failed in the last turn read as "not checked yet" until someone
//! reconnected it. Keyed like the catalog cache (mcp_cache.keyFor: command,
//! args, cwd, env), recorded on every failed start, and cleared by the next
//! real start that succeeds. A server restored dormant from the cache did not
//! start, so it clears nothing.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const credential_store = @import("credential_store.zig");
const util = @import("util.zig");

const rel_path = ".codegraff/mcp-failures.json";

pub const Failure = struct {
    /// The error name (`FileNotFound`, `McpClosed`).
    code: []const u8,
    /// Human text for it (mcp_status.errorText).
    text: []const u8,
    /// The server's own last stderr line, when a reconnect read it.
    detail: ?[]const u8 = null,
    at_ms: i64 = 0,
};

fn path(arena: Allocator, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/" ++ rel_path, .{home}) catch null;
}

fn readServers(io: Io, arena: Allocator, p: []const u8) std.json.ObjectMap {
    const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 20)) catch return .empty;
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return .empty;
    if (root != .object) return .empty;
    const servers = root.object.get("servers") orelse return .empty;
    return if (servers == .object) servers.object else .empty;
}

fn str(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const v = obj.get(field) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn get(io: Io, arena: Allocator, home: []const u8, key: []const u8) ?Failure {
    const p = path(arena, home) orelse return null;
    const entry = readServers(io, arena, p).get(key) orelse return null;
    if (entry != .object) return null;
    return .{
        .code = str(entry.object, "code") orelse return null,
        .text = str(entry.object, "text") orelse "failed to start",
        .detail = str(entry.object, "detail"),
        .at_ms = if (entry.object.get("atMs")) |v| (if (v == .integer) v.integer else 0) else 0,
    };
}

/// Write `failure` for `key`, or remove it when null. Best-effort, locked like
/// the catalog cache: servers fail concurrently at startup.
fn update(io: Io, arena: Allocator, home: []const u8, key: []const u8, failure: ?Failure) void {
    if (key.len == 0) return;
    const p = path(arena, home) orelse return;
    if (failure == null) {
        // Most starts succeed: only touch the file when there is something to clear.
        if (readServers(io, arena, p).get(key) == null) return;
    }
    if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    const lock_path = std.fmt.allocPrint(arena, "{s}.lock", .{p}) catch return;
    const lock = Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch return;
    defer lock.close(io);
    var servers = readServers(io, arena, p);
    if (failure) |f| {
        var entry: std.json.ObjectMap = .empty;
        entry.put(arena, "code", .{ .string = f.code }) catch return;
        entry.put(arena, "text", .{ .string = f.text }) catch return;
        if (f.detail) |d| entry.put(arena, "detail", .{ .string = d }) catch return;
        entry.put(arena, "atMs", .{ .integer = util.unixMs(io) }) catch return;
        servers.put(arena, key, .{ .object = entry }) catch return;
    } else if (!servers.swapRemove(key)) return;
    var root: std.json.ObjectMap = .empty;
    root.put(arena, "servers", .{ .object = servers }) catch return;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(Value{ .object = root }) catch return;
    credential_store.replaceFile(io, Io.Dir.cwd(), p, aw.writer.buffered(), .default_file) catch {};
}

pub fn record(io: Io, arena: Allocator, home: []const u8, key: []const u8, failure: Failure) void {
    update(io, arena, home, key, failure);
}

pub fn clear(io: Io, arena: Allocator, home: []const u8, key: []const u8) void {
    update(io, arena, home, key, null);
}

/// Both from a `gpa` caller (pool threads have no arena of their own).
pub fn recordErr(io: Io, gpa: Allocator, home: []const u8, cfg: std.json.ObjectMap, err: anyerror, detail: ?[]const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    record(io, a, home, @import("mcp_cache.zig").keyFor(a, cfg), .{ .code = @errorName(err), .text = @import("mcp_status.zig").errorText(err), .detail = detail });
}

pub fn clearCfg(io: Io, gpa: Allocator, home: []const u8, cfg: std.json.ObjectMap) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    clear(io, a, home, @import("mcp_cache.zig").keyFor(a, cfg));
}

test "a start failure is kept across sessions until the next real start" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try std.testing.expect(get(io, a, home, "cmd:a") == null);
    clear(io, a, home, "cmd:a"); // nothing to clear: no file is written
    record(io, a, home, "cmd:a", .{ .code = "McpClosed", .text = "the server exited during startup", .detail = "a: not licensed" });
    record(io, a, home, "cmd:b", .{ .code = "FileNotFound", .text = "command not found" });
    const f = get(io, a, home, "cmd:a").?;
    try std.testing.expectEqualStrings("McpClosed", f.code);
    try std.testing.expectEqualStrings("a: not licensed", f.detail.?);
    clear(io, a, home, "cmd:a");
    try std.testing.expect(get(io, a, home, "cmd:a") == null);
    try std.testing.expectEqualStrings("command not found", get(io, a, home, "cmd:b").?.text);
}
