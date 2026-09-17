//! Account-plan remaining for `/usage`. Session $/tokens stay in pricing.CostTally.
//! Codex: ChatGPT `/wham/usage` (same windows Codex `/status` shows).
//! xAI: response rate-limit headers. SuperGrok weekly % is not a public API.

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
};

pub const Report = struct {
    plan: []const u8 = "",
    windows: []const Window = &.{},
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
        else => null,
    };
}

fn intOf(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn windowFrom(obj: std.json.ObjectMap, label: []const u8) ?Window {
    const used = if (obj.get("used_percent")) |v| numberOf(v) orelse return null else return null;
    const reset = if (obj.get("reset_after_seconds")) |v| intOf(v) else if (obj.get("reset_at")) |v| intOf(v) else null;
    return .{ .label = label, .used_percent = used, .remaining_percent = remainingOf(used), .reset_after_seconds = reset };
}

/// Parse Codex `/wham/usage` JSON. Missing windows are omitted, not invented.
pub fn parseCodex(arena: Allocator, raw: []const u8) !Report {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return error.InvalidUsage;
    if (parsed != .object) return error.InvalidUsage;
    const plan = util.strFieldObj(parsed.object, "plan_type") orelse "";
    var list: std.ArrayList(Window) = .empty;
    if (parsed.object.get("rate_limit")) |rl| if (rl == .object) {
        if (rl.object.get("primary_window")) |w| if (w == .object) {
            if (windowFrom(w.object, "5h")) |win| try list.append(arena, win);
        };
        if (rl.object.get("secondary_window")) |w| if (w == .object) {
            if (windowFrom(w.object, "weekly")) |win| try list.append(arena, win);
        };
    };
    if (parsed.object.get("additional_rate_limits")) |extra| if (extra == .array) {
        for (extra.array.items) |item| {
            if (item != .object) continue;
            const name = util.strFieldObj(item.object, "name") orelse util.strFieldObj(item.object, "id") orelse "extra";
            if (item.object.get("primary_window")) |w| if (w == .object) {
                if (windowFrom(w.object, name)) |win| try list.append(arena, win);
            };
        }
    };
    return .{ .plan = plan, .windows = try list.toOwnedSlice(arena) };
}

pub fn parseRateLimitHeaders(arena: Allocator, remaining_req: ?[]const u8, limit_req: ?[]const u8, remaining_tok: ?[]const u8, limit_tok: ?[]const u8) !Report {
    var list: std.ArrayList(Window) = .empty;
    try addHeaderWindow(arena, &list, "requests", remaining_req, limit_req);
    try addHeaderWindow(arena, &list, "tokens/min", remaining_tok, limit_tok);
    const note: []const u8 = if (list.items.len == 0) "xAI weekly plan remaining is not a public API" else "API rate-limit headers (not SuperGrok weekly pool)";
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
    if (report.plan.len > 0) try w.print("  plan:      {s}\n", .{report.plan});
    for (report.windows) |win| {
        try w.print("  {s}: {d:.0}% remaining ({d:.0}% used)", .{ win.label, win.remaining_percent, win.used_percent });
        if (win.reset_after_seconds) |secs| if (secs > 0) try w.print(", resets in {s}", .{fmtReset(secs)});
        try w.writeByte('\n');
    }
    if (report.note.len > 0) try w.print("  {s}\n", .{report.note});
}

fn fmtReset(secs: i64) []const u8 {
    if (secs >= 86400) return "more than a day";
    if (secs >= 3600) return "a few hours";
    if (secs >= 60) return "under an hour";
    return "soon";
}

fn getJson(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, extra: []const std.http.Header) ![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var extra_buf: [8]std.http.Header = undefined;
    const n = @min(extra.len, extra_buf.len);
    @memcpy(extra_buf[0..n], extra[0..n]);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = extra_buf[0..n],
    });
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
    return try parseCodex(arena, body);
}

/// Probe api.x.ai for rate-limit headers. SuperGrok weekly % is not returned.
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
    var req = try client.request(.GET, try std.Uri.parse("https://api.x.ai/v1/models"), .{ .extra_headers = extra_buf[0..extra_n] });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = 0 };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.end();
    try req.connection.?.flush();
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

pub fn appendTo(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, xai_key: ?[]const u8, out: *Io.Writer) void {
    if (fetchCodex(io, gpa, arena, home)) |maybe| {
        if (maybe) |report| {
            out.writeAll("codex plan\n") catch return;
            renderWindows(out, report) catch return;
        }
    } else |_| {}
    if (fetchXaiHeaders(io, gpa, arena, home, xai_key)) |maybe| {
        if (maybe) |report| {
            out.writeAll("xai / grok\n") catch return;
            renderWindows(out, report) catch return;
        }
    } else |_| {}
}

test "remainingOf clamps used percent" {
    try std.testing.expectEqual(@as(f64, 42), remainingOf(58));
    try std.testing.expectEqual(@as(f64, 0), remainingOf(100));
    try std.testing.expectEqual(@as(f64, 100), remainingOf(0));
    try std.testing.expectEqual(@as(f64, 0), remainingOf(140));
}

test "parseCodex reads 5h and weekly windows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report = try parseCodex(arena_state.allocator(),
        \\{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":42,"reset_after_seconds":8100},"secondary_window":{"used_percent":18,"reset_after_seconds":345600}}}
    );
    try std.testing.expectEqualStrings("pro", report.plan);
    try std.testing.expectEqual(@as(usize, 2), report.windows.len);
    try std.testing.expectEqualStrings("5h", report.windows[0].label);
    try std.testing.expectEqual(@as(f64, 58), report.windows[0].remaining_percent);
    try std.testing.expectEqualStrings("weekly", report.windows[1].label);
    try std.testing.expectEqual(@as(f64, 82), report.windows[1].remaining_percent);
}

test "parseCodex omits missing windows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report = try parseCodex(arena_state.allocator(), "{}");
    try std.testing.expectEqual(@as(usize, 0), report.windows.len);
}

test "xAI header remaining is remaining/limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report = try parseRateLimitHeaders(arena_state.allocator(), "58", "100", "80", "100");
    try std.testing.expectEqual(@as(usize, 2), report.windows.len);
    try std.testing.expectEqual(@as(f64, 58), report.windows[0].remaining_percent);
    try std.testing.expectEqual(@as(f64, 80), report.windows[1].remaining_percent);
}
