//! Unit tests for `plan_usage_live.zig`: Codex headers + WS `codex.rate_limits`,
//! Anthropic unified headers, Claude Agent `rate_limit_event`, and xAI headers.

const std = @import("std");
const live = @import("plan_usage_live.zig");
const util = @import("util.zig");

test "live codex headers and WS codex.rate_limits capture + credits" {
    live.resetForTest();
    defer live.resetForTest();
    const io = std.testing.io;
    const now_s = @divTrunc(util.unixMs(io), 1000);
    var reset_buf: [24]u8 = undefined;
    const reset_str = try std.fmt.bufPrint(&reset_buf, "{d}", .{now_s + 1800});
    live.noteHeaderList(io, "codex", "gpt-5", 200, &.{
        .{ .name = "x-codex-plan-type", .value = "pro" },
        .{ .name = "x-codex-credits-balance", .value = "12.50" },
        .{ .name = "x-codex-primary-window-minutes", .value = "300" },
        .{ .name = "x-codex-primary-used-percent", .value = "25" },
        .{ .name = "x-codex-primary-reset-at", .value = reset_str },
        .{ .name = "x-codex-codex_bengalfox-primary-used-percent", .value = "10" },
        .{ .name = "x-codex-codex_bengalfox-primary-window-minutes", .value = "300" },
    });
    live.noteWsFrame(io, "codex", "{\"type\":\"codex.rate_limits\",\"rate_limits\":{\"secondary\":{\"used_percent\":40,\"window_minutes\":10080,\"resets_at\":1800000000}}}");
    const snap = (try live.snapshot(io, std.testing.allocator, "codex")).?;
    defer snap.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pro", snap.plan.?);
    try std.testing.expectEqualStrings("12.50", snap.credits.?);
    try std.testing.expectEqual(@as(usize, 3), snap.windows.len);
    try std.testing.expectEqualStrings("Session (5h)", snap.windows[0].label);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), snap.windows[0].remaining_pct.?, 0.01);
    try std.testing.expectEqualStrings("GPT-5.3-Codex-Spark (5h)", snap.windows[1].label);
    try std.testing.expectEqualStrings("Week (7d)", snap.windows[2].label);
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), snap.windows[2].remaining_pct.?, 0.01);
}

test "anthropic headers, claude_agent rate_limit_event scaling, and fable block mask" {
    live.resetForTest();
    defer live.resetForTest();
    const io = std.testing.io;
    live.noteHeaderList(io, "anthropic", "claude-fable-5-2", 429, &.{
        .{ .name = "anthropic-ratelimit-unified-status", .value = "rejected" },
        .{ .name = "anthropic-ratelimit-unified-representative-claim", .value = "fable" },
        .{ .name = "anthropic-ratelimit-unified-5h-utilization", .value = "0.42" },
    });
    try std.testing.expect(live.isModelBlocked("anthropic", "claude-fable-5-2"));
    try std.testing.expect(!live.isModelBlocked("anthropic", "claude-opus-5-5"));
    const a_snap = (try live.snapshot(io, std.testing.allocator, "anthropic")).?;
    defer a_snap.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 58.0), a_snap.windows[0].remaining_pct.?, 0.01);
    live.noteHeaderList(io, "anthropic", "claude-fable-5-2", 200, &.{.{ .name = "anthropic-ratelimit-unified-status", .value = "allowed" }});
    try std.testing.expect(!live.isModelBlocked("anthropic", "claude-fable-5-2"));

    live.noteClaudeRateLimit(io, "claude-fable-5-2", .{ .status = "rejected", .rate_limit_type = "fable", .utilization = 1.0, .overage_status = "rejected" });
    try std.testing.expect(live.isModelBlocked("claude-agent", "claude-fable-5-2"));
    const c_snap = (try live.snapshot(io, std.testing.allocator, "claude-agent")).?;
    defer c_snap.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Fable", c_snap.windows[0].label);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c_snap.windows[0].remaining_pct.?, 0.01);
    live.noteClaudeRateLimit(io, "claude-fable-5-2", .{ .status = "allowed_warning", .rate_limit_type = "fable", .utilization = 0.85 });
    try std.testing.expect(!live.isModelBlocked("claude-agent", "claude-fable-5-2"));
}

test "xai response headers capture requests remaining pct" {
    live.resetForTest();
    defer live.resetForTest();
    const io = std.testing.io;
    live.noteHeaderList(io, "xai", "grok-4.7", 200, &.{
        .{ .name = "x-ratelimit-limit-requests", .value = "100" },
        .{ .name = "x-ratelimit-remaining-requests", .value = "75" },
        .{ .name = "x-ratelimit-reset-requests", .value = "1m30s" },
    });
    const snap = (try live.snapshot(io, std.testing.allocator, "xai")).?;
    defer snap.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Requests", snap.windows[0].label);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), snap.windows[0].remaining_pct.?, 0.01);
    try std.testing.expectEqual(@as(i64, 90), snap.windows[0].resets_in_s.?);
}
