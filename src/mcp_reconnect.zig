//! Reconnect an MCP server: drop its cached catalog and run a real handshake.
//!
//! - `probe` (`graff mcp reconnect <name>|--all`, the desktop app's Reconnect
//!   and "Check all"): start each server fresh, record its live catalog for
//!   the next session, report a status row, and stop it again. The desktop app
//!   starts a new graff per run, so this is what makes the *next* turn see a
//!   server's real tools.
//! - `live` (`/mcp reconnect <name>` in a session): replace the server in the
//!   session's registry at the same index, so tools other parts of the session
//!   already hold keep pointing at the right server. A server that failed at
//!   startup joins the registry for the first time.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const mcp_cache = @import("mcp_cache.zig");
const mcp_config = @import("mcp_config.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_start = @import("mcp_start.zig");
const mcp_state = @import("mcp_state.zig");
const mcp_status = @import("mcp_status.zig");
const mcp_teardown = @import("mcp_teardown.zig");
const StartOutcome = @import("mcp_boot.zig").StartOutcome;

/// Fresh handshakes for `names` (every switched-on server when null), run
/// concurrently. Rows come back in config order; switched-off servers are
/// reported as such and not started.
pub fn probe(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, merged: mcp_config.Merged, names: ?[]const []const u8, environ_map: anytype) ![]mcp_status.Row {
    const all = try mcp_status.offline(io, arena, home, merged, environ_map);
    var rows: std.ArrayList(mcp_status.Row) = .empty;
    next: for (all) |row| {
        if (names) |wanted| {
            for (wanted) |n| {
                if (std.mem.eql(u8, n, row.name)) break;
            } else continue :next;
        } else if (!row.enabled) continue;
        try rows.append(arena, row);
    }
    const futures = try arena.alloc(?Io.Future(StartOutcome), rows.items.len);
    @memset(futures, null);
    for (rows.items, futures, 0..) |row, *fut, i| {
        if (!row.enabled) continue;
        const cfg = merged.servers.get(row.name).?.object;
        mcp_cache.forget(io, arena, home, mcp_cache.keyFor(arena, cfg));
        const ctx: mcp_start.Ctx = .{ .gpa = gpa, .io = io, .home = home, .show_diagnostics = false, .stdio_probe = true, .lazy_stdio = false };
        fut.* = io.concurrent(mcp_start.task, .{ ctx, row.name, cfg }) catch null;
        // No thread for it: run it here rather than skip it.
        if (fut.* == null) apply(io, arena, &rows.items[i], mcp_start.task(ctx, row.name, cfg));
    }
    for (rows.items, futures) |*row, *fut| if (fut.*) |*f| apply(io, arena, row, f.await(io));
    for (rows.items) |*row| if (row.state == .failed and row.transport[0] == 's' and !std.mem.eql(u8, row.errorCode orelse "", "FileNotFound")) {
        const cfg = merged.servers.get(row.name).?.object;
        row.detail = stderrHint(io, gpa, arena, cfg);
        if (row.detail != null) @import("mcp_failures.zig").record(io, arena, home, mcp_cache.keyFor(arena, cfg), .{ .code = row.errorCode orelse "failed", .text = row.@"error" orelse "failed to start", .detail = row.detail });
    };
    return rows.items;
}

/// After a local server failed to start: run it once more with no input for
/// a moment and keep the last line it wrote to stderr, which is usually the
/// reason a person can act on. Only ever on an explicit reconnect.
fn stderrHint(io: Io, gpa: Allocator, arena: Allocator, cfg: std.json.ObjectMap) ?[]const u8 {
    const spec = @import("mcp_lazy.zig").stdioSpec(io, gpa, arena, cfg) catch return null;
    defer if (spec.env) |m| m.deinit();
    const run = @import("process_runner.zig").runCappedWithOptions(arena, io, spec.argv, 4096, 16 * 1024, 3_000, .{
        .cwd = if (spec.cwd) |p| .{ .path = p } else .inherit,
        .environ_map = spec.env,
        .kill_process_tree = true,
    }) catch return null;
    return lastLine(arena, run.stderr);
}

fn lastLine(arena: Allocator, text: []const u8) ?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, @import("acp_engine.zig").stripSgr(arena, raw) catch raw, " \t\r");
        if (line.len > 0) return line[0..@min(line.len, 240)];
    }
    return null;
}

/// Fold one start into its row, then stop the server: a probe leaves nothing
/// running.
fn apply(io: Io, arena: Allocator, row: *mcp_status.Row, outcome: StartOutcome) void {
    var o = outcome;
    const server = o.server orelse {
        if (mcp_start.failure(row.name)) |err| mcp_status.failedRow(row, err) else row.state = .failed;
        return;
    };
    var tools: std.ArrayList(mcp_status.ToolRow) = .empty;
    for (o.tools) |t| tools.append(arena, .{
        .name = arena.dupe(u8, t.original_name) catch continue,
        .description = arena.dupe(u8, firstLine(t.description)) catch "",
    }) catch break;
    row.state = .ready;
    row.@"error" = null;
    row.errorCode = null;
    row.detail = null;
    row.tools = tools.items;
    row.toolCount = tools.items.len;
    mcp_rpc.deinitServer(server, io, .init(io, mcp_teardown.teardown_grace));
    if (o.arena_state) |*a| a.deinit();
}

fn firstLine(text: []const u8) []const u8 {
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    return std.mem.trim(u8, line[0..@min(line.len, 200)], " \t\r");
}

pub const LiveResult = union(enum) {
    reconnected: usize,
    connected: usize,
    still_connecting,
    switched_off,
    not_configured,
    failed: anyerror,
};

/// Restart `name` inside the session. The caller re-renders its catalog.
pub fn live(reg: *mcp.Registry, merged: mcp_config.Merged, name: []const u8) LiveResult {
    if (@import("mcp_boot.zig").alreadyStarting(reg, name) and !present(reg, name)) return .still_connecting;
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    const a = reg.arena();
    if (mcp_state.load(reg.io, a, reg.home).isDisabled(name)) return .switched_off;
    const index: ?usize = for (reg.servers, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) break i;
    } else null;
    const cfg = configFor(reg, merged, name, index) orelse return .not_configured;
    mcp_cache.forget(reg.io, a, reg.home, mcp_cache.keyFor(a, cfg));

    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    const lazy = reg.lazy_stdio;
    reg.lazy_stdio = false; // asked for a reconnect: really start it
    defer reg.lazy_stdio = lazy;
    reg.startServer(a, &servers, &tools, a.dupe(u8, name) catch return .{ .failed = error.OutOfMemory }, cfg) catch |err| {
        mcp_start.note(name, err);
        @import("mcp_failures.zig").recordErr(reg.io, reg.gpa, reg.home, cfg, err, null);
        return .{ .failed = err };
    };
    mcp_start.clear(name);
    @import("mcp_failures.zig").clearCfg(reg.io, reg.gpa, reg.home, cfg);
    return swapIn(reg, index, servers.items[0], tools.items) catch |err| .{ .failed = err };
}

fn present(reg: *mcp.Registry, name: []const u8) bool {
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    for (reg.servers) |s| if (std.mem.eql(u8, s.name, name)) return true;
    return false;
}

fn swapIn(reg: *mcp.Registry, index: ?usize, server: *mcp_rpc.Server, fresh: []mcp.Tool) !LiveResult {
    const a = reg.arena();
    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    try servers.appendSlice(a, reg.servers);
    const at = index orelse servers.items.len;
    if (index) |i| {
        mcp_rpc.deinitServer(servers.items[i], reg.io, .init(reg.io, mcp_teardown.teardown_grace));
        servers.items[i] = server;
    } else try servers.append(a, server);
    var tools: std.ArrayList(mcp.Tool) = .empty;
    for (reg.tools) |t| if (t.server_index != at) try tools.append(a, t);
    for (fresh) |t| {
        var copy = t;
        copy.server_index = at;
        try tools.append(a, copy);
    }
    // Tools withdrawn after an earlier close are back.
    var withdrawn: std.ArrayList(@import("mcp_call.zig").Withdrawn) = .empty;
    for (reg.withdrawn) |w| if (!std.mem.eql(u8, w.server, server.name)) try withdrawn.append(a, w);
    reg.servers = servers.items;
    reg.tools = tools.items;
    reg.withdrawn = withdrawn.items;
    reg.catalog_dirty.store(true, .release);
    return if (index != null) .{ .reconnected = fresh.len } else .{ .connected = fresh.len };
}

/// The config to start `name` from: its config entry, else how the session
/// launched it (`/mcp add`, a client-provided server).
fn configFor(reg: *mcp.Registry, merged: mcp_config.Merged, name: []const u8, index: ?usize) ?std.json.ObjectMap {
    if (merged.servers.get(name)) |v| if (v == .object) return v.object;
    const i = index orelse return null;
    const a = reg.arena();
    return switch (reg.servers[i].transport) {
        .stdio => |s| if (s.relaunch) |r| r.cfg else null,
        .dormant => |d| d.cfg,
        .http => |h| blk: {
            var cfg: std.json.ObjectMap = .empty;
            cfg.put(a, "url", .{ .string = h.url }) catch break :blk null;
            if (h.headers.len > 0) {
                var headers: std.json.ObjectMap = .empty;
                for (h.headers) |hd| headers.put(a, hd.name, .{ .string = hd.value }) catch break :blk null;
                cfg.put(a, "headers", .{ .object = headers }) catch break :blk null;
            }
            break :blk cfg;
        },
    };
}

test "a failed reconnect keeps the server's last stderr line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("tool: not licensed. Run: tool activate", lastLine(a, "starting\n\x1b[31mtool: not licensed. Run: tool activate\x1b[0m\n\n").?);
    try std.testing.expect(lastLine(a, "  \n") == null);
}

test "live reconnect swaps a server in place and brings back withdrawn tools" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var reg = mcp.Registry.empty(gpa, io);
    defer reg.deinit();
    reg.stdio_probe = false;
    reg.lazy_stdio = false;
    const script =
        \\while read -r l; do
        \\  id=$(printf '%s' "$l" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
        \\  [ -z "$id" ] && continue
        \\  case "$l" in
        \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"f","version":"1"}}}\n' "$id" ;;
        \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"ping","description":"d","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
        \\    *) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"pong"}]}}\n' "$id" ;;
        \\  esac
        \\done
    ;
    _ = try reg.addServer("first", "/bin/sh", &.{ "-c", script });
    _ = try reg.addServer("second", "/bin/sh", &.{ "-c", script });
    const old_second = reg.servers[1];
    reg.withdrawn = try reg.arena().dupe(@import("mcp_call.zig").Withdrawn, &.{.{ .qualified_name = "mcp__second__ping", .server = "second", .reason = "McpClosed" }});

    const merged: mcp_config.Merged = .{};
    const result = live(&reg, merged, "second");
    try std.testing.expectEqual(@as(usize, 1), result.reconnected);
    try std.testing.expectEqual(@as(usize, 2), reg.servers.len);
    try std.testing.expect(reg.servers[1] != old_second);
    try std.testing.expectEqualStrings("second", reg.servers[1].name);
    try std.testing.expectEqual(@as(usize, 0), reg.withdrawn.len);
    var second_tools: usize = 0;
    for (reg.tools) |t| if (t.server_index == 1) {
        second_tools += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), second_tools);
    const args: std.json.Value = .{ .object = .empty };
    const out = try reg.call(gpa, "mcp__second__ping", args);
    defer gpa.free(out.text);
    try std.testing.expectEqualStrings("pong", out.text);
    try std.testing.expectEqual(LiveResult.not_configured, live(&reg, merged, "missing"));
}
