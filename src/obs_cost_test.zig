//! usage/debug must not be a weaker view than the session cost tally.
//! Drives the shipped renderers against `pricing.g_cost` + named events.

const std = @import("std");
const Io = std.Io;

const obs = @import("obs.zig");
const pricing = @import("pricing.zig");
const engine_sink = @import("engine_sink.zig");

fn resetCost(io: Io) void {
    const c = &pricing.g_cost;
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    c.usd = 0;
    c.in_tokens = 0;
    c.cache_tokens = 0;
    c.cache_write_tokens = 0;
    c.out_tokens = 0;
    c.api_calls = 0;
    c.sub_calls = 0;
    c.unpriced_calls = 0;
    c.missing_usage_calls = 0;
    c.unreported_failed_attempts = 0;
}

fn renderCost(io: Io, buf: []u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    pricing.CostTally.render(pricing.g_cost.snap(io), &w) catch return "";
    return w.buffered();
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "usage/debug match the cost-tally renderer and add turn/decision extras" {
    const io = std.testing.io;
    resetCost(io);
    defer resetCost(io);
    obs.reset();
    defer obs.reset();
    obs.attach(io);

    pricing.g_cost.add(io, .priced, "gpt-5.5", 1000, 200, 0, 50);
    obs.turn(.completed);
    obs.note(.{ .tool_rejected = .{
        .name = "mcp__github__create_issue",
        .input = .null,
        .reason = "denied",
        .message = "sk-live-secret /Users/me/key",
    } });

    var cost_buf: [256]u8 = undefined;
    const cost = renderCost(io, &cost_buf);
    try std.testing.expect(cost.len > 0);

    var usage_buf: [512]u8 = undefined;
    var usage_w: Io.Writer = .fixed(&usage_buf);
    try obs.renderUsage(&usage_w);
    const usage = usage_w.buffered();

    var debug_buf: [2048]u8 = undefined;
    var debug_w: Io.Writer = .fixed(&debug_buf);
    try obs.renderHud(&debug_w);
    const debug = debug_w.buffered();

    try std.testing.expect(contains(usage, cost));
    try std.testing.expect(contains(debug, cost));
    try std.testing.expect(contains(debug, "turns"));
    try std.testing.expect(contains(debug, "cache"));
    try std.testing.expect(contains(debug, "deny"));
    try std.testing.expect(contains(debug, "completed"));
    try std.testing.expect(!contains(usage, "chars sent"));
    try std.testing.expect(!contains(debug, "chars sent"));
    try std.testing.expect(!contains(debug, "sk-live"));
    try std.testing.expect(!contains(debug, "/Users/me"));
    try std.testing.expect(!contains(debug, "create_issue"));
    try std.testing.expect(contains(debug, "mcp_tool"));

    pricing.g_cost.add(io, .sub, "gpt-5.5", 10, 0, 0, 10);
    pricing.g_cost.add(io, .unpriced, "no-such-model", 10, 0, 0, 10);
    var cost2_buf: [384]u8 = undefined;
    const cost2 = renderCost(io, &cost2_buf);
    try std.testing.expect(contains(cost2, "subscription"));
    try std.testing.expect(contains(cost2, "unpriced"));

    var usage2_buf: [512]u8 = undefined;
    var usage2_w: Io.Writer = .fixed(&usage2_buf);
    try obs.renderUsage(&usage2_w);
    const usage2 = usage2_w.buffered();

    var debug2_buf: [2048]u8 = undefined;
    var debug2_w: Io.Writer = .fixed(&debug2_buf);
    try obs.renderHud(&debug2_w);
    const debug2 = debug2_w.buffered();

    try std.testing.expect(contains(usage2, cost2));
    try std.testing.expect(contains(debug2, cost2));

    var otlp_buf: [2048]u8 = undefined;
    var otlp_w: Io.Writer = .fixed(&otlp_buf);
    var s: std.json.Stringify = .{ .writer = &otlp_w };
    try s.beginArray();
    try obs.writeOtlp(&s, 0);
    try s.endArray();
    const otlp = otlp_w.buffered();
    try std.testing.expect(contains(otlp, "graff.turn_completed"));
    try std.testing.expect(contains(otlp, "graff.tool_decision"));
    try std.testing.expect(contains(otlp, "mcp_tool"));
    try std.testing.expect(!contains(otlp, "sk-live"));
    try std.testing.expect(!contains(otlp, "/Users/me"));
    try std.testing.expect(!contains(otlp, "create_issue"));
}

test "live emit path fills HUD and OTLP like a real turn" {
    const io = std.testing.io;
    resetCost(io);
    defer resetCost(io);
    obs.reset();
    defer obs.reset();
    obs.attach(io);

    const sink = engine_sink.writerSink(null);
    sink.emit(io, .{ .session_banner = .{ .cwd = "/Users/secret/repo", .trace_path = "/tmp/trace.jsonl" } });
    obs.prompt(11, "gpt-5.5");
    pricing.g_cost.add(io, .priced, "gpt-5.5", 1000, 200, 0, 50);
    sink.emit(io, .{ .tool_call_started = .{ .name = "bash", .input = .null } });
    sink.emit(io, .{ .tool_call_finished = .{ .name = "bash", .text = "cat /etc/passwd", .is_error = false, .ms = 12 } });
    obs.turn(.completed);

    var cost_buf: [256]u8 = undefined;
    const cost = renderCost(io, &cost_buf);
    try std.testing.expect(cost.len > 0);

    var usage_buf: [512]u8 = undefined;
    var usage_w: Io.Writer = .fixed(&usage_buf);
    try obs.renderUsage(&usage_w);
    const usage = usage_w.buffered();

    var debug_buf: [2048]u8 = undefined;
    var debug_w: Io.Writer = .fixed(&debug_buf);
    try obs.renderHud(&debug_w);
    const debug = debug_w.buffered();

    try std.testing.expect(contains(usage, cost));
    try std.testing.expect(contains(debug, cost));
    try std.testing.expect(contains(debug, "turns      1"));
    try std.testing.expect(contains(debug, "user_prompt"));
    try std.testing.expect(contains(debug, "11ch"));
    try std.testing.expect(contains(debug, "tool_decision"));
    try std.testing.expect(!contains(debug, "offline"));
    try std.testing.expect(!contains(debug, "chars sent"));
    try std.testing.expect(!contains(debug, "/Users/secret"));
    try std.testing.expect(!contains(debug, "/etc/passwd"));
    try std.testing.expect(obs.snapshot().sessions == 1);
    try std.testing.expect(obs.snapshot().api_calls == 0); // cost tally, not the event ring
    try std.testing.expect(obs.snapshot().tool_calls == 1);

    var otlp_buf: [2048]u8 = undefined;
    var otlp_w: Io.Writer = .fixed(&otlp_buf);
    var s: std.json.Stringify = .{ .writer = &otlp_w };
    try s.beginArray();
    try obs.writeOtlp(&s, 0);
    try s.endArray();
    const otlp = otlp_w.buffered();
    try std.testing.expect(contains(otlp, "graff.session_start"));
    try std.testing.expect(contains(otlp, "graff.user_prompt"));
    try std.testing.expect(contains(otlp, "graff.turn_completed"));
    try std.testing.expect(contains(otlp, "graff.tool_decision"));
    try std.testing.expect(contains(otlp, "graff.tool_result"));
    try std.testing.expect(contains(otlp, "prompt_length"));
    try std.testing.expect(!contains(otlp, "/Users/secret"));
    try std.testing.expect(!contains(otlp, "/etc/passwd"));
}

fn expectUncertainSurfaces(with_success: bool) !void {
    const io = std.testing.io;
    resetCost(io);
    defer resetCost(io);
    obs.reset();
    defer obs.reset();
    obs.attach(io);
    pricing.g_cost.failedWithoutUsage(io, 1);
    if (with_success) pricing.g_cost.add(io, .priced, "gpt-5.5", 1000, 200, 0, 50);

    var expected_buf: [1024]u8 = undefined;
    const expected = renderCost(io, &expected_buf);
    try std.testing.expect(contains(expected, "known subtotal:"));
    try std.testing.expect(contains(expected, "1 failed request attempt(s) without usage"));
    const snapshot = pricing.g_cost.snap(io);
    try std.testing.expectEqual(@as(u64, if (with_success) 1 else 0), snapshot.api_calls);
    try std.testing.expectEqual(@as(u64, if (with_success) 50 else 0), snapshot.out_tokens);
    if (with_success) try std.testing.expect(snapshot.usd > 0);

    var repl_buf: [2048]u8 = undefined;
    var repl: Io.Writer = .fixed(&repl_buf);
    try @import("commands_misc.zig").renderSessionUsage(snapshot, &repl);
    var usage_buf: [2048]u8 = undefined;
    var usage: Io.Writer = .fixed(&usage_buf);
    try obs.renderUsage(&usage);
    var debug_buf: [4096]u8 = undefined;
    var debug: Io.Writer = .fixed(&debug_buf);
    try obs.renderHud(&debug);
    for ([_][]const u8{ repl.buffered(), usage.buffered(), debug.buffered() }) |text| {
        try std.testing.expect(contains(text, expected));
        try std.testing.expect(!contains(text, "no API calls yet"));
    }
}

test "usage surfaces preserve failed-only unknown accounting" {
    try expectUncertainSurfaces(false);
}

test "usage surfaces preserve unknown attempts alongside known successful usage" {
    try expectUncertainSurfaces(true);
}
