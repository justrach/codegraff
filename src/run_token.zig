//! A cloud agent's short-lived launch credential (`cg_lt_`), delivered by the
//! gateway's `POST /v1/runs` as a 0600 JSON file at `~/.codegraff/run.json`:
//! `{"token","run_id","expires_at","max_expires_at","renew_url"}`.
//!
//! The token is the agent's codegraff key (oauth_codegraff.loadKey falls back
//! to it), so it never appears in argv or the environment. remote-control
//! renews it every third of its remaining lifetime — renewing also counts as
//! sandbox activity, so it is the auto-stop heartbeat — and exits once the
//! run is revoked or expired: a killed run must not keep a live agent.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const util = @import("util.zig");

pub const file = ".codegraff/run.json";

pub const Run = struct {
    token: []const u8,
    run_id: []const u8,
    renew_url: []const u8,
    expires_at: i64,
    max_expires_at: i64,
};

/// Seconds since the epoch; the gateway may also send milliseconds.
fn seconds(v: ?Value) i64 {
    const raw: i64 = switch (v orelse return 0) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => return 0,
    };
    return if (raw > 100_000_000_000) @divTrunc(raw, 1000) else raw;
}

pub fn parse(arena: Allocator, data: []const u8) ?Run {
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const token = util.strFieldObj(v.object, "token") orelse return null;
    if (!std.mem.startsWith(u8, token, "cg_")) return null;
    return .{
        .token = token,
        .run_id = util.strFieldObj(v.object, "run_id") orelse "",
        .renew_url = util.strFieldObj(v.object, "renew_url") orelse "",
        .expires_at = seconds(v.object.get("expires_at")),
        .max_expires_at = seconds(v.object.get("max_expires_at")),
    };
}

pub fn load(io: Io, arena: Allocator, home: []const u8) ?Run {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, file }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024)) catch return null;
    return parse(arena, data);
}

/// Next renew: a third of the remaining lifetime, at least 1s, at most 10 min.
pub fn renewDelayMs(expires_at: i64, now: i64) u64 {
    const left = @max(expires_at - now, 3);
    return @intCast(std.math.clamp(@divTrunc(left * 1000, 3), 1000, 600_000));
}

pub const Outcome = union(enum) {
    /// Renewed to this expiry (seconds).
    renewed: i64,
    /// Transient failure; retry soon.
    retry,
    /// Revoked, expired, or refused: the run is over.
    ended: []const u8,
};

/// One renew call. 200 extends; 401/403/409 end the run; anything else retries.
pub fn renew(io: Io, gpa: Allocator, arena: Allocator, run: Run) Outcome {
    if (run.renew_url.len == 0) return .{ .ended = "run file has no renew_url" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const auth = std.fmt.allocPrint(arena, "Bearer {s}", .{run.token}) catch return .retry;
    const res = client.fetch(.{
        .location = .{ .url = run.renew_url },
        .method = .POST,
        .payload = "{}",
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = auth } },
    }) catch return .retry;
    const code: u16 = @intFromEnum(res.status);
    const body = aw.writer.buffered();
    if (code >= 200 and code < 300) {
        const v = std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always }) catch return .retry;
        if (v != .object) return .retry;
        const exp = seconds(v.object.get("expires_at"));
        return if (exp > 0) .{ .renewed = exp } else .retry;
    }
    if (code == 401 or code == 403 or code == 409) return .{ .ended = errorType(arena, body) orelse "revoked" };
    return .retry;
}

fn errorType(arena: Allocator, body: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const e = v.object.get("error") orelse return null;
    if (e != .object) return null;
    return util.strFieldObj(e.object, "type") orelse util.strFieldObj(e.object, "message");
}

test "run file parses the gateway's run_file and normalises milliseconds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = parse(a, "{\"token\":\"cg_lt_ab\",\"run_id\":\"r1\",\"expires_at\":1790000000000,\"max_expires_at\":1790021600,\"renew_url\":\"https://g/v1/runs/r1/renew\"}").?;
    try std.testing.expectEqualStrings("cg_lt_ab", r.token);
    try std.testing.expectEqual(@as(i64, 1790000000), r.expires_at);
    try std.testing.expectEqual(@as(i64, 1790021600), r.max_expires_at);
    try std.testing.expect(parse(a, "{\"token\":\"nope\"}") == null);
    try std.testing.expect(parse(a, "[]") == null);
}

test "renew waits a third of the remaining lifetime, clamped" {
    try std.testing.expectEqual(@as(u64, 600_000), renewDelayMs(1800 + 100, 100));
    try std.testing.expectEqual(@as(u64, 3_000), renewDelayMs(109, 100));
    try std.testing.expectEqual(@as(u64, 1_000), renewDelayMs(50, 100));
}
