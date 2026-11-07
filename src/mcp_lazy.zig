//! Local (stdio) MCP servers start on first use.
//!
//! Every configured stdio server used to be spawned at session start, so a
//! chat with twenty servers ran twenty processes whether or not it ever called
//! one. When the tool catalog for a server is already cached (mcp_cache.zig,
//! keyed by command + args), the session advertises those tools from the cache
//! and keeps only the launch config: the process is spawned, and handshaken
//! for a legacy server, on the first `tools/call` that needs it. Once awake it
//! re-lists its tools to refresh the cache for later sessions.
//!
//! Processes are never shared between sessions: a stdio server holds state for
//! the agent using it (a browser, a working directory, credentials). A server
//! with no cached catalog yet starts at once so its tools can be learned; an
//! entry can opt out with `"startup": "eager"`, and `GRAFF_MCP_EAGER=1` turns
//! lazy starts off for the whole process.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Allocator = std.mem.Allocator;
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_cache = @import("mcp_cache.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const util = @import("util.zig");

/// How a stdio entry is launched. `env` owns gpa copies of its strings: the
/// caller deinits it once the child has been spawned.
pub const Spec = struct {
    argv: []const []const u8,
    env: ?*std.process.Environ.Map = null,
    cwd: ?[]const u8 = null,
};

pub fn stdioSpec(io: Io, gpa: Allocator, a: Allocator, cfg: ObjectMap) !Spec {
    const command_v = cfg.get("command") orelse return error.BadMcpConfig;
    if (command_v != .string) return error.BadMcpConfig;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, command_v.string);
    if (cfg.get("args")) |args| {
        if (args != .array) return error.BadMcpConfig;
        for (args.array.items) |arg| {
            if (arg != .string) return error.BadMcpConfig;
            try argv.append(a, arg.string);
        }
    }
    var spec: Spec = .{ .argv = argv.items };
    // `"shared": true`: run through the per-machine broker (mcp_share.zig).
    const share = @import("mcp_share.zig");
    if (share.wantsShared(cfg)) {
        const key = share.keyFor(cfg);
        spec.argv = try share.attachArgv(a, try std.process.executablePathAlloc(io, a), try a.dupe(u8, &key), argv.items);
    }
    if (cfg.get("cwd")) |cwd| {
        if (cwd != .string or cwd.string.len == 0) return error.BadMcpConfig;
        spec.cwd = cwd.string;
    }
    // Optional per-server env overlaid on the parent environment. A spawn's
    // `environ_map` REPLACES the child's environment, so the overlay starts
    // from a copy of graff's own: an entry that sets one token must not lose
    // PATH and HOME (an `npx` server then cannot find `node` and exits).
    if (cfg.get("env")) |env| {
        if (env != .object) return error.BadMcpConfig;
        const m = try a.create(std.process.Environ.Map);
        m.* = if (parent_env) |p| try p.clone(gpa) else std.process.Environ.Map.init(gpa);
        errdefer m.deinit();
        var it = env.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.BadMcpConfig;
            try m.put(entry.key_ptr.*, entry.value_ptr.*.string);
        }
        spec.env = m;
    }
    return spec;
}

/// graff's own environment, the base every per-server `env` overlays. Set
/// where MCP is set up (`remember`); null in unit tests.
pub var parent_env: ?*const std.process.Environ.Map = null;

pub fn remember(environ_map: anytype) void {
    const T = @TypeOf(environ_map);
    if (T == *std.process.Environ.Map or T == *const std.process.Environ.Map) parent_env = environ_map;
}

/// A stdio entry that did not ask to start with the session.
pub fn wantsLazy(cfg: ObjectMap) bool {
    if (cfg.get("command") == null) return false;
    if (cfg.get("startup")) |s| if (s == .string and std.ascii.eqlIgnoreCase(s.string, "eager")) return false;
    return true;
}

fn cloneValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(a);
            for (arr.items) |item| try out.append(try cloneValue(a, item));
            break :blk .{ .array = out };
        },
        .object => |o| .{ .object = try cloneMap(a, o) },
        else => v,
    };
}

/// A deep copy: the config an ACP client sent lives in its request's arena.
pub fn cloneMap(a: Allocator, m: ObjectMap) Allocator.Error!ObjectMap {
    var out: ObjectMap = .empty;
    var it = m.iterator();
    while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
    return out;
}

/// A dormant server built from a cached catalog, or null when this entry must
/// start now (not stdio, opted out, or never listed before).
pub fn dormantFromCache(io: Io, a: Allocator, home: []const u8, name: []const u8, cfg: ObjectMap) !?struct { server: *mcp_rpc.Server, tools: Value } {
    if (!wantsLazy(cfg)) return null;
    const hit = mcp_cache.lookupAnyAge(io, a, home, mcp_cache.keyFor(a, cfg)) orelse return null;
    const server = try a.create(mcp_rpc.Server);
    server.* = .{
        .name = name,
        .transport = .{ .dormant = .{ .cfg = try cloneMap(a, cfg) } },
        .era = hit.era,
        .protocol_version = try a.dupe(u8, hit.protocol_version),
        .initialized = false,
    };
    return .{ .server = server, .tools = hit.tools };
}

/// Spawn and handshake a dormant server before its first request. On failure
/// it stays dormant, so a later call tries again.
pub fn wake(reg: anytype, server: *mcp_rpc.Server) !void {
    const cfg = server.transport.dormant.cfg;
    wakeInner(reg, server) catch |err| {
        @import("mcp_failures.zig").recordErr(reg.io, reg.gpa, reg.home, cfg, err, null); // `graff mcp status` says why
        return err;
    };
}

fn wakeInner(reg: anytype, server: *mcp_rpc.Server) !void {
    const dormant = server.transport.dormant;
    const cfg = dormant.cfg;
    const a = reg.arena();
    const spec = try stdioSpec(reg.io, reg.gpa, a, cfg);
    defer if (spec.env) |m| m.deinit();
    server.transport = try reg.spawnStdio(a, spec.argv, spec.env, spec.cwd);
    server.transport.stdio.relaunch = dormant;
    errdefer {
        mcp_stdio.stopChild(reg.io, &server.transport.stdio.child);
        server.transport = .{ .dormant = dormant };
        server.initialized = false;
    }
    // Same rule as a cache hit at connect: legacy needs `initialize` on the
    // live child; a modern server takes any request first.
    if (mcp_cache.handshakeOnCacheHit(server.era, false)) {
        try mcp_rpc.initializeServer(server, a, a, reg.io);
    } else {
        server.initialized = server.era == .modern;
    }
    mcp_rpc.bindNotes(server);
    @import("mcp_pages.zig").listen(server, a);
    if (reg.show_diagnostics) std.debug.print("  [mcp:{s}] started on first use\n", .{server.name});
    @import("mcp_failures.zig").clearCfg(reg.io, reg.gpa, reg.home, cfg);
    refreshCache(reg, server, cfg);
}

/// Re-list the tools of a server that just woke and store them, so the next
/// session advertises its current catalog. The live session keeps the list
/// it started with. Best effort: a failure costs nothing but freshness.
fn refreshCache(reg: anytype, server: *mcp_rpc.Server, cfg: ObjectMap) void {
    if (!server.initialized or reg.home.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(reg.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const listed = mcp_rpc.request(server, a, "{}", "tools/list", null) catch return;
    const result = if (listed == .object) listed.object.get("result") orelse return else return;
    mcp_cache.store(reg.io, a, reg.home, mcp_cache.keyFor(a, cfg), server.era, server.protocol_version, result, util.unixMs(reg.io));
}

test "wantsLazy: stdio entries, unless they ask to start with the session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(al: Allocator, s: []const u8) ObjectMap {
            return (std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable).object;
        }
    }.f;
    try std.testing.expect(wantsLazy(parse(a, "{\"command\":\"npx\",\"args\":[\"-y\",\"x\"]}")));
    try std.testing.expect(!wantsLazy(parse(a, "{\"command\":\"npx\",\"startup\":\"eager\"}")));
    try std.testing.expect(!wantsLazy(parse(a, "{\"url\":\"https://example.com/mcp\"}")));
}

test "cloneMap survives the source arena" {
    var src = std.heap.ArenaAllocator.init(std.testing.allocator);
    const original = (try std.json.parseFromSliceLeaky(Value, src.allocator(),
        \\{"command":"node","args":["server.js","--port","9"],"env":{"TOKEN":"t"},"cwd":"/tmp"}
    , .{ .allocate = .alloc_always })).object;
    var dst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer dst.deinit();
    const copy = try cloneMap(dst.allocator(), original);
    src.deinit(); // the request arena an ACP client's config came from is gone
    const spec = try stdioSpec(std.testing.io, std.testing.allocator, dst.allocator(), copy);
    defer if (spec.env) |m| m.deinit();
    try std.testing.expectEqualStrings("node", spec.argv[0]);
    try std.testing.expectEqualStrings("9", spec.argv[3]);
    try std.testing.expectEqualStrings("/tmp", spec.cwd.?);
    try std.testing.expectEqualStrings("t", spec.env.?.get("TOKEN").?);
}

test "a server's env overlays graff's own environment instead of replacing it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("TOKEN", "from-parent");
    const saved = parent_env;
    defer parent_env = saved;
    remember(&parent);
    const cfg = (try std.json.parseFromSliceLeaky(Value, a, "{\"command\":\"npx\",\"env\":{\"TOKEN\":\"from-entry\"}}", .{})).object;
    const spec = try stdioSpec(std.testing.io, std.testing.allocator, a, cfg);
    const env = spec.env.?;
    defer env.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("from-entry", env.get("TOKEN").?);
}
