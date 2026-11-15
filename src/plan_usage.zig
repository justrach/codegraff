//! Account-plan remaining for `/usage` & ACP `graff/accounts`.
//! Session $/tokens stay in `pricing.CostTally`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const oauth = @import("oauth.zig");
const util = @import("util.zig");

pub const Window = struct {
    label: []const u8,
    used_percent: f64,
    remaining_percent: f64,
    reset_after_seconds: ?i64 = null,
    resets_at_unix: ?i64 = null,
    window_seconds: ?i64 = null,
    status: ?[]const u8 = null,
};

pub const Report = struct {
    provider: []const u8 = "",
    plan: []const u8 = "",
    email: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    auth_kind: []const u8 = "",
    windows: []const Window = &.{},
    prepaid_cents: ?i64 = null,
    reset_credits: ?f64 = null,
    note: []const u8 = "",
};

pub fn remainingOf(used_percent: f64) f64 {
    if (!std.math.isFinite(used_percent)) return 0;
    return std.math.clamp(100 - used_percent, 0, 100);
}

fn numberOf(v: Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null,
        else => null,
    };
}

fn intOf(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
        else => null,
    };
}

/// Parse RFC3339 / ISO-8601 UTC or offset timestamp (`YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`).
pub fn parseRfc3339Unix(raw: []const u8) ?i64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't' and s[10] != ' ')) return null;
    if (s[13] != ':' or s[16] != ':') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const min = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour < 0 or hour > 23 or min < 0 or min > 59 or sec < 0 or sec > 60) return null;

    var idx: usize = 19;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        while (idx < s.len and std.ascii.isDigit(s[idx])) : (idx += 1) {}
    }
    var offset_s: i64 = 0;
    if (idx >= s.len) return null;
    if (s[idx] == 'Z' or s[idx] == 'z') {
        if (idx + 1 != s.len) return null;
    } else if (s[idx] == '+' or s[idx] == '-') {
        const sign: i64 = if (s[idx] == '+') 1 else -1;
        const tz = s[idx + 1 ..];
        if (tz.len == 5 and tz[2] == ':') {
            const oh = std.fmt.parseInt(i64, tz[0..2], 10) catch return null;
            const om = std.fmt.parseInt(i64, tz[3..5], 10) catch return null;
            offset_s = sign * (oh * 3600 + om * 60);
        } else if (tz.len == 4) {
            const oh = std.fmt.parseInt(i64, tz[0..2], 10) catch return null;
            const om = std.fmt.parseInt(i64, tz[2..4], 10) catch return null;
            offset_s = sign * (oh * 3600 + om * 60);
        } else return null;
    } else return null;

    const y: i64 = if (month <= 2) year - 1 else year;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const m_adj: i64 = month + (if (month > 2) @as(i64, -3) else 9);
    const doy: i64 = @divTrunc(153 * m_adj + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days: i64 = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + min * 60 + sec - offset_s;
}

pub fn codexWindowLabel(arena: Allocator, prefix: ?[]const u8, secondary: bool, window_seconds: ?i64) ![]const u8 {
    const span: []const u8 = if (window_seconds) |ws| blk: {
        if (ws == 18000) break :blk "5h";
        if (ws == 604800) break :blk "weekly";
        if (ws >= 86400 and @mod(ws, 86400) == 0) break :blk try std.fmt.allocPrint(arena, "{d}d", .{@divTrunc(ws, 86400)});
        if (ws >= 3600 and @mod(ws, 3600) == 0) break :blk try std.fmt.allocPrint(arena, "{d}h", .{@divTrunc(ws, 3600)});
        if (ws >= 60) break :blk try std.fmt.allocPrint(arena, "{d}m", .{@divTrunc(ws, 60)});
        break :blk try std.fmt.allocPrint(arena, "{d}s", .{@max(1, ws)});
    } else if (secondary) "weekly" else "5h";

    const raw_prefix = prefix orelse return span;
    const pretty = if (std.ascii.eqlIgnoreCase(raw_prefix, "codex_bengalfox")) "GPT-5.3-Codex-Spark" else raw_prefix;
    return if (window_seconds != null) try std.fmt.allocPrint(arena, "{s} ({s})", .{ pretty, span }) else pretty;
}

fn windowFromWithNow(arena: Allocator, obj: std.json.ObjectMap, prefix: ?[]const u8, secondary: bool, now_unix: i64) !?Window {
    const used = if (obj.get("used_percent")) |v| numberOf(v) orelse return null else return null;
    const win_secs = if (obj.get("limit_window_seconds")) |v| intOf(v) else null;
    var reset_after: ?i64 = if (obj.get("reset_after_seconds")) |v| intOf(v) else null;
    var resets_at: ?i64 = if (obj.get("reset_at")) |v| intOf(v) else null;
    if (resets_at) |at| {
        if (reset_after == null) {
            reset_after = if (now_unix > 0) @max(0, at - now_unix) else if (at < 1_000_000_000) at else null;
        }
    } else if (reset_after) |delta| {
        if (now_unix > 0) resets_at = now_unix + @max(0, delta);
    }
    return .{
        .label = try codexWindowLabel(arena, prefix, secondary, win_secs),
        .used_percent = used,
        .remaining_percent = remainingOf(used),
        .reset_after_seconds = reset_after,
        .resets_at_unix = resets_at,
        .window_seconds = win_secs,
    };
}

fn appendCodexRlWindows(arena: Allocator, list: *std.ArrayList(Window), rl: std.json.ObjectMap, prefix: ?[]const u8, now_unix: i64) !void {
    if (rl.get("primary_window")) |w| if (w == .object) {
        if (try windowFromWithNow(arena, w.object, prefix, false, now_unix)) |win| try list.append(arena, win);
    };
    if (rl.get("secondary_window")) |w| if (w == .object) {
        if (try windowFromWithNow(arena, w.object, prefix, true, now_unix)) |win| try list.append(arena, win);
    };
}

pub fn parseCodex(arena: Allocator, raw: []const u8) !Report {
    return parseCodexWithNow(arena, raw, 0);
}

/// Parse Codex `/wham/usage` or `/api/codex/usage` JSON. Missing windows are omitted.
pub fn parseCodexWithNow(arena: Allocator, raw: []const u8, now_unix: i64) !Report {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return error.InvalidUsage;
    if (parsed != .object) return error.InvalidUsage;
    const plan = util.strFieldObj(parsed.object, "plan_type") orelse "";
    var list: std.ArrayList(Window) = .empty;
    if (parsed.object.get("rate_limit")) |rl| if (rl == .object) try appendCodexRlWindows(arena, &list, rl.object, null, now_unix);
    if (parsed.object.get("additional_rate_limits")) |extra| if (extra == .array) {
        for (extra.array.items) |item| {
            if (item != .object) continue;
            const name = util.strFieldObj(item.object, "limit_name") orelse util.strFieldObj(item.object, "metered_feature") orelse util.strFieldObj(item.object, "name") orelse util.strFieldObj(item.object, "id") orelse "extra";
            const nested_rl = blk: {
                if (item.object.get("details")) |d| if (d == .object) if (d.object.get("rate_limit")) |dr| if (dr == .object) break :blk dr.object;
                if (item.object.get("rate_limit")) |ir| if (ir == .object) break :blk ir.object;
                break :blk item.object;
            };
            try appendCodexRlWindows(arena, &list, nested_rl, name, now_unix);
        }
    };
    var reset_credits: ?f64 = null;
    if (parsed.object.get("rate_limit_reset_credits")) |rc| if (rc == .object) if (rc.object.get("available_count")) |v| {
        reset_credits = numberOf(v);
    };
    if (reset_credits == null) if (parsed.object.get("credits")) |cr| if (cr == .object) if (cr.object.get("balance")) |v| {
        reset_credits = numberOf(v);
    };
    return .{ .plan = plan, .windows = try list.toOwnedSlice(arena), .reset_credits = reset_credits };
}

fn formatGrokTier(arena: Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return "";
    if (std.ascii.eqlIgnoreCase(raw, "SUBSCRIPTION_TIER_SUPER_GROK") or std.ascii.eqlIgnoreCase(raw, "SuperGrok")) return "SuperGrok";
    if (std.ascii.eqlIgnoreCase(raw, "SUBSCRIPTION_TIER_GROK_PRO") or std.ascii.eqlIgnoreCase(raw, "GrokPro")) return "Grok Pro";
    const stem = if (std.mem.startsWith(u8, raw, "SUBSCRIPTION_TIER_")) raw["SUBSCRIPTION_TIER_".len..] else raw;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, stem, '_');
    while (it.next()) |w| {
        if (w.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.append(arena, std.ascii.toUpper(w[0]));
        for (w[1..]) |c| try out.append(arena, std.ascii.toLower(c));
    }
    return if (out.items.len > 0) out.items else raw;
}

/// Parse `xai-org/grok-build` `/v1/billing?format=credits` response (`BillingConfigResponse`).
pub fn parseGrokBilling(arena: Allocator, raw: []const u8, now_unix: i64) !Report {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return error.InvalidUsage;
    if (parsed != .object) return error.InvalidUsage;
    const plan = try formatGrokTier(arena, util.strFieldObj(parsed.object, "subscriptionTier") orelse "");
    var list: std.ArrayList(Window) = .empty;
    if (parsed.object.get("productUsage")) |pu| if (pu == .array) {
        var target: ?std.json.ObjectMap = null;
        for (pu.array.items) |item| {
            if (item != .object) continue;
            const prod = util.strFieldObj(item.object, "product") orelse "";
            if (std.mem.eql(u8, prod, "PRODUCT_GROK_BUILD") or std.mem.eql(u8, prod, "GrokBuild")) {
                target = item.object;
                break;
            }
        }
        if (target == null and pu.array.items.len == 1 and pu.array.items[0] == .object) target = pu.array.items[0].object;
        if (target) |tobj| {
            if (tobj.get("creditUsagePercent")) |cv| if (numberOf(cv)) |used_raw| {
                const used = std.math.clamp(used_raw, 0, 100);
                var label: []const u8 = "Cycle";
                var resets_at: ?i64 = null;
                var reset_after: ?i64 = null;
                if (tobj.get("currentPeriod")) |cp| if (cp == .object) {
                    const p = util.strFieldObj(cp.object, "period") orelse "";
                    if (std.ascii.eqlIgnoreCase(p, "daily")) label = "Daily" else if (std.ascii.eqlIgnoreCase(p, "weekly")) label = "Weekly" else if (std.ascii.eqlIgnoreCase(p, "monthly")) label = "Monthly";
                    if (util.strFieldObj(cp.object, "end")) |end_str| {
                        resets_at = parseRfc3339Unix(end_str);
                        if (resets_at != null and now_unix > 0) reset_after = @max(0, resets_at.? - now_unix);
                    }
                };
                try list.append(arena, .{
                    .label = label,
                    .used_percent = used,
                    .remaining_percent = remainingOf(used),
                    .reset_after_seconds = reset_after,
                    .resets_at_unix = resets_at,
                });
            };
        }
    };
    var prepaid_cents: ?i64 = null;
    if (parsed.object.get("prepaidBalance")) |pb| if (pb == .object) if (pb.object.get("val")) |v| {
        prepaid_cents = intOf(v);
    };
    return .{ .plan = plan, .windows = try list.toOwnedSlice(arena), .prepaid_cents = prepaid_cents };
}

/// Parse `https://api.anthropic.com/api/oauth/usage` JSON (`0..100` utilization).
pub fn parseAnthropicUsage(arena: Allocator, raw: []const u8, now_unix: i64) !Report {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return error.InvalidUsage;
    if (parsed != .object) return error.InvalidUsage;
    const buckets = [_][2][]const u8{
        .{ "five_hour", "5h" },          .{ "seven_day", "weekly" },
        .{ "seven_day_opus", "Opus" },   .{ "seven_day_sonnet", "Sonnet" },
        .{ "seven_day_haiku", "Haiku" }, .{ "fable", "Fable" },
        .{ "seven_day_fable", "Fable" },
    };
    var list: std.ArrayList(Window) = .empty;
    for (buckets) |b| {
        const node = parsed.object.get(b[0]) orelse continue;
        if (node != .object) continue;
        const uv = node.object.get("utilization") orelse continue;
        if (uv == .null) continue;
        const used_raw = numberOf(uv) orelse continue;
        const used = std.math.clamp(used_raw, 0, 100);
        var resets_at: ?i64 = null;
        var reset_after: ?i64 = null;
        if (node.object.get("resets_at")) |rv| {
            if (rv == .string) resets_at = parseRfc3339Unix(rv.string) else resets_at = intOf(rv);
            if (resets_at != null and now_unix > 0) reset_after = @max(0, resets_at.? - now_unix);
        }
        try list.append(arena, .{
            .label = b[1],
            .used_percent = used,
            .remaining_percent = remainingOf(used),
            .reset_after_seconds = reset_after,
            .resets_at_unix = resets_at,
        });
    }
    var note: []const u8 = "";
    if (parsed.object.get("extra_usage")) |eu| if (eu == .object) {
        if (eu.object.get("is_enabled")) |en| if (en == .bool and en.bool) {
            const used_c = if (eu.object.get("used_credits")) |v| numberOf(v) else null;
            const lim_c = if (eu.object.get("monthly_limit")) |v| numberOf(v) else null;
            if (used_c != null and lim_c != null) {
                note = try std.fmt.allocPrint(arena, "extra usage: {d:.0}/{d:.0} credits", .{ used_c.?, lim_c.? });
            }
        };
    };
    return .{ .windows = try list.toOwnedSlice(arena), .note = note };
}

pub fn parseRateLimitHeaders(arena: Allocator, remaining_req: ?[]const u8, limit_req: ?[]const u8, remaining_tok: ?[]const u8, limit_tok: ?[]const u8) !Report {
    var list: std.ArrayList(Window) = .empty;
    try addHeaderWindow(arena, &list, "requests", remaining_req, limit_req);
    try addHeaderWindow(arena, &list, "tokens/min", remaining_tok, limit_tok);
    const note: []const u8 = if (list.items.len == 0) "xAI weekly plan remaining is not available" else "API rate-limit headers (not Grok billing pool)";
    return .{ .windows = try list.toOwnedSlice(arena), .note = note };
}

fn addHeaderWindow(arena: Allocator, list: *std.ArrayList(Window), label: []const u8, remaining: ?[]const u8, limit: ?[]const u8) !void {
    const rem = parseU64(remaining) orelse return;
    const lim = parseU64(limit) orelse return;
    if (lim == 0) return;
    const used = (1 - @as(f64, @floatFromInt(rem)) / @as(f64, @floatFromInt(lim))) * 100;
    try list.append(arena, .{ .label = label, .used_percent = used, .remaining_percent = remainingOf(used) });
}

fn parseU64(raw: ?[]const u8) ?u64 {
    const s = std.mem.trim(u8, raw orelse return null, " \t");
    if (s.len == 0) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

pub fn renderWindows(w: *Io.Writer, report: Report) !void {
    if (report.email != null or report.display_name != null or report.organization != null) {
        try w.writeAll("  account:   ");
        if (report.display_name) |dn| {
            try w.writeAll(dn);
            if (report.email) |em| try w.print(" <{s}>", .{em});
        } else if (report.email) |em| {
            try w.writeAll(em);
        }
        if (report.organization) |org| try w.print(" ({s})", .{org});
        try w.writeByte('\n');
    }
    if (report.plan.len > 0) try w.print("  plan:      {s}\n", .{report.plan});
    var rb: [32]u8 = undefined;
    for (report.windows) |win| {
        try w.print("  {s}: {d:.0}% remaining ({d:.0}% used)", .{ win.label, win.remaining_percent, win.used_percent });
        if (win.reset_after_seconds) |secs| if (secs > 0) try w.print(", resets in {s}", .{fmtResetBuf(&rb, secs)});
        try w.writeByte('\n');
    }
    if (report.prepaid_cents) |cents| {
        const abs: u64 = @abs(cents);
        const sign: []const u8 = if (cents < 0) "-" else "";
        try w.print("  prepaid:   {s}${d}.{d:0>2}\n", .{ sign, abs / 100, abs % 100 });
    }
    if (report.reset_credits) |cr| try w.print("  credits:   {d:.2}\n", .{cr});
    if (report.note.len > 0) try w.print("  {s}\n", .{report.note});
}

fn fmtResetBuf(buf: []u8, secs: i64) []const u8 {
    if (secs >= 86400) return std.fmt.bufPrint(buf, "{d}d {d}h", .{ @divTrunc(secs, 86400), @divTrunc(@mod(secs, 86400), 3600) }) catch "soon";
    if (secs >= 3600) return std.fmt.bufPrint(buf, "{d}h {d}m", .{ @divTrunc(secs, 3600), @divTrunc(@mod(secs, 3600), 60) }) catch "soon";
    if (secs >= 60) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(secs, 60)}) catch "soon";
    return "<1m";
}

fn getJson(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, extra: []const std.http.Header) ![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var extra_buf: [8]std.http.Header = undefined;
    const n = @min(extra.len, extra_buf.len);
    @memcpy(extra_buf[0..n], extra[0..n]);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = extra_buf[0..n],
    });
    if (res.status != .ok) return error.FetchFailed;
    return aw.writer.buffered();
}

pub fn fetchCodex(io: Io, gpa: Allocator, arena: Allocator, home: []const u8) !?Report {
    const auth = oauth.loadCodexAuth(io, arena, home) orelse return null;
    var extra: [2]std.http.Header = undefined;
    extra[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{auth.token}) };
    var n: usize = 1;
    if (auth.account.len > 0) {
        extra[1] = .{ .name = "ChatGPT-Account-Id", .value = auth.account };
        n = 2;
    }
    const body = getJson(io, gpa, arena, "https://chatgpt.com/backend-api/wham/usage", extra[0..n]) catch return error.FetchFailed;
    return try parseCodexWithNow(arena, body, @divTrunc(util.unixMs(io), 1000));
}

pub fn fetchXaiHeaders(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, api_key: ?[]const u8) !?Report {
    const token = api_key orelse oauth.loadXaiOAuth(io, gpa, arena, home, false, null) orelse return null;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    var extra_buf: [2]std.http.Header = undefined;
    extra_buf[0] = .{ .name = "Authorization", .value = auth };
    var extra_n: usize = 1;
    if (api_key == null) {
        extra_buf[1] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
        extra_n = 2;
    }
    var req = try client.request(.GET, try std.Uri.parse("https://api.x.ai/v1/models"), .{
        .redirect_behavior = .unhandled,
        .extra_headers = extra_buf[0..extra_n],
    });
    defer req.deinit();
    defer if (req.connection) |conn| {
        conn.closing = true;
    };
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    var rem_r: ?[]const u8 = null;
    var lim_r: ?[]const u8 = null;
    var rem_t: ?[]const u8 = null;
    var lim_t: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-remaining-requests")) rem_r = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-limit-requests")) lim_r = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-remaining-tokens")) rem_t = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-limit-tokens")) lim_t = h.value;
    }
    return try parseRateLimitHeaders(arena, rem_r, lim_r, rem_t, lim_t);
}

pub fn appendTo(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *const @import("provider.zig").Keys, active_provider: []const u8, out: *Io.Writer) void {
    @import("plan_accounts.zig").appendUsageTo(io, gpa, arena, home, keys, active_provider, out);
}

test "remainingOf clamps used percent and parseRfc3339Unix handles UTC and offsets" {
    try std.testing.expectEqual(@as(f64, 42), remainingOf(58));
    try std.testing.expectEqual(@as(f64, 0), remainingOf(140));
    try std.testing.expectEqual(@as(?i64, 0), parseRfc3339Unix("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1770000000), parseRfc3339Unix("2026-02-02T02:40:00.123Z"));
    try std.testing.expectEqual(@as(?i64, 1770000000), parseRfc3339Unix("2026-02-02T04:40:00+02:00"));
}

test "parseCodexWithNow reads reset_at epoch, window spans, nested additional_rate_limits, and credits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report = try parseCodexWithNow(arena_state.allocator(),
        \\{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_at":1770001800},"secondary_window":{"used_percent":18,"reset_after_seconds":345600}},"additional_rate_limits":[{"limit_name":"codex_bengalfox","details":{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1770003600}}}}],"rate_limit_reset_credits":{"available_count":2.5}}
    , 1770000000);
    try std.testing.expectEqualStrings("pro", report.plan);
    try std.testing.expectEqual(@as(usize, 3), report.windows.len);
    try std.testing.expectEqualStrings("5h", report.windows[0].label);
    try std.testing.expectEqual(@as(?i64, 1800), report.windows[0].reset_after_seconds);
    try std.testing.expectEqual(@as(?i64, 1770001800), report.windows[0].resets_at_unix);
    try std.testing.expectEqualStrings("weekly", report.windows[1].label);
    try std.testing.expectEqualStrings("GPT-5.3-Codex-Spark (5h)", report.windows[2].label);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), report.reset_credits.?, 0.001);
}

test "parseCodex reads legacy relative windows and omits missing windows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report = try parseCodex(arena_state.allocator(),
        \\{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":42,"reset_after_seconds":8100},"secondary_window":{"used_percent":18,"reset_after_seconds":345600}}}
    );
    try std.testing.expectEqual(@as(usize, 2), report.windows.len);
    try std.testing.expectEqualStrings("5h", report.windows[0].label);
    try std.testing.expectEqual(@as(f64, 58), report.windows[0].remaining_percent);
    const empty = try parseCodex(arena_state.allocator(), "{}");
    try std.testing.expectEqual(@as(usize, 0), empty.windows.len);
}

test "parseGrokBilling and parseAnthropicUsage decode billing periods, prepaid cents, and model buckets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const grok = try parseGrokBilling(arena_state.allocator(),
        \\{"subscriptionTier":"SUBSCRIPTION_TIER_GROK_PRO","prepaidBalance":{"val":"1542"},"productUsage":[{"product":"PRODUCT_GROK_BUILD","creditUsagePercent":22.5,"currentPeriod":{"period":"weekly","end":"2026-02-03T02:40:00Z"}}]}
    , 1770000000);
    try std.testing.expectEqualStrings("Grok Pro", grok.plan);
    try std.testing.expectEqual(@as(?i64, 1542), grok.prepaid_cents);
    try std.testing.expectEqualStrings("Weekly", grok.windows[0].label);
    try std.testing.expectApproxEqAbs(@as(f64, 77.5), grok.windows[0].remaining_percent, 0.01);
    try std.testing.expectEqual(@as(?i64, 86400), grok.windows[0].reset_after_seconds);

    const ant = try parseAnthropicUsage(arena_state.allocator(),
        \\{"five_hour":{"utilization":30,"resets_at":"2026-02-02T03:40:00Z"},"seven_day":{"utilization":12},"seven_day_opus":{"utilization":45},"fable":{"utilization":80}}
    , 1770000000);
    try std.testing.expectEqual(@as(usize, 4), ant.windows.len);
    try std.testing.expectEqualStrings("5h", ant.windows[0].label);
    try std.testing.expectApproxEqAbs(@as(f64, 70), ant.windows[0].remaining_percent, 0.01);
    try std.testing.expectEqual(@as(?i64, 3600), ant.windows[0].reset_after_seconds);
    try std.testing.expectEqualStrings("Opus", ant.windows[2].label);
    try std.testing.expectEqualStrings("Fable", ant.windows[3].label);
}
