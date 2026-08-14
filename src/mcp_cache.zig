//! On-disk `tools/list` cache (MCP 2026-07-28 CacheableResult / rust-sdk
//! ClientCacheConfig). Remote servers are stateless: a fresh process can
//! reuse last session's tool catalog and skip the handshake until TTL.
//!
//! Modern HTTP: no network at all on a hit. Legacy: still `initialize`,
//! but not a second `tools/list`. Nothing secret is stored — names,
//! descriptions, schemas, era, TTL.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp_rpc = @import("mcp_rpc.zig");
const credential_store = @import("credential_store.zig");
const util = @import("util.zig");

const rel_path = ".codegraff/mcp-list-cache.json";
const default_ttl_ms: u64 = 60 * 60 * 1000;
const min_ttl_ms: u64 = 60 * 1000;
const max_ttl_ms: u64 = 24 * 60 * 60 * 1000;

pub const Hit = struct {
    era: mcp_rpc.Era,
    protocol_version: []const u8,
    tools: Value,
};

pub fn keyFor(arena: Allocator, cfg: std.json.ObjectMap) []const u8 {
    if (cfg.get("url")) |u| if (u == .string) {
        return std.fmt.allocPrint(arena, "url:{s}", .{u.string}) catch "";
    };
    const cmd = if (cfg.get("command")) |c| (if (c == .string) c.string else "") else "";
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.print("cmd:{s}", .{cmd}) catch return "";
    if (cfg.get("args")) |args| if (args == .array) {
        for (args.array.items) |arg| if (arg == .string) {
            aw.writer.print(" {s}", .{arg.string}) catch {};
        };
    };
    return aw.writer.buffered();
}

fn cachePath(arena: Allocator, home: []const u8) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}/" ++ rel_path, .{home}) catch "";
}

fn readFile(io: Io, arena: Allocator, home: []const u8) ?[]const u8 {
    const path = cachePath(arena, home);
    if (path.len == 0) return null;
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(2 * 1024 * 1024)) catch null;
}

fn parseRoot(arena: Allocator, data: []const u8) ?std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    return v.object;
}

fn eraFrom(s: []const u8) mcp_rpc.Era {
    if (std.mem.eql(u8, s, "modern")) return .modern;
    if (std.mem.eql(u8, s, "legacy")) return .legacy;
    return .unknown;
}

fn eraName(e: mcp_rpc.Era) []const u8 {
    return switch (e) {
        .modern => "modern",
        .legacy => "legacy",
        .unknown => "unknown",
    };
}

pub const Lookup = struct {
    hit: ?Hit = null,
    era: mcp_rpc.Era = .unknown,
};

/// One disk read: fresh `tools/list` if the TTL still holds, plus the era even
/// when the catalog is stale (so Auto can skip the modern probe).
pub fn lookup(io: Io, arena: Allocator, home: []const u8, key: []const u8, now_ms: i64) Lookup {
    var out: Lookup = .{};
    if (key.len == 0) return out;
    const data = readFile(io, arena, home) orelse return out;
    const root = parseRoot(arena, data) orelse return out;
    const servers = root.get("servers") orelse return out;
    if (servers != .object) return out;
    const entry = servers.object.get(key) orelse return out;
    if (entry != .object) return out;
    const era_s = if (entry.object.get("era")) |v| (if (v == .string) v.string else "") else "";
    out.era = eraFrom(era_s);
    const fetched = if (entry.object.get("fetched_unix_ms")) |v|
        (if (v == .integer) v.integer else 0)
    else
        0;
    const ttl = if (entry.object.get("ttl_ms")) |v|
        (if (v == .integer and v.integer > 0) @as(u64, @intCast(v.integer)) else default_ttl_ms)
    else
        default_ttl_ms;
    if (fetched <= 0 or now_ms < fetched) return out;
    if (@as(u64, @intCast(now_ms - fetched)) > ttl) return out;
    if (out.era == .unknown) return out;
    const ver = if (entry.object.get("protocol_version")) |v| (if (v == .string) v.string else "?") else "?";
    const tools = entry.object.get("tools") orelse return out;
    if (tools != .array) return out;
    out.hit = .{ .era = out.era, .protocol_version = ver, .tools = tools };
    return out;
}

pub fn load(io: Io, arena: Allocator, home: []const u8, key: []const u8, now_ms: i64) ?Hit {
    return lookup(io, arena, home, key, now_ms).hit;
}

/// Era only — ignores tools TTL. A 2025-11-25 URL stays legacy across cache
/// expiry so Auto can skip the modern probe (~0.7s) on the next cold-ish run.
pub fn loadEra(io: Io, arena: Allocator, home: []const u8, key: []const u8) mcp_rpc.Era {
    return lookup(io, arena, home, key, 0).era;
}

/// rust-sdk / 2026-07-28: a cached catalog is enough to advertise tools.
/// HTTP is stateless enough that `call()` can `initialize` on first use.
/// A live stdio child still needs the session handshake now.
pub fn handshakeOnCacheHit(era: mcp_rpc.Era, is_http: bool) bool {
    return era == .legacy and !is_http;
}

pub fn ttlFromResult(result: Value) u64 {
    if (result != .object) return default_ttl_ms;
    const v = result.object.get("ttlMs") orelse result.object.get("ttl_ms") orelse return default_ttl_ms;
    const n: u64 = switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else default_ttl_ms,
        .float => |f| if (f > 0) @intFromFloat(f) else default_ttl_ms,
        else => default_ttl_ms,
    };
    return @min(max_ttl_ms, @max(min_ttl_ms, n));
}

pub fn store(
    io: Io,
    arena: Allocator,
    home: []const u8,
    key: []const u8,
    era: mcp_rpc.Era,
    protocol_version: []const u8,
    result: Value,
    now_ms: i64,
) void {
    if (key.len == 0 or home.len == 0 or era == .unknown) return;
    const tools = if (result == .object) result.object.get("tools") else null;
    if (tools == null or tools.? != .array) return;
    const ttl = ttlFromResult(result);

    var root_map: std.json.ObjectMap = .empty;
    if (readFile(io, arena, home)) |data| {
        if (parseRoot(arena, data)) |existing| root_map = existing;
    }
    var servers_map: std.json.ObjectMap = .empty;
    if (root_map.get("servers")) |s| if (s == .object) {
        servers_map = s.object;
    };

    var entry: std.json.ObjectMap = .empty;
    entry.put(arena, "era", .{ .string = eraName(era) }) catch return;
    entry.put(arena, "protocol_version", .{ .string = protocol_version }) catch return;
    entry.put(arena, "fetched_unix_ms", .{ .integer = now_ms }) catch return;
    entry.put(arena, "ttl_ms", .{ .integer = @intCast(ttl) }) catch return;
    entry.put(arena, "tools", tools.?) catch return;
    servers_map.put(arena, key, .{ .object = entry }) catch return;
    root_map.put(arena, "servers", .{ .object = servers_map }) catch return;

    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(Value{ .object = root_map }) catch return;
    const path = cachePath(arena, home);
    if (path.len == 0) return;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    credential_store.replaceFile(io, Io.Dir.cwd(), path, aw.writer.buffered(), .default_file) catch {};
}

test "keyFor distinguishes url and command+args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var url_cfg: std.json.ObjectMap = .empty;
    try url_cfg.put(a, "url", .{ .string = "https://example.com/mcp" });
    try std.testing.expectEqualStrings("url:https://example.com/mcp", keyFor(a, url_cfg));
    var cmd_cfg: std.json.ObjectMap = .empty;
    try cmd_cfg.put(a, "command", .{ .string = "npx" });
    var args = std.json.Array.init(a);
    try args.append(.{ .string = "-y" });
    try args.append(.{ .string = "foo" });
    try cmd_cfg.put(a, "args", .{ .array = args });
    try std.testing.expectEqualStrings("cmd:npx -y foo", keyFor(a, cmd_cfg));
}

test "ttlFromResult honors CacheableResult ttlMs and clamps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const empty: std.json.ObjectMap = .empty;
    try std.testing.expectEqual(default_ttl_ms, ttlFromResult(.{ .object = empty }));
    var short: std.json.ObjectMap = .empty;
    try short.put(a, "ttlMs", .{ .integer = 10 });
    try std.testing.expectEqual(min_ttl_ms, ttlFromResult(.{ .object = short }));
    var long: std.json.ObjectMap = .empty;
    try long.put(a, "ttl_ms", .{ .integer = 99_000_000_000 });
    try std.testing.expectEqual(max_ttl_ms, ttlFromResult(.{ .object = long }));
}

test "store then load within TTL; miss after expiry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var result: std.json.ObjectMap = .empty;
    var tools = std.json.Array.init(a);
    var tool: std.json.ObjectMap = .empty;
    try tool.put(a, "name", .{ .string = "search" });
    try tool.put(a, "description", .{ .string = "find things" });
    try tools.append(.{ .object = tool });
    try result.put(a, "tools", .{ .array = tools });
    try result.put(a, "ttlMs", .{ .integer = 5_000 });

    const key = "url:https://example.com/mcp";
    store(io, a, home, key, .modern, "2026-07-28", .{ .object = result }, 1_000_000);
    const hit = load(io, a, home, key, 1_000_000 + 2_000) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mcp_rpc.Era.modern, hit.era);
    try std.testing.expectEqualStrings("2026-07-28", hit.protocol_version);
    try std.testing.expectEqual(@as(usize, 1), hit.tools.array.items.len);
    try std.testing.expect(load(io, a, home, key, 1_000_000 + 70_000) == null);
    try std.testing.expect(load(io, a, home, "url:https://other.example/mcp", 1_000_000) == null);
    try std.testing.expectEqual(mcp_rpc.Era.modern, loadEra(io, a, home, key));
    try std.testing.expectEqual(mcp_rpc.Era.unknown, loadEra(io, a, home, "url:https://other.example/mcp"));
}

test "loadEra survives tools TTL so Auto can skip the modern probe" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var result: std.json.ObjectMap = .empty;
    const tools = std.json.Array.init(a);
    try result.put(a, "tools", .{ .array = tools });
    try result.put(a, "ttlMs", .{ .integer = 1_000 });
    const key = "url:https://mcp.deepwiki.com/mcp";
    store(io, a, home, key, .legacy, "2025-11-25", .{ .object = result }, 1_000);
    try std.testing.expect(load(io, a, home, key, 1_000 + 70_000) == null);
    try std.testing.expectEqual(mcp_rpc.Era.legacy, loadEra(io, a, home, key));
}

test "HTTP cache hit skips handshake; stdio legacy still initializes" {
    try std.testing.expect(!handshakeOnCacheHit(.modern, true));
    try std.testing.expect(!handshakeOnCacheHit(.modern, false));
    try std.testing.expect(!handshakeOnCacheHit(.legacy, true));
    try std.testing.expect(handshakeOnCacheHit(.legacy, false));
}
