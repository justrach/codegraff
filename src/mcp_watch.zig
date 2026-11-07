//! Servers added to the MCP config while a session runs join it (live join).
//!
//! `graff mcp add` writes `.mcp.json`; before this, a running session only saw
//! the new server after a restart or `/mcp trust`. The watcher is armed only
//! once the session has connected its configured servers (consent given,
//! `--yolo`, or `/mcp trust`), so it never widens what the user agreed to: it
//! joins names that appear after arming and ignores ones boot chose to skip.

const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp.zig");
const mcp_boot = @import("mcp_boot.zig");
const mcp_config = @import("mcp_config.zig");

const State = struct {
    armed: bool = false,
    project_path: []const u8 = ".mcp.json",
    stamp: u64 = 0,
    /// Hashes of every configured name when armed or last joined.
    known: std.ArrayList(u64) = .empty,
};
var g: State = .{};
const alloc = std.heap.page_allocator;

pub fn resetForTest() void {
    g.known.deinit(alloc);
    g = .{};
}

fn nameHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6d63, name);
}

fn isKnown(name: []const u8) bool {
    const h = nameHash(name);
    for (g.known.items) |k| if (k == h) return true;
    return false;
}

fn signature(io: Io, global_path: ?[]const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_]?[]const u8{ g.project_path, global_path }) |maybe| {
        const path = maybe orelse continue;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch {
            h.update("-");
            continue;
        };
        const mtime: i128 = st.mtime.nanoseconds;
        h.update(std.mem.asBytes(&st.size));
        h.update(std.mem.asBytes(&mtime));
    }
    return h.final();
}

fn load(reg: *mcp.Registry) mcp_config.Merged {
    return mcp_config.load(reg.io, reg.arena(), Io.Dir.cwd(), g.project_path, reg.global_config_path, reg.home, reg.global_is_override);
}

/// The session connected its configured servers: from here, new ones join.
pub fn arm(reg: *mcp.Registry, project_path: []const u8) void {
    g.project_path = project_path;
    g.known.clearRetainingCapacity();
    const merged = load(reg);
    var it = merged.servers.iterator();
    while (it.next()) |e| g.known.append(alloc, nameHash(e.key_ptr.*)) catch {};
    g.stamp = signature(reg.io, reg.global_config_path);
    g.armed = true;
}

/// Before a model request: start servers that appeared in the config since the
/// last look and give their handshakes a short window. True when tools joined.
pub fn poll(reg: *mcp.Registry) bool {
    if (!g.armed) return false;
    const now = signature(reg.io, reg.global_config_path);
    if (now == g.stamp) return false;
    g.stamp = now;
    const merged = load(reg);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    var it = merged.servers.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (isKnown(name)) continue;
        g.known.append(alloc, nameHash(name)) catch {};
        if (e.value_ptr.* != .object or mcp_boot.alreadyStarting(reg, name)) continue;
        const state = @import("mcp_state.zig").load(reg.io, reg.arena(), reg.home);
        if (state.isDisabled(name) or (!state.isEnabled(name) and @import("mcp_state.zig").offInConfig(e.value_ptr.*.object))) continue;
        if (!mcp_boot.queueConfig(reg, name, e.value_ptr.*.object)) continue;
        names.append(alloc, name) catch continue;
        if (@import("engine_sink.zig").hostedSink()) |sink| {
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "MCP: connecting {s} (added to the config)", .{name}) catch "MCP: connecting a new server";
            sink.emit(reg.io, .{ .session_notice = .{ .text = text, .tone = .dim } });
        }
    }
    if (names.items.len == 0) return false;
    return mcp_boot.joinNamedWithin(reg, names.items, 8_000);
}

test "only names added after arming join; a touched file with no new name is quiet" {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/mcp.json", .{dir});
    try tmp.dir.writeFile(io, .{ .sub_path = "mcp.json", .data = "{\"mcpServers\":{\"old\":{\"command\":\"/bin/false\"}}}" });
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    defer reg.deinit();
    arm(&reg, path);
    try std.testing.expect(isKnown("old"));
    try std.testing.expect(!poll(&reg)); // unchanged
    try tmp.dir.writeFile(io, .{ .sub_path = "mcp.json", .data = "{\"mcpServers\":{\"old\":{\"command\":\"/bin/false\"},\"brand-new\":{\"command\":\"/bin/false\"}}}" });
    _ = poll(&reg); // /bin/false never handshakes; the point is it was picked up
    try std.testing.expect(isKnown("brand-new"));
    try std.testing.expect(mcp_boot.alreadyStarting(&reg, "brand-new") or reg.pending_starts.len == 0);
    try std.testing.expect(!poll(&reg)); // nothing new since
}
