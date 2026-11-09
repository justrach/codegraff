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
    before_bytes: []const u8 = "",

    /// After a refresh under the lease: publish the new login only when the
    /// local credential file actually changed. A transient offline/5xx failure
    /// leaves the local file untouched and releases the lease without advancing
    /// the vault version.
    pub fn commit(l: *Live) void {
        if (l.step != .refresh) return;
        const after = Io.Dir.cwd().readFileAlloc(l.s.io, l.file, l.s.arena, .limited(1 << 20)) catch {
            l.s.c.release("graff", l.slot) catch {};
            return;
        };
        if (std.mem.eql(u8, after, l.before_bytes)) {
            l.s.c.release("graff", l.slot) catch {};
            return;
        }
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
    const edge_url = env("HARNESS_EDGE_URL") orelse client.default_edge;
    client.checkEdgeUrl(edge_url) catch return null;
    http.* = .{ .io = io, .gpa = gpa, .base = edge_url };
    const c = arena.create(client.Client) catch return null;
    c.* = .{ .io = io, .arena = arena, .transport = http.transport(), .bearer = bearer, .device_id = ident.id, .keys = ident.keys };
    const s = arena.create(sync.Session) catch return null;
    s.* = sync.Session.open(io, arena, c) catch return null;
    s.prev_key_path = keys_vault_cli.prevKeyPath(arena, home, env("GRAFF_VAULT_DEVICE_FILE")) catch null;
    const versions = refresh.Versions.at(io, arena, home) catch return null;
    const p = refresh.plan(s, versions, provider, file) catch return null;
    const live = arena.create(Live) catch return null;
    live.* = .{ .step = .refresh, .s = s, .versions = versions, .slot = provider, .file = file, .base = 0 };
    switch (p) {
        .adopted => live.step = .adopted,
        .wait => live.step = .wait,
        .refresh => |base| {
            live.base = base;
            live.before_bytes = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(1 << 20)) catch "";
        },
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

test "Live.commit releases the vault lease without bumping version when local refresh failed transiently" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const file = try std.fmt.allocPrint(arena, "{s}/kimi.json", .{home});

    var edge = @import("vault_mock_edge.zig").MockEdge.init(std.testing.allocator);
    defer edge.deinit();
    var c: client.Client = .{
        .io = io,
        .arena = arena,
        .transport = edge.transport(),
        .bearer = "user-1",
        .device_id = "dev-a",
        .keys = @import("vault_crypto.zig").DeviceKeys.generate(io),
        .now_ms = 1,
    };
    var s = try sync.Session.open(io, arena, &c);
    _ = try s.enable("laptop");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "token-v1" });
    const v1 = try s.push("graff", "kimi", "rotating", "token-v1");
    const versions = try refresh.Versions.at(io, arena, home);
    try versions.set("kimi", v1);

    // Take lease via plan, simulate transient provider error (file stays "token-v1").
    const p1 = try refresh.plan(&s, versions, "kimi", file);
    var live1: Live = .{ .step = .refresh, .s = &s, .versions = versions, .slot = "kimi", .file = file, .base = p1.refresh, .before_bytes = "token-v1" };
    live1.commit();
    try std.testing.expectEqual(v1, (try c.getItem("graff", "kimi")).?.version);
    // Lease was released, so a subsequent attempt can immediately acquire it.
    const p2 = try refresh.plan(&s, versions, "kimi", file);
    try std.testing.expect(p2 == .refresh);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "token-v2" });
    var live2: Live = .{ .step = .refresh, .s = &s, .versions = versions, .slot = "kimi", .file = file, .base = p2.refresh, .before_bytes = "token-v1" };
    live2.commit();
    try std.testing.expectEqual(v1 + 1, (try c.getItem("graff", "kimi")).?.version);
}
