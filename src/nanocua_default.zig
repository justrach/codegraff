//! Computer use on macOS is nanocua (ADR 0314), an app of its own that release
//! builds ship beside graff. graff links none of it: when the app is there, it
//! is one more MCP server, `nanocua mcp`, which answers handshakes without
//! starting the app. A server the user named `nanocua` themselves wins, and
//! `graff mcp disable nanocua` switches it off like any other.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const server_name = "nanocua";
const executable = "nanocua.app/Contents/MacOS/nanocua";

/// Whether `home` is `real` or a folder inside it, as an account's HOME under
/// Harness is. A $HOME anywhere else is a sandbox, and stays one.
pub fn within(home: []const u8, real: []const u8) bool {
    const h = std.mem.trimEnd(u8, home, "/");
    const r = std.mem.trimEnd(u8, real, "/");
    if (r.len == 0 or !std.mem.startsWith(u8, h, r)) return false;
    return h.len == r.len or h[r.len] == '/';
}

/// The home the one app on this Mac is under: the user's real one when $HOME is
/// inside it. A sandbox's HOME is used as it is, so a test running graff can't
/// find or replace the app installed on the machine running it.
pub fn userHome(home: []const u8) []const u8 {
    if (builtin.is_test or builtin.os.tag != .macos) return home;
    const user = std.c.getpwuid(std.c.getuid()) orelse return home;
    const real = std.mem.span(user.dir orelse return home);
    return if (within(home, real)) real else home;
}

/// Where install.sh and `graff update` put the app.
pub fn installRoot(arena: Allocator, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/Applications", .{home}) catch null;
}

fn inRoot(io: Io, arena: Allocator, root: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, executable }) catch return null;
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return path;
}

/// The shipped app's program. Unit tests and a sandbox's HOME look only under
/// that home, so an app installed on the machine doesn't change what they see.
pub fn find(io: Io, arena: Allocator, home: []const u8) ?[]const u8 {
    if (installRoot(arena, home)) |root| if (inRoot(io, arena, root)) |p| return p;
    if (builtin.is_test) return null;
    const user = userHome(home);
    if (!within(home, user)) return null;
    if (installRoot(arena, user)) |root| if (inRoot(io, arena, root)) |p| return p;
    if (inRoot(io, arena, "/Applications")) |p| return p;
    // An unpacked release tarball, which has it beside graff.
    const exe = std.process.executablePathAlloc(io, arena) catch return null;
    return inRoot(io, arena, std.fs.path.dirname(exe) orelse return null);
}

fn entry(arena: Allocator, command: []const u8) !std.json.Value {
    var args = std.json.Array.init(arena);
    try args.append(.{ .string = "mcp" });
    var cfg: std.json.ObjectMap = .empty;
    try cfg.put(arena, "command", .{ .string = command });
    try cfg.put(arena, "args", .{ .array = args });
    return .{ .object = cfg };
}

/// Fills `nanocua` when nothing else defined that name, on macOS, with the app
/// there. True means this entry is graff's own, which needs no consent: it runs
/// the app graff shipped, and that app asks the user itself before anything acts.
pub fn merge(io: Io, arena: Allocator, home: []const u8, servers: *std.json.ObjectMap, found: *bool) bool {
    if (builtin.os.tag != .macos) return false;
    return mergeFound(io, arena, home, servers, found);
}

fn mergeFound(io: Io, arena: Allocator, home: []const u8, servers: *std.json.ObjectMap, found: *bool) bool {
    if (home.len == 0 or servers.get(server_name) != null) return false;
    const command = find(io, arena, home) orelse return false;
    const cfg = entry(arena, command) catch return false;
    servers.put(arena, server_name, cfg) catch return false;
    found.* = true;
    return true;
}

const testing = std.testing;

fn tmpHome(io: Io, arena: Allocator, tmp: *testing.TmpDir, with_app: bool) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const home = try arena.dupe(u8, buf[0..n]);
    if (with_app) {
        const path = try std.fmt.allocPrint(arena, "{s}/Applications/{s}", .{ home, executable });
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
    }
    return home;
}

test "only a home inside the user's own leads back to it" {
    try testing.expect(within("/Users/ada", "/Users/ada"));
    try testing.expect(within("/Users/ada/", "/Users/ada"));
    try testing.expect(within("/Users/ada/.harness/accounts/two", "/Users/ada"));
    try testing.expect(!within("/Users/adam", "/Users/ada"));
    try testing.expect(!within("/tmp/sandbox", "/Users/ada"));
    try testing.expect(!within("/var/folders/x/T/home", "/Users/ada"));
    try testing.expect(!within("/Users/ada", ""));
}

test "the shipped app becomes the nanocua server" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const home = try tmpHome(testing.io, a, &tmp, true);
    var servers: std.json.ObjectMap = .empty;
    var found = false;
    try testing.expect(mergeFound(testing.io, a, home, &servers, &found));
    try testing.expect(found);
    const cfg = servers.get(server_name).?.object;
    try testing.expect(std.mem.endsWith(u8, cfg.get("command").?.string, "/Applications/nanocua.app/Contents/MacOS/nanocua"));
    try testing.expectEqualStrings("mcp", cfg.get("args").?.array.items[0].string);
}

test "no app, no home or the user's own nanocua: nothing is added" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var servers: std.json.ObjectMap = .empty;
    var found = false;
    try testing.expect(!mergeFound(testing.io, a, try tmpHome(testing.io, a, &tmp, false), &servers, &found));
    try testing.expect(!mergeFound(testing.io, a, "", &servers, &found));
    try testing.expect(!found);
    const home = try tmpHome(testing.io, a, &tmp, true);
    try servers.put(a, server_name, .{ .string = "theirs" });
    try testing.expect(!mergeFound(testing.io, a, home, &servers, &found));
    try testing.expectEqualStrings("theirs", servers.get(server_name).?.string);
}

test "only macOS offers it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const home = try tmpHome(testing.io, a, &tmp, true);
    var servers: std.json.ObjectMap = .empty;
    var found = false;
    try testing.expectEqual(builtin.os.tag == .macos, merge(testing.io, a, home, &servers, &found));
}

test "through the config: shipped and consent-free, the user's files win and can switch it off" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const mcp_config = @import("mcp_config.zig");
    const mcp_status = @import("mcp_status.zig");
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const home = try tmpHome(io, a, &tmp, true);
    const global = try std.fmt.allocPrint(a, "{s}/global.json", .{home});

    const plain = mcp_config.load(io, a, tmp.dir, ".mcp.json", global, home, false);
    try testing.expect(plain.shipped_nanocua and plain.found);
    try testing.expect(plain.servers.get(server_name) != null);
    try testing.expectEqualStrings("shipped", mcp_status.sourceOf(plain, server_name));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = global, .data = "{\"mcpServers\":{},\"disabledMcpServers\":{\"nanocua\":{}}}" });
    const off = mcp_config.load(io, a, tmp.dir, ".mcp.json", global, home, false);
    try testing.expect(off.servers.get(server_name) == null);
    try testing.expect(off.disabled.get(server_name) != null);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = global, .data = "{\"mcpServers\":{\"nanocua\":{\"command\":\"theirs\"}}}" });
    const theirs = mcp_config.load(io, a, tmp.dir, ".mcp.json", global, home, false);
    try testing.expect(!theirs.shipped_nanocua);
    try testing.expectEqualStrings("theirs", theirs.servers.get(server_name).?.object.get("command").?.string);
    try testing.expectEqualStrings("global", mcp_status.sourceOf(theirs, server_name));
}
