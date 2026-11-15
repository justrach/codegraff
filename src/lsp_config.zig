//! Trusted, immutable per-agent LSP configuration. Explicit project config in
//! `.harness/settings.json` merges ahead of user-level defaults in
//! `~/.graff/lsp/settings.json` (`GRAFF_LSP_CONFIG`). No model-authored commands.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
pub const global_rel_path = ".graff/lsp/settings.json";
pub const path_env = "GRAFF_LSP_CONFIG";
const max_servers: usize = 16;
pub var root_enabled: bool = false;
pub const Server = struct {
    id: []const u8,
    command: []const []const u8,
    extensions: []const []const u8,
    language_id: []const u8,
    timeout_ms: u64 = 5000,
    warm_ttl_ms: u64 = 0,
};
pub const Registry = struct {
    servers: []const Server = &.{},
    problem: ?[]const u8 = null,
    pub fn enabled(self: Registry) bool {
        return self.servers.len > 0;
    }
    pub fn select(self: Registry, path: []const u8, id: ?[]const u8) ?Server {
        for (self.servers) |server| {
            if (id) |name| if (!std.mem.eql(u8, name, server.id)) continue;
            for (server.extensions) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return server;
        }
        return null;
    }
};
const Parsed = struct {
    explicit_off: bool = false,
    servers: []const Server = &.{},
};
const ReadResult = union(enum) {
    parsed: Parsed,
    problem: []const u8,
};
fn text(v: Value) ![]const u8 {
    if (v != .string or v.string.len == 0 or v.string.len > 4096 or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidLspConfig;
    return v.string;
}
fn strings(a: Allocator, v: Value, extensions: bool) ![]const []const u8 {
    if (v != .array or v.array.items.len == 0 or v.array.items.len > 32) return error.InvalidLspConfig;
    const out = try a.alloc([]const u8, v.array.items.len);
    for (v.array.items, out) |item, *dest| {
        dest.* = try text(item);
        if (extensions and (dest.*[0] != '.' or std.mem.indexOfAny(u8, dest.*, "/\\") != null)) return error.InvalidLspConfig;
    }
    return out;
}
fn parseDetailed(a: Allocator, bytes: []const u8) !Parsed {
    const root = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
    if (root != .object) return error.InvalidLspConfig;
    const config = root.object.get("lsp") orelse return .{};
    if (config == .bool and !config.bool) return .{ .explicit_off = true };
    if (config != .object) return error.InvalidLspConfig;
    const servers = config.object.get("servers") orelse return error.InvalidLspConfig;
    if (servers != .array or servers.array.items.len > max_servers) return error.InvalidLspConfig;
    var out: std.ArrayList(Server) = .empty;
    for (servers.array.items) |entry| {
        if (entry != .object) return error.InvalidLspConfig;
        const id = try text(entry.object.get("id") orelse return error.InvalidLspConfig);
        if (!@import("extension_runtime.zig").identifier(id)) return error.InvalidLspConfig;
        for (out.items) |old| if (std.mem.eql(u8, old.id, id)) return error.InvalidLspConfig;
        const timeout = entry.object.get("timeout_ms") orelse Value{ .integer = 5000 };
        if (timeout != .integer or timeout.integer < 100 or timeout.integer > 30_000) return error.InvalidLspConfig;
        const warm = entry.object.get("warm_ttl_ms") orelse Value{ .integer = 0 };
        if (warm != .integer or (warm.integer != 0 and (warm.integer < 100 or warm.integer > 300_000))) return error.InvalidLspConfig;
        try out.append(a, .{
            .id = id,
            .command = try strings(a, entry.object.get("command") orelse return error.InvalidLspConfig, false),
            .extensions = try strings(a, entry.object.get("extensions") orelse return error.InvalidLspConfig, true),
            .language_id = try text(entry.object.get("language_id") orelse return error.InvalidLspConfig),
            .timeout_ms = @intCast(timeout.integer),
            .warm_ttl_ms = @intCast(warm.integer),
        });
    }
    return .{ .servers = try out.toOwnedSlice(a) };
}
pub fn parse(a: Allocator, bytes: []const u8) !Registry {
    const parsed = try parseDetailed(a, bytes);
    return .{ .servers = parsed.servers };
}
fn readDirFile(io: std.Io, a: Allocator, dir: std.Io.Dir, rel_path: []const u8, base: ?[]const u8, escape_msg: []const u8, unavail_msg: []const u8, invalid_msg: []const u8) ReadResult {
    const policy = @import("harness_policy.zig");
    if (!policy.noSymlinkEscape(io, rel_path, base)) return .{ .problem = escape_msg };
    const data = dir.readFileAlloc(io, rel_path, a, .limited(1024 * 1024)) catch |err| return switch (err) {
        error.FileNotFound => .{ .parsed = .{} },
        else => .{ .problem = unavail_msg },
    };
    return .{ .parsed = parseDetailed(a, data) catch return .{ .problem = invalid_msg } };
}
fn readGlobal(io: std.Io, a: Allocator, cwd: std.Io.Dir, cwd_path: ?[]const u8, home: ?[]const u8, env_override: ?[]const u8) ReadResult {
    if (env_override) |override| if (override.len > 0) {
        if (!std.fs.path.isAbsolute(override)) {
            return readDirFile(io, a, cwd, override, cwd_path, "global LSP settings escape workspace", "global LSP settings unavailable", "invalid lsp configuration in GRAFF_LSP_CONFIG");
        }
        const dir_path = std.fs.path.dirname(override) orelse "/";
        const base_name = std.fs.path.basename(override);
        var gdir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err| return switch (err) {
            error.FileNotFound, error.NotDir => .{ .parsed = .{} },
            else => .{ .problem = "global LSP settings unavailable" },
        };
        defer gdir.close(io);
        return readDirFile(io, a, gdir, base_name, dir_path, "global LSP settings escape config directory", "global LSP settings unavailable", "invalid lsp configuration in GRAFF_LSP_CONFIG");
    };
    const h = home orelse return .{ .parsed = .{} };
    if (h.len == 0) return .{ .parsed = .{} };
    var hdir = std.Io.Dir.cwd().openDir(io, h, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .{ .parsed = .{} },
        else => .{ .problem = "global LSP settings unavailable" },
    };
    defer hdir.close(io);
    return readDirFile(io, a, hdir, global_rel_path, h, "global LSP settings escape home", "global LSP settings unavailable", "invalid lsp configuration in ~/.graff/lsp/settings.json");
}
pub fn loadFrom(io: std.Io, a: Allocator, cwd: std.Io.Dir, cwd_path: ?[]const u8, home: ?[]const u8, env_override: ?[]const u8) Registry {
    if (@import("no_local_tools.zig").enabled) return .{};
    const policy = @import("harness_policy.zig");
    const proj = switch (readDirFile(io, a, cwd, policy.settings_path, cwd_path, "LSP settings escape workspace", "LSP settings unavailable", "invalid lsp configuration in .harness/settings.json")) {
        .problem => |msg| return .{ .problem = msg },
        .parsed => |p| p,
    };
    if (proj.explicit_off) return .{};
    const glob = switch (readGlobal(io, a, cwd, cwd_path, home, env_override)) {
        .problem => |msg| return .{ .problem = msg },
        .parsed => |g| g,
    };
    if (glob.explicit_off or glob.servers.len == 0) return .{ .servers = proj.servers };
    if (proj.servers.len == 0) return .{ .servers = glob.servers };
    var out: std.ArrayList(Server) = .empty;
    out.appendSlice(a, proj.servers) catch return .{ .servers = proj.servers };
    for (glob.servers) |gs| {
        if (out.items.len >= max_servers) break;
        const dup = for (proj.servers) |ps| {
            if (std.mem.eql(u8, ps.id, gs.id)) break true;
        } else false;
        if (!dup) out.append(a, gs) catch return .{ .servers = proj.servers };
    }
    return .{ .servers = out.toOwnedSlice(a) catch proj.servers };
}
/// Called only at trusted session/workspace adoption, before catalog rendering.
/// Workers inherit these commands; their own checkout cannot replace them.
pub fn load(io: std.Io, a: Allocator) Registry {
    const env = @import("tool_env.zig").get();
    const home = if (env) |m| (m.get("HOME") orelse m.get("USERPROFILE")) else null;
    const override = if (env) |m| m.get(path_env) else null;
    return loadFrom(io, a, std.Io.Dir.cwd(), null, home, override);
}
pub fn clone(a: Allocator, source: Registry) !Registry {
    const out = try a.alloc(Server, source.servers.len);
    for (source.servers, out) |server, *dest| {
        const command = try a.alloc([]const u8, server.command.len);
        for (server.command, command) |s, *d| d.* = try a.dupe(u8, s);
        const extensions = try a.alloc([]const u8, server.extensions.len);
        for (server.extensions, extensions) |s, *d| d.* = try a.dupe(u8, s);
        dest.* = .{ .id = try a.dupe(u8, server.id), .command = command, .extensions = extensions, .language_id = try a.dupe(u8, server.language_id), .timeout_ms = server.timeout_ms, .warm_ttl_ms = server.warm_ttl_ms };
    }
    return .{ .servers = out, .problem = if (source.problem) |p| try a.dupe(u8, p) else null };
}
