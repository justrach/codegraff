//! What each configured MCP server is doing, as one row per server: the data
//! behind `/mcp`, `graff mcp status --json` and the desktop app's MCP servers
//! page (and the fullscreen client's `/mcp`).
//!
//! Two views of the same row:
//! - `offline`: config + the catalog cache + stored sign-ins. Spawns nothing
//!   and touches no network, so a settings page can list servers instantly.
//! - `live`: the session's registry, which also knows what is connected,
//!   still connecting, or failed to start (mcp_start.failure).
//! A real handshake is `graff mcp reconnect` (mcp_reconnect.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const mcp_cache = @import("mcp_cache.zig");
const mcp_config = @import("mcp_config.zig");
const mcp_state = @import("mcp_state.zig");

pub const State = enum {
    /// Connected; its tools are live.
    ready,
    /// Known tools; the server starts (or connects) on its first call.
    on_demand,
    /// Starting in the background.
    connecting,
    failed,
    needs_login,
    /// Switched off by the user.
    off,
    /// Off by default until opted in.
    opt_in,
    /// Configured but not started this session (startup consent declined).
    not_started,
    /// Never checked: no cached catalog yet.
    unknown,
};

pub const ToolRow = struct { name: []const u8, description: []const u8 };

pub const Row = struct {
    name: []const u8,
    /// project | global | shipped | imported | session
    source: []const u8,
    /// stdio | http
    transport: []const u8,
    /// Command basename or URL origin; never args, env or headers.
    origin: []const u8,
    enabled: bool,
    state: State,
    @"error": ?[]const u8 = null,
    errorCode: ?[]const u8 = null,
    /// The server's own last stderr line after a failed reconnect, which
    /// usually names the fix ("not licensed", "missing API key").
    detail: ?[]const u8 = null,
    /// none | bearer | oauth | unknown
    auth: []const u8,
    toolCount: usize,
    tools: []const ToolRow,
};

pub fn sourceOf(merged: mcp_config.Merged, name: []const u8) []const u8 {
    if (merged.project.get(name) != null) return "project";
    if (merged.global.get(name) != null) return "global";
    if (merged.shipped_nanocua and std.mem.eql(u8, name, @import("nanocua_default.zig").server_name)) return "shipped";
    if (merged.servers.get(name) != null) return "imported";
    return "session";
}

/// A short, secret-free label for where the server runs.
pub fn originOf(arena: Allocator, cfg: std.json.ObjectMap) []const u8 {
    if (cfg.get("url")) |u| if (u == .string) {
        const sep = std.mem.indexOf(u8, u.string, "://") orelse return "remote";
        var rest = u.string[sep + 3 ..];
        rest = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
        if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..]; // drop user:password
        return std.fmt.allocPrint(arena, "{s}://{s}", .{ u.string[0..sep], rest }) catch "remote";
    };
    const command = if (cfg.get("command")) |c| (if (c == .string) c.string else "") else "";
    const base = std.fs.path.basename(command);
    // A package runner names the package, not itself.
    const runners = [_][]const u8{ "npx", "uvx", "bunx", "pnpx", "pipx" };
    for (runners) |r| if (std.mem.eql(u8, base, r)) {
        if (cfg.get("args")) |args| if (args == .array) for (args.array.items) |arg| {
            if (arg == .string and arg.string.len > 0 and arg.string[0] != '-')
                return std.fmt.allocPrint(arena, "{s} {s}", .{ base, arg.string }) catch base;
        };
    };
    return base;
}

fn transportOf(cfg: std.json.ObjectMap) []const u8 {
    return if (cfg.get("url") != null) "http" else "stdio";
}

fn authOf(io: Io, arena: Allocator, home: []const u8, cfg: std.json.ObjectMap) []const u8 {
    const url = cfg.get("url") orelse return "none";
    if (cfg.get("headers")) |h| if (h == .object) {
        var it = h.object.iterator();
        while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e.key_ptr.*, "authorization")) return "bearer";
    };
    if (url == .string and @import("mcp_oauth.zig").hasCredentials(io, arena, home, url.string)) return "oauth";
    return "unknown";
}

/// The first line of a tool description, capped for a list view.
fn summary(text: []const u8) []const u8 {
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    return std.mem.trim(u8, line[0..@min(line.len, 200)], " \t\r");
}

fn cachedTools(arena: Allocator, tools: std.json.Value) []const ToolRow {
    if (tools != .array) return &.{};
    var out: std.ArrayList(ToolRow) = .empty;
    for (tools.array.items) |t| {
        if (t != .object or !@import("mcp_apps.zig").modelVisible(t)) continue; // as the session lists them
        const name = t.object.get("name") orelse continue;
        if (name != .string) continue;
        const desc = if (t.object.get("description")) |d| (if (d == .string) d.string else "") else "";
        out.append(arena, .{ .name = name.string, .description = summary(desc) }) catch break;
    }
    return out.items;
}

/// Human text for a start failure; `errorCode` keeps the raw name.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "command not found",
        error.AccessDenied, error.PermissionDenied => "command is not executable",
        error.McpClosed, error.EndOfStream, error.BrokenPipe, error.WriteFailed => "the server exited during startup",
        error.McpHandshakeTimeout, error.McpRequestTimedOut, error.ConnectionTimedOut => "the server did not answer in time",
        error.McpAuthenticationRequired => "sign-in required",
        error.ConnectionRefused => "connection refused",
        error.McpHttpStatus => "the server returned an HTTP error",
        error.BadMcpConfig => "invalid config entry",
        error.BadMcpUrl => "invalid URL",
        error.McpIncompatibleProtocolVersion => "unsupported MCP protocol version",
        else => "failed to start",
    };
}

pub fn failedRow(row: *Row, err: anyerror) void {
    row.state = if (err == error.McpAuthenticationRequired) .needs_login else .failed;
    row.@"error" = errorText(err);
    row.errorCode = @errorName(err);
}

fn baseRow(io: Io, arena: Allocator, home: []const u8, merged: mcp_config.Merged, name: []const u8, cfg: std.json.ObjectMap) Row {
    return .{
        .name = name,
        .source = sourceOf(merged, name),
        .transport = transportOf(cfg),
        .origin = originOf(arena, cfg),
        .enabled = true,
        .state = .unknown,
        .auth = authOf(io, arena, home, cfg),
        .toolCount = 0,
        .tools = &.{},
    };
}

fn applySkip(row: *Row, skip: mcp_state.Skip) bool {
    switch (skip) {
        .none => return false,
        .off => row.state = .off,
        .opt_in => row.state = .opt_in,
    }
    row.enabled = false;
    return true;
}

/// Every configured server from config, cache and stored sign-ins alone.
pub fn offline(io: Io, arena: Allocator, home: []const u8, merged: mcp_config.Merged, environ_map: anytype) ![]Row {
    const state = mcp_state.load(io, arena, home);
    var rows: std.ArrayList(Row) = .empty;
    var it = merged.servers.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) continue;
        const cfg = e.value_ptr.*.object;
        var row = baseRow(io, arena, home, merged, e.key_ptr.*, cfg);
        _ = applySkip(&row, mcp_state.skipReason(state, row.name, cfg, environ_map, merged.isGlobalOnly(row.name)));
        const key = mcp_cache.keyFor(arena, cfg);
        if (mcp_cache.lookupAnyAge(io, arena, home, key)) |hit| {
            row.tools = cachedTools(arena, hit.tools);
            row.toolCount = row.tools.len;
            if (row.enabled) row.state = .on_demand;
        }
        // The last start failed (this session or an earlier one) and nothing
        // has started it since: say so, keeping its last-known tools.
        if (row.enabled) if (@import("mcp_failures.zig").get(io, arena, home, key)) |f| {
            row.state = if (std.mem.eql(u8, f.code, "McpAuthenticationRequired")) .needs_login else .failed;
            row.@"error" = f.text;
            row.errorCode = f.code;
            row.detail = f.detail;
        };
        try rows.append(arena, row);
    }
    return rows.items;
}

fn liveTools(arena: Allocator, reg: *const mcp.Registry, index: usize) []const ToolRow {
    var out: std.ArrayList(ToolRow) = .empty;
    for (reg.tools) |t| if (t.server_index == index)
        out.append(arena, .{ .name = t.original_name, .description = summary(t.description) }) catch break;
    return out.items;
}

/// The session's view: configured servers plus any added at runtime.
pub fn live(reg: *mcp.Registry, arena: Allocator, merged: mcp_config.Merged, environ_map: anytype) ![]Row {
    const state = mcp_state.load(reg.io, arena, reg.home);
    var rows: std.ArrayList(Row) = .empty;
    var it = merged.servers.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) continue;
        var row = baseRow(reg.io, arena, reg.home, merged, e.key_ptr.*, e.value_ptr.*.object);
        // A recorded failure means it was tried, whatever its opt-in says.
        if (!liveState(reg, arena, &row)) if (@import("mcp_start.zig").failure(row.name)) |err| failedRow(&row, err) else if (!applySkip(&row, mcp_state.skipReason(state, row.name, e.value_ptr.*.object, environ_map, merged.isGlobalOnly(row.name)))) {
            row.state = .not_started;
        };
        try rows.append(arena, row);
    }
    for (reg.servers, 0..) |server, i| {
        if (merged.servers.get(server.name) != null) continue;
        try rows.append(arena, .{
            .name = server.name,
            .source = "session",
            .transport = if (server.transport == .http) "http" else "stdio",
            .origin = "",
            .enabled = true,
            .state = if (server.transport == .dormant) .on_demand else .ready,
            .auth = "none",
            .toolCount = reg.toolCount(i),
            .tools = liveTools(arena, reg, i),
        });
    }
    return rows.items;
}

/// Connected or still connecting: true when the registry decided the state.
fn liveState(reg: *mcp.Registry, arena: Allocator, row: *Row) bool {
    for (reg.servers, 0..) |server, i| if (std.mem.eql(u8, server.name, row.name)) {
        row.state = if (server.transport == .dormant) .on_demand else .ready;
        row.tools = liveTools(arena, reg, i);
        row.toolCount = row.tools.len;
        return true;
    };
    for (@import("mcp_connect_notice.zig").connecting(reg, arena)) |n| if (std.mem.eql(u8, n, row.name)) {
        row.state = .connecting;
        return true;
    };
    return false;
}

pub fn writeJson(rows: []const Row, w: *Io.Writer) !void {
    try std.json.Stringify.value(.{ .version = 1, .servers = rows }, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

/// One line per state for `/mcp`.
pub fn label(row: Row) []const u8 {
    return switch (row.state) {
        .ready => "connected",
        .on_demand => "starts on first use",
        .connecting => "connecting",
        .failed => "failed",
        .needs_login => "sign-in required",
        .off => "off",
        .opt_in => "off (optional)",
        .not_started => "not started",
        .unknown => "not checked yet",
    };
}

const testing = std.testing;

test "mcp status rows: origin hides args and secrets; failures name the cause" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = struct {
        fn f(al: Allocator, s: []const u8) std.json.ObjectMap {
            return (std.json.parseFromSliceLeaky(std.json.Value, al, s, .{}) catch unreachable).object;
        }
    }.f;
    try testing.expectEqualStrings("npx @scope/server-x", originOf(a, parse(a, "{\"command\":\"npx\",\"args\":[\"-y\",\"@scope/server-x\",\"--token\",\"abc\"]}")));
    try testing.expectEqualStrings("codedb", originOf(a, parse(a, "{\"command\":\"/opt/bin/codedb\",\"args\":[\"mcp\"]}")));
    try testing.expectEqualStrings("https://mcp.example.com", originOf(a, parse(a, "{\"url\":\"https://user:pw@mcp.example.com/mcp?key=s3cret\"}")));

    var row: Row = .{ .name = "x", .source = "global", .transport = "stdio", .origin = "x", .enabled = true, .state = .unknown, .auth = "none", .toolCount = 0, .tools = &.{} };
    failedRow(&row, error.McpAuthenticationRequired);
    try testing.expectEqual(State.needs_login, row.state);
    failedRow(&row, error.FileNotFound);
    try testing.expectEqual(State.failed, row.state);
    try testing.expectEqualStrings("command not found", row.@"error".?);

    var aw: Io.Writer.Allocating = .init(a);
    try writeJson(&.{row}, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"state\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"errorCode\":\"FileNotFound\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"version\":1") != null);
}

test "offline status: cached catalog means on demand; off and optional say so" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "global.json", .data =
        \\{"mcpServers":{"cached":{"command":"srv-a"},"fresh":{"command":"srv-b"},"deepwiki":{"url":"https://mcp.deepwiki.com/mcp"},"muted":{"command":"srv-c"}}}
    });
    var cfg: std.json.ObjectMap = .empty;
    try cfg.put(a, "command", .{ .string = "srv-a" });
    var result: std.json.ObjectMap = .empty;
    var tools = std.json.Array.init(a);
    var tool: std.json.ObjectMap = .empty;
    try tool.put(a, "name", .{ .string = "search" });
    try tool.put(a, "description", .{ .string = "Find things.\nLong detail." });
    try tools.append(.{ .object = tool });
    try result.put(a, "tools", .{ .array = tools });
    mcp_cache.store(io, a, home, mcp_cache.keyFor(a, cfg), .modern, "2026-07-28", .{ .object = result }, 1_000);
    try mcp_state.set(io, a, home, "muted", false);

    const merged = mcp_config.load(io, a, tmp.dir, ".mcp.json", "global.json", "", false);
    const NoEnv = struct {
        pub fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const rows = try offline(io, a, home, merged, NoEnv{});
    var seen: usize = 0;
    for (rows) |r| {
        try testing.expectEqualStrings("global", r.source);
        if (std.mem.eql(u8, r.name, "cached")) {
            try testing.expectEqual(State.on_demand, r.state);
            try testing.expectEqualStrings("Find things.", r.tools[0].description);
        } else if (std.mem.eql(u8, r.name, "fresh")) {
            try testing.expectEqual(State.unknown, r.state);
        } else if (std.mem.eql(u8, r.name, "deepwiki")) {
            try testing.expectEqual(State.opt_in, r.state);
            try testing.expectEqualStrings("unknown", r.auth);
        } else if (std.mem.eql(u8, r.name, "muted")) {
            try testing.expectEqual(State.off, r.state);
            try testing.expect(!r.enabled);
        } else continue;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 4), seen);
}
