//! ACP `graff/accounts` (and `_codegraff/accounts`) handler returning signed-in
//! account identities, plans, credits, and remaining usage windows.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const plan_accounts = @import("plan_accounts.zig");
const provider_mod = @import("provider.zig");
const proto = @import("acp_protocol.zig");

const WindowWire = struct {
    label: []const u8,
    usedPercent: f64,
    remainingPercent: f64,
    resetAfterSeconds: ?i64 = null,
    resetsAtUnix: ?i64 = null,
    windowSeconds: ?i64 = null,
    status: ?[]const u8 = null,
};

const AccountWire = struct {
    provider: []const u8,
    authenticated: bool,
    authKind: []const u8,
    email: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    prepaidCents: ?i64 = null,
    resetCredits: ?f64 = null,
    note: ?[]const u8 = null,
    windows: []const WindowWire = &.{},
};

fn probeParam(params: ?std.json.Value) bool {
    const p = params orelse return true;
    if (p != .object) return true;
    const v = p.object.get("probe") orelse return true;
    return if (v == .bool) v.bool else true;
}

pub fn handle(arena: Allocator, io: Io, gpa: Allocator, home: []const u8, keys: *const provider_mod.Keys, active_provider: []const u8, out: *Io.Writer, req: proto.Request) !bool {
    if (!std.mem.eql(u8, req.method, "graff/accounts") and !std.mem.eql(u8, req.method, "_codegraff/accounts")) return false;
    if (req.id == null) return true;
    const include_usage = probeParam(req.params);
    const entries = try plan_accounts.collectAccounts(io, gpa, arena, home, keys, include_usage);
    const wire = try arena.alloc(AccountWire, entries.len);
    for (entries, 0..) |e, i| {
        const wins = try arena.alloc(WindowWire, e.windows.len);
        for (e.windows, 0..) |w, j| {
            wins[j] = .{
                .label = w.label,
                .usedPercent = w.used_percent,
                .remainingPercent = w.remaining_percent,
                .resetAfterSeconds = w.reset_after_seconds,
                .resetsAtUnix = w.resets_at_unix,
                .windowSeconds = w.window_seconds,
                .status = w.status,
            };
        }
        wire[i] = .{
            .provider = e.provider,
            .authenticated = e.authenticated,
            .authKind = e.auth_kind,
            .email = e.email,
            .displayName = e.display_name,
            .organization = e.organization,
            .plan = e.plan,
            .prepaidCents = e.prepaid_cents,
            .resetCredits = e.reset_credits,
            .note = e.note,
            .windows = wins,
        };
    }
    try proto.writeResult(out, req.id, .{ .activeProvider = active_provider, .accounts = wire });
    return true;
}

test "graff/accounts emits camelCase account identity and windows without secret tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const live = @import("plan_usage_live.zig");
    live.resetForTest();
    defer live.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try a.dupe(u8, pbuf[0..try tmp.dir.realPath(std.testing.io, &pbuf)]);
    const xai_dir = try std.fmt.allocPrint(a, "{s}/.xai/credentials", .{home});
    try Io.Dir.cwd().createDirPath(std.testing.io, xai_dir);
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/graff-oauth.json", .{xai_dir}),
        .data = "{\"access_token\":\"xai-secret-bearer\",\"refresh_token\":\"xai-secret-refresh\",\"expires_at\":4102444800,\"email\":\"grok@example.com\",\"plan\":\"Grok Pro\"}",
    });
    live.noteHeaderList(std.testing.io, "xai", "grok-4.7", 200, &.{
        .{ .name = "x-ratelimit-limit-requests", .value = "100" },
        .{ .name = "x-ratelimit-remaining-requests", .value = "80" },
    });

    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    const req: proto.Request = .{
        .id = .{ .integer = 7 },
        .method = "graff/accounts",
        .params = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"probe\":false}", .{}),
    };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.testing.expect(try handle(a, std.testing.io, std.testing.allocator, home, &keys, "xai", &aw.writer, req));
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "xai-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"activeProvider\":\"xai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"email\":\"grok@example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plan\":\"Grok Pro\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"remainingPercent\":80") != null);
}
