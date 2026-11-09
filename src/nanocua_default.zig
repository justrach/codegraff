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

pub const missing_agent_hint = "macOS computer use (MCP server 'nanocua') is not installed: ~/Applications/nanocua.app is missing. Run `graff computer install` (or `graff update`) to install it, then reload its tool schemas.";
pub const disabled_agent_hint = "macOS computer use (MCP server 'nanocua') is switched off. Run `graff mcp enable nanocua` and `/mcp reconnect nanocua`, then reload its tool schemas.";
pub const unconnected_agent_hint = "macOS computer use (`nanocua.app`) is installed on disk, but MCP server 'nanocua' is not connected in this session yet. Run `/mcp reconnect nanocua`, then reload its tool schemas.";
pub const custom_unconnected_hint = "MCP server 'nanocua' is configured but not connected in this session. Inspect `/mcp` (`/mcp trust` or `/mcp reconnect nanocua`), then reload its tool schemas.";
pub const missing_status_line = "  nanocua  not installed — run `graff computer install` (or `graff update`) to install ~/Applications/nanocua.app\n";

fn isComputerAlias(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, server_name) or
        std.ascii.eqlIgnoreCase(word, "computer") or
        std.ascii.eqlIgnoreCase(word, "computer-use") or
        std.ascii.eqlIgnoreCase(word, "computer_use");
}

fn startsWithIgnoreCase(hay: []const u8, prefix: []const u8) bool {
    return hay.len >= prefix.len and std.ascii.eqlIgnoreCase(hay[0..prefix.len], prefix);
}

pub fn isComputerToolName(name: []const u8) bool {
    return isComputerAlias(name) or
        startsWithIgnoreCase(name, "mcp__nanocua__") or
        startsWithIgnoreCase(name, "mcp__computer__");
}

/// True when a `load_tool_schemas` / `mcp_select_tool` / `mcp_search_tools`
/// call asks for `nanocua` or macOS computer use and no live tool matched.
pub fn requestsNanocua(input: std.json.Value, has_live_query_match: bool) bool {
    if (input != .object) return false;
    if (input.object.get("server")) |sv| if (sv == .string and isComputerAlias(sv.string)) return true;
    if (input.object.get("tools")) |list| if (list == .array) {
        for (list.array.items) |item| if (item == .string and isComputerToolName(item.string)) return true;
    };
    if (!has_live_query_match) {
        if (input.object.get("query")) |q| if (q == .string) {
            var tok = std.mem.tokenizeAny(u8, q.string, " \t,;:/_-.");
            while (tok.next()) |w| {
                if (std.ascii.eqlIgnoreCase(w, server_name) or std.ascii.eqlIgnoreCase(w, "computer")) return true;
            }
        };
    }
    return false;
}

fn isWholesaleOff(merged: @import("mcp_config.zig").Merged, global_is_override: bool) bool {
    return global_is_override and merged.found and !merged.invalid_global and merged.global.count() == 0 and merged.global_off.count() == 0;
}

fn isExecutableFile(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (builtin.os.tag == .windows) return stat.kind == .file;
    return stat.permissions.toMode() & 0o111 != 0;
}

/// Lock-free explanation for why `nanocua` is absent from the active catalog.
pub fn unavailableMessage(
    io: Io,
    arena: Allocator,
    home: []const u8,
    global_config_path: ?[]const u8,
    global_is_override: bool,
    is_macos: bool,
) ?[]const u8 {
    if (!is_macos or home.len == 0) return null;
    const mcp_config = @import("mcp_config.zig");
    const merged = mcp_config.load(io, arena, Io.Dir.cwd(), @import("main.zig").mcp_config_path, global_config_path, home, global_is_override);
    if (isWholesaleOff(merged, global_is_override)) return null;
    if (merged.disabled.get(server_name) != null or @import("mcp_state.zig").load(io, arena, home).isDisabled(server_name))
        return disabled_agent_hint;
    if (merged.servers.get(server_name) != null)
        return if (merged.shipped_nanocua or find(io, arena, home) != null) unconnected_agent_hint else custom_unconnected_hint;
    if (find(io, arena, home) != null) return unconnected_agent_hint;
    return missing_agent_hint;
}

/// Called from `unavailableLoad` with `reg.mutex` unlocked: hot-connects shipped
/// `nanocua` if it was installed mid-session, else returns the unavailable hint.
pub fn resolveUnavailable(reg: *@import("mcp.zig").Registry, arena: Allocator, is_macos: bool) ?[]const u8 {
    if (!is_macos or reg.home.len == 0) return null;
    if (ismacos_connect: {
        if (!is_macos) break :ismacos_connect false;
        break :ismacos_connect connectShipped(reg, arena);
    }) return null;
    return unavailableMessage(reg.io, arena, reg.home, reg.global_config_path, reg.global_is_override, is_macos);
}

/// Hot-connect shipped `nanocua` into `reg` when `nanocua.app` was installed
/// mid-session (`/computer install`, `/update install`, or `graff computer install`).
pub fn connectShipped(reg: *@import("mcp.zig").Registry, arena: Allocator) bool {
    if (builtin.os.tag != .macos or reg.home.len == 0) return false;
    {
        reg.mutex.lockUncancelable(reg.io);
        defer reg.mutex.unlock(reg.io);
        for (reg.tools) |t| if (std.mem.eql(u8, t.serverName(), server_name)) return false;
    }
    const mcp_config = @import("mcp_config.zig");
    const merged = mcp_config.load(reg.io, arena, Io.Dir.cwd(), @import("main.zig").mcp_config_path, reg.global_config_path, reg.home, reg.global_is_override);
    if (!merged.shipped_nanocua or isWholesaleOff(merged, reg.global_is_override)) return false;
    if (merged.disabled.get(server_name) != null or @import("mcp_state.zig").load(reg.io, arena, reg.home).isDisabled(server_name)) return false;
    const cfg_val = merged.servers.get(server_name) orelse return false;
    if (cfg_val != .object) return false;
    const cmd_val = cfg_val.object.get("command") orelse return false;
    if (cmd_val != .string or !isExecutableFile(reg.io, cmd_val.string)) return false;
    return switch (@import("mcp_reconnect.zig").live(reg, merged, server_name)) {
        .connected, .reconnected => true,
        else => false,
    };
}

/// Human-facing note for `graff mcp status` (non-`--json`) and `/mcp` on macOS
/// when `nanocua.app` is missing and not overridden or disabled.
pub fn missingStatusNote(
    io: Io,
    arena: Allocator,
    home: []const u8,
    merged: @import("mcp_config.zig").Merged,
    global_is_override: bool,
    is_macos: bool,
) ?[]const u8 {
    if (!is_macos or home.len == 0) return null;
    if (isWholesaleOff(merged, global_is_override)) return null;
    if (merged.servers.get(server_name) != null or merged.disabled.get(server_name) != null) return null;
    if (@import("mcp_state.zig").load(io, arena, home).isDisabled(server_name)) return null;
    if (find(io, arena, home) != null) return null;
    return missing_status_line;
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

test "missing nanocua.app on macOS explains how to install it on load, search, call, and status without non-macOS noise (#1819)" {
    const mcp = @import("mcp.zig");
    const mcp_call = @import("mcp_call.zig");
    const mcp_config = @import("mcp_config.zig");
    const mcp_select = @import("mcp_select.zig");
    const mcp_status_cli = @import("mcp_status_cli.zig");
    const mcp_listing = @import("mcp_listing.zig");
    const gate = @import("mcp_schema_gate.zig");
    gate.reset();
    defer gate.reset();
    const saved_policy = gate.g_policy;
    defer gate.g_policy = saved_policy;
    gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };

    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const home = try tmpHome(io, a, &tmp, false);
    const empty_global = try std.fmt.allocPrint(a, "{s}/nonexistent-global.json", .{home});

    var reg = mcp.Registry.empty(gpa, io);
    defer reg.deinit();
    reg.home = home;
    reg.global_config_path = empty_global;

    // 1. Query/server/tool matching rules: exact computer/nanocua tokens match, "compute" and empty args do not.
    for ([_][]const u8{
        "{\"server\":\"nanocua\"}",
        "{\"server\":\"computer\"}",
        "{\"tools\":[\"mcp__nanocua__screenshot\"]}",
        "{\"query\":\"nanocua\"}",
        "{\"query\":\"computer use\"}",
    }) |raw| {
        const val = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
        const msg = mcp_call.unavailableLoadForPlatform(&reg, a, val, true) orelse return error.TestExpectedHint;
        try testing.expect(std.mem.indexOf(u8, msg, "graff computer install") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "graff update") != null);
        // Non-macOS never emits the macOS nanocua hint.
        try testing.expect(mcp_call.unavailableLoadForPlatform(&reg, a, val, false) == null);
    }
    for ([_][]const u8{
        "{}",
        "{\"query\":\"compute hash\"}",
        "{\"server\":\"linear\"}",
    }) |raw| {
        const val = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
        try testing.expect(mcp_call.unavailableLoadForPlatform(&reg, a, val, true) == null);
    }

    // 2. A live deferred tool matching "computer" wins over the missing-nanocua hint.
    reg.tools = try reg.arena().dupe(mcp.Tool, &.{.{
        .server_name = "custom",
        .server_index = 0,
        .original_name = "act",
        .qualified_name = "mcp__custom__act",
        .description = "custom computer automation tool",
        .input_schema = .{ .object = .empty },
    }});
    const q_comp = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"query\":\"computer\"}", .{});
    try testing.expect(mcp_call.unavailableLoadForPlatform(&reg, a, q_comp, true) == null);
    reg.tools = &.{};

    // 3. Switched-off nanocua reports `graff mcp enable nanocua`.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = empty_global, .data = "{\"mcpServers\":{},\"disabledMcpServers\":{\"nanocua\":{}}}" });
    const off_msg = mcp_call.unavailableLoadForPlatform(&reg, a, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"server\":\"nanocua\"}", .{}), true).?;
    try testing.expect(std.mem.indexOf(u8, off_msg, "graff mcp enable nanocua") != null);
    try Io.Dir.cwd().deleteFile(io, empty_global);

    // 4. mcp_search_tools and direct mcp__nanocua__* call on macOS surface the install hint.
    if (builtin.os.tag == .macos) {
        const FakeAgent = struct {
            arena: Allocator,
            gpa: Allocator,
            io: Io,
            agent_cwd: ?[]const u8 = null,
            sub: bool = false,
            registry: ?*mcp.Registry,
        };
        var fake: FakeAgent = .{ .arena = a, .gpa = gpa, .io = io, .registry = &reg };
        const sr = mcp_select.handleSearch(&fake, q_comp);
        try testing.expect(sr.is_error);
        try testing.expect(std.mem.indexOf(u8, sr.text, "graff computer install") != null);

        const cr = try reg.call(gpa, "mcp__nanocua__screenshot", .{ .object = .empty });
        defer gpa.free(cr.text);
        try testing.expect(cr.is_error);
        try testing.expect(std.mem.indexOf(u8, cr.text, "graff computer install") != null);
    }

    // 5. `graff mcp status --json` stays strictly configured servers only, while human status & `/mcp` note missing nanocua on macOS.
    const NoEnv = struct {
        pub fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const merged = mcp_config.load(io, a, tmp.dir, ".nonexistent-mcp.json", empty_global, home, false);
    var aw: Io.Writer.Allocating = .init(a);
    try mcp_status_cli.run(io, gpa, a, home, merged, &.{ "status", "--json" }, &aw.writer, NoEnv{});
    const status_json = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{});
    try testing.expectEqual(@as(usize, 0), status_json.object.get("servers").?.array.items.len);

    if (builtin.os.tag == .macos) {
        aw.clearRetainingCapacity();
        try mcp_status_cli.run(io, gpa, a, home, merged, &.{"status"}, &aw.writer, NoEnv{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "graff computer install") != null);

        aw.clearRetainingCapacity();
        try mcp_listing.notConnected(&reg, a, &aw.writer, ".nonexistent-mcp.json");
        try testing.expect(std.mem.indexOf(u8, aw.written(), "graff computer install") != null);

        aw.clearRetainingCapacity();
        try testing.expect(!try mcp_listing.reconnect(&reg, a, &aw.writer, ".nonexistent-mcp.json", "nanocua"));
        try testing.expect(std.mem.indexOf(u8, aw.written(), "graff computer install") != null);
    }
}

test "load_tool_schemas surfaces missing nanocua.app on macOS and hot-connects it once installed mid-session (#1819)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const mcp = @import("mcp.zig");
    const mcp_select = @import("mcp_select.zig");
    const gate = @import("mcp_schema_gate.zig");
    const Kind = @import("provider.zig").Provider.Kind;
    gate.reset();
    defer gate.reset();
    const saved_policy = gate.g_policy;
    defer gate.g_policy = saved_policy;
    gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };

    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const home = try tmpHome(io, a, &tmp, false);

    var reg = mcp.Registry.empty(gpa, io);
    defer reg.deinit();
    reg.home = home;
    reg.global_config_path = try std.fmt.allocPrint(a, "{s}/nonexistent-global.json", .{home});
    reg.stdio_probe = false;
    reg.lazy_stdio = false;

    const FakeAgent = struct {
        arena: Allocator,
        gpa: Allocator,
        io: Io,
        agent_cwd: ?[]const u8 = null,
        sub: bool = false,
        registry: ?*mcp.Registry,
        provider: struct { kind: Kind } = .{ .kind = .anthropic },
        rebuilds: usize = 0,
        pub fn invalidateRootTools(_: *@This()) void {}
        pub fn ensureRootTools(self: *@This(), _: Kind) !void {
            self.rebuilds += 1;
        }
    };
    var agent: FakeAgent = .{ .arena = a, .gpa = gpa, .io = io, .registry = &reg };

    // Before install: `load_tool_schemas` with `query: "computer use"` names `graff computer install`.
    const before_in = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"query\":\"computer use\"}", .{});
    const before = mcp_select.loadBoth(&agent, .{ .id = "c1", .name = gate.tool_name, .input = before_in });
    try testing.expect(std.mem.indexOf(u8, before.text, "graff computer install") != null);

    // Mid-session install of nanocua.app: next `load_tool_schemas` hot-connects and loads its schema.
    const app_exe = try std.fmt.allocPrint(a, "{s}/Applications/{s}", .{ home, executable });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(app_exe).?);
    const script =
        \\#!/bin/sh
        \\while read -r l; do
        \\  id=$(printf '%s' "$l" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
        \\  [ -z "$id" ] && continue
        \\  case "$l" in
        \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"nanocua","version":"1"}}}\n' "$id" ;;
        \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"get_ui_tree","description":"macOS computer UI tree","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
        \\    *) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"ok"}]}}\n' "$id" ;;
        \\  esac
        \\done
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = app_exe, .data = script, .flags = .{ .permissions = .fromMode(0o755) } });

    const after_in = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"server\":\"nanocua\"}", .{});
    const after = mcp_select.loadBoth(&agent, .{ .id = "c2", .name = gate.tool_name, .input = after_in });
    try testing.expect(!after.is_error);
    try testing.expect(std.mem.indexOf(u8, after.text, "mcp__nanocua__get_ui_tree") != null);
    try testing.expect(gate.isLoaded("mcp__nanocua__get_ui_tree"));
    try testing.expect(agent.rebuilds >= 1);
}
