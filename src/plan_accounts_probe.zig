//! Status-checked, timeout-bounded HTTP usage and profile probes for plan
//! accounts, plus live-cache window conversion. Zero secrets ever leave here.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const oauth_anthropic = @import("oauth_anthropic.zig");
const plan_usage = @import("plan_usage.zig");
const plan_usage_live = @import("plan_usage_live.zig");
const util = @import("util.zig");

pub const AnthropicProfile = struct {
    email: []const u8 = "",
    display_name: []const u8 = "",
    organization: []const u8 = "",
    plan: []const u8 = "",
};

fn delay(io: Io, duration: Io.Duration) void {
    io.sleep(duration, .awake) catch {};
}

fn fetchGet(client: *std.http.Client, url: []const u8, headers: []const std.http.Header, writer: *Io.Writer) !std.http.Status {
    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = headers,
    });
    defer req.deinit();
    defer if (req.connection) |conn| {
        conn.closing = true;
    };
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.status != .ok) return response.head.status;
    const gpa = client.allocator;
    const dbuf: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (dbuf.len != 0) gpa.free(dbuf);
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, dbuf);
    _ = reader.streamRemaining(writer) catch |err| {
        if (err == error.WriteFailed) return error.ResponseTooLarge;
        return err;
    };
    return response.head.status;
}

pub fn getJsonChecked(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, headers: []const std.http.Header) ![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var buf: [64 * 1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var extra_buf: [8]std.http.Header = undefined;
    const n = @min(headers.len, extra_buf.len);
    @memcpy(extra_buf[0..n], headers[0..n]);

    const Done = union(enum) { fetched: anyerror!std.http.Status, timeout: void };
    var done: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &done);
    select.concurrent(.timeout, delay, .{ io, .fromSeconds(8) }) catch return error.DeadlineUnavailable;
    select.concurrent(.fetched, fetchGet, .{ &client, url, extra_buf[0..n], &writer }) catch {
        select.cancelDiscard();
        return error.TransportUnavailable;
    };
    const first = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.cancelDiscard();
    const status = switch (first) {
        .fetched => |r| try r,
        .timeout => return error.DeadlineExceeded,
    };
    if (status != .ok) return error.HttpError;
    return try arena.dupe(u8, writer.buffered());
}

pub fn liveWindows(io: Io, arena: Allocator, provider: []const u8) !?struct {
    windows: []const plan_usage.Window,
    plan: []const u8,
    credits: ?f64,
} {
    const snap = (plan_usage_live.snapshot(io, arena, provider) catch return null) orelse return null;
    if (snap.windows.len == 0) return null;
    var list: std.ArrayList(plan_usage.Window) = .empty;
    for (snap.windows) |w| {
        const used_pct = w.used_pct orelse if (w.remaining_pct) |rp| plan_usage.remainingOf(rp) else continue;
        const rem_pct = w.remaining_pct orelse plan_usage.remainingOf(used_pct);
        try list.append(arena, .{
            .label = w.label,
            .used_percent = used_pct,
            .remaining_percent = rem_pct,
            .reset_after_seconds = w.resets_in_s,
            .resets_at_unix = w.resets_at_unix,
            .window_seconds = w.window_seconds,
            .status = w.status,
        });
    }
    const credits: ?f64 = if (snap.credits) |c| std.fmt.parseFloat(f64, c) catch null else null;
    return .{ .windows = try list.toOwnedSlice(arena), .plan = snap.plan orelse "", .credits = credits };
}

pub fn parseAnthropicProfile(arena: Allocator, raw: []const u8) !AnthropicProfile {
    const v = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return error.InvalidProfile;
    if (v != .object) return error.InvalidProfile;
    var res: AnthropicProfile = .{};
    var has_max = false;
    var has_pro = false;
    if (v.object.get("account")) |acct| if (acct == .object) {
        if (util.strFieldObj(acct.object, "email")) |e| res.email = e;
        res.display_name = util.strFieldObj(acct.object, "display_name") orelse util.strFieldObj(acct.object, "full_name") orelse util.strFieldObj(acct.object, "name") orelse "";
        if (acct.object.get("has_claude_max")) |b| if (b == .bool and b.bool) {
            has_max = true;
        };
        if (acct.object.get("has_claude_pro")) |b| if (b == .bool and b.bool) {
            has_pro = true;
        };
    };
    var org_type: []const u8 = "";
    var tier: []const u8 = "";
    if (v.object.get("organization")) |org| if (org == .object) {
        if (util.strFieldObj(org.object, "name")) |n| res.organization = n;
        if (util.strFieldObj(org.object, "organization_type")) |t| org_type = t;
        if (util.strFieldObj(org.object, "rate_limit_tier")) |t| tier = t;
    };
    res.plan = if (has_max or util.indexOfIgnoreCase(org_type, "max") != null or util.indexOfIgnoreCase(tier, "max") != null)
        "Claude Max"
    else if (util.indexOfIgnoreCase(org_type, "enterprise") != null)
        "Claude Enterprise"
    else if (util.indexOfIgnoreCase(org_type, "team") != null)
        "Claude Team"
    else if (has_pro or util.indexOfIgnoreCase(org_type, "pro") != null)
        "Claude Pro"
    else if (tier.len > 0)
        tier
    else
        org_type;
    return res;
}

pub fn probeCodexAt(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, token: []const u8, account: []const u8, now_s: i64) ?plan_usage.Report {
    var hdrs: [2]std.http.Header = undefined;
    hdrs[0] = .{ .name = "Authorization", .value = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return null };
    var n: usize = 1;
    if (account.len > 0) {
        hdrs[1] = .{ .name = "ChatGPT-Account-Id", .value = account };
        n = 2;
    }
    const body = getJsonChecked(io, gpa, arena, url, hdrs[0..n]) catch return null;
    return plan_usage.parseCodexWithNow(arena, body, now_s) catch null;
}

pub fn probeAnthropicOAuth(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, token: []const u8, now_s: i64, has_profile: bool) ?plan_usage.Report {
    const auth = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return null;
    const hdrs = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
    };
    var report: plan_usage.Report = .{};
    var got_usage = false;
    if (getJsonChecked(io, gpa, arena, "https://api.anthropic.com/api/oauth/usage", &hdrs)) |body| {
        if (plan_usage.parseAnthropicUsage(arena, body, now_s)) |r| {
            report = r;
            got_usage = true;
        } else |_| {}
    } else |_| {}
    if (!has_profile) {
        if (getJsonChecked(io, gpa, arena, "https://api.anthropic.com/api/oauth/profile", &hdrs)) |pbody| {
            if (parseAnthropicProfile(arena, pbody)) |p| {
                if (p.email.len > 0) report.email = p.email;
                if (p.display_name.len > 0) report.display_name = p.display_name;
                if (p.organization.len > 0) report.organization = p.organization;
                if (p.plan.len > 0) report.plan = p.plan;
                oauth_anthropic.saveProfileMetadata(io, arena, home, p.email, p.display_name, p.organization, p.plan);
                got_usage = true;
            } else |_| {}
        } else |_| {}
    }
    return if (got_usage) report else null;
}

pub fn probeGrokBilling(io: Io, gpa: Allocator, arena: Allocator, token: []const u8, now_s: i64) ?plan_usage.Report {
    const auth = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return null;
    const hdrs = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" },
    };
    const body = getJsonChecked(io, gpa, arena, "https://cli-chat-proxy.grok.com/v1/billing?format=credits", &hdrs) catch return null;
    return plan_usage.parseGrokBilling(arena, body, now_s) catch null;
}

test "parseAnthropicProfile extracts account identity, org, and max/pro plan" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try parseAnthropicProfile(arena_state.allocator(),
        \\{"account":{"email":"dev@example.com","display_name":"Dev User","has_claude_max":true},"organization":{"name":"Acme","organization_type":"claude_max"}}
    );
    try std.testing.expectEqualStrings("dev@example.com", p.email);
    try std.testing.expectEqualStrings("Dev User", p.display_name);
    try std.testing.expectEqualStrings("Acme", p.organization);
    try std.testing.expectEqualStrings("Claude Max", p.plan);
}
