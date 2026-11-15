//! Trusted, immutable per-agent LSP configuration. No server autodetection,
//! package installation, mutable process registry, or model-authored commands.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
pub const Server = struct {
    id: []const u8,
    command: []const []const u8,
    extensions: []const []const u8,
    language_id: []const u8,
    timeout_ms: u64 = 5000,
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
pub fn parse(a: Allocator, bytes: []const u8) !Registry {
    const root = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
    if (root != .object) return error.InvalidLspConfig;
    const config = root.object.get("lsp") orelse return .{};
    if (config == .bool and !config.bool) return .{};
    if (config != .object) return error.InvalidLspConfig;
    const servers = config.object.get("servers") orelse return error.InvalidLspConfig;
    if (servers != .array or servers.array.items.len > 16) return error.InvalidLspConfig;
    var out: std.ArrayList(Server) = .empty;
    for (servers.array.items) |entry| {
        if (entry != .object) return error.InvalidLspConfig;
        const id = try text(entry.object.get("id") orelse return error.InvalidLspConfig);
        if (!@import("extension_runtime.zig").identifier(id)) return error.InvalidLspConfig;
        for (out.items) |old| if (std.mem.eql(u8, old.id, id)) return error.InvalidLspConfig;
        const timeout = entry.object.get("timeout_ms") orelse Value{ .integer = 5000 };
        if (timeout != .integer or timeout.integer < 100 or timeout.integer > 10_000) return error.InvalidLspConfig;
        try out.append(a, .{
            .id = id,
            .command = try strings(a, entry.object.get("command") orelse return error.InvalidLspConfig, false),
            .extensions = try strings(a, entry.object.get("extensions") orelse return error.InvalidLspConfig, true),
            .language_id = try text(entry.object.get("language_id") orelse return error.InvalidLspConfig),
            .timeout_ms = @intCast(timeout.integer),
        });
    }
    return .{ .servers = try out.toOwnedSlice(a) };
}
/// Called only at trusted session/workspace adoption, before catalog rendering.
/// Workers inherit these commands; their own checkout cannot replace them.
pub fn load(io: std.Io, a: Allocator) Registry {
    if (@import("no_local_tools.zig").enabled) return .{};
    const policy = @import("harness_policy.zig");
    if (!policy.noSymlinkEscape(io, policy.settings_path, null)) return .{ .problem = "LSP settings escape workspace" };
    const data = std.Io.Dir.cwd().readFileAlloc(io, policy.settings_path, a, .limited(1024 * 1024)) catch |err| return switch (err) {
        error.FileNotFound => .{},
        else => .{ .problem = "LSP settings unavailable" },
    };
    return parse(a, data) catch .{ .problem = "invalid lsp configuration in .harness/settings.json" };
}
pub fn clone(a: Allocator, source: Registry) !Registry {
    const out = try a.alloc(Server, source.servers.len);
    for (source.servers, out) |server, *dest| {
        const command = try a.alloc([]const u8, server.command.len);
        for (server.command, command) |s, *d| d.* = try a.dupe(u8, s);
        const extensions = try a.alloc([]const u8, server.extensions.len);
        for (server.extensions, extensions) |s, *d| d.* = try a.dupe(u8, s);
        dest.* = .{ .id = try a.dupe(u8, server.id), .command = command, .extensions = extensions, .language_id = try a.dupe(u8, server.language_id), .timeout_ms = server.timeout_ms };
    }
    return .{ .servers = out, .problem = if (source.problem) |p| try a.dupe(u8, p) else null };
}
