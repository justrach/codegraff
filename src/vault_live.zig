//! graff's own token refresh when vault sync is on (harness ADR 0005,
//! decision 7). Sync is on when HARNESS_BEARER is set and this device has a
//! vault identity. Nothing here touches the network unless a refresh is due,
//! and any vault failure falls back to refreshing locally as before.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const client = @import("vault_client.zig");
const sync = @import("vault_sync.zig");
const refresh = @import("vault_refresh.zig");
const keys_vault_cli = @import("keys_vault_cli.zig");
const util = @import("util.zig");

pub const Step = enum { adopted, wait, refresh };

pub const Live = struct {
    step: Step,
    s: *sync.Session,
    versions: refresh.Versions,
    slot: []const u8,
    file: []const u8,
    base: u64,

    /// After a refresh under the lease: publish the new login. Failures are
    /// logged; the local refresh already succeeded.
    pub fn commit(l: *Live) void {
        if (l.step != .refresh) return;
        _ = refresh.commit(l.s, l.versions, l.slot, l.file, l.base) catch |err| {
            std.log.scoped(.vault).warn("vault: could not publish the refreshed {s} login: {t}", .{ l.slot, err });
        };
    }
};

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// Is the stored login within `margin_s` of expiry? Files without an
/// `expires_at` (codex keeps its own format) only sync on a forced refresh.
pub fn due(io: Io, arena: Allocator, file: []const u8, margin_s: i64) bool {
    const data = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 * 1024)) catch return false;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return false;
    if (v != .object) return false;
    const e = v.object.get("expires_at") orelse return false;
    if (e != .integer or e.integer == 0) return false;
    return @divTrunc(util.unixMs(io), 1000) >= e.integer - margin_s;
}

/// Plan a refresh of graff's `provider` login against the vault. null means
/// "refresh locally as today": sync is off, nothing is due, or the vault is
/// unreachable.
pub fn before(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, provider: []const u8, force: bool, margin_s: i64) ?*Live {
    const bearer = env("HARNESS_BEARER") orelse return null;
    const file = keys_vault_cli.providerPath(arena, home, provider) orelse return null;
    if (!force and !due(io, arena, file, margin_s)) return null;
    const ident = (keys_vault_cli.loadIdentity(io, gpa, arena, home, false, env("GRAFF_VAULT_DEVICE_FILE")) catch return null) orelse return null;
    const http = arena.create(client.Http) catch return null;
    http.* = .{ .io = io, .gpa = gpa, .base = env("HARNESS_EDGE_URL") orelse client.default_edge };
    const c = arena.create(client.Client) catch return null;
    c.* = .{ .io = io, .arena = arena, .transport = http.transport(), .bearer = bearer, .device_id = ident.id, .keys = ident.keys };
    const s = arena.create(sync.Session) catch return null;
    s.* = sync.Session.open(io, arena, c) catch return null;
    const versions = refresh.Versions.at(io, arena, home) catch return null;
    const p = refresh.plan(s, versions, provider, file) catch return null;
    const live = arena.create(Live) catch return null;
    live.* = .{ .step = .refresh, .s = s, .versions = versions, .slot = provider, .file = file, .base = 0 };
    switch (p) {
        .adopted => live.step = .adopted,
        .wait => live.step = .wait,
        .refresh => |base| live.base = base,
    }
    return live;
}

test "due reads expires_at against the margin and ignores files without one" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = @divTrunc(util.unixMs(io), 1000);
    const soon = try std.fmt.allocPrint(arena, "{{\"access_token\":\"a\",\"expires_at\":{d}}}", .{now + 60});
    const later = try std.fmt.allocPrint(arena, "{{\"access_token\":\"a\",\"expires_at\":{d}}}", .{now + 3600});
    try tmp.dir.writeFile(io, .{ .sub_path = "soon.json", .data = soon });
    try tmp.dir.writeFile(io, .{ .sub_path = "later.json", .data = later });
    try tmp.dir.writeFile(io, .{ .sub_path = "codex.json", .data = "{\"tokens\":{}}" });
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expect(due(io, arena, try std.fmt.allocPrint(arena, "{s}/soon.json", .{base}), 300));
    try std.testing.expect(!due(io, arena, try std.fmt.allocPrint(arena, "{s}/later.json", .{base}), 300));
    try std.testing.expect(!due(io, arena, try std.fmt.allocPrint(arena, "{s}/codex.json", .{base}), 300));
    try std.testing.expect(!due(io, arena, try std.fmt.allocPrint(arena, "{s}/missing.json", .{base}), 300));
}
