//! ADR 0358: a child that ends failed or cancelled says why on its terminal
//! ACP frame, in every mode that has one; a completed child's frames are the
//! bytes they were before the reason existed (fixtures captured from the
//! unmodified writers).

const std = @import("std");
const Io = std.Io;
const live = @import("acp_subagent_live.zig");
const subagent_reason = @import("subagent_reason.zig");

const progress_completed_fixture =
    \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"parent","update":{"sessionUpdate":"tool_call_update","toolCallId":"spawn-1","title":"Scout · reader-model","content":[{"type":"content","content":{"type":"text","text":""}}],"_meta":{"graff/subagent":{"sessionId":"sa-001-scout","name":"Scout","state":"running","provider":"fixture","model":"reader-model"}}}}}
    \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"parent","update":{"sessionUpdate":"tool_call_update","toolCallId":"spawn-1","title":"Scout · reader-model","content":[{"type":"content","content":{"type":"text","text":"✓ finished"}}],"_meta":{"graff/subagent":{"sessionId":"sa-001-scout","name":"Scout","state":"completed","provider":"fixture","model":"reader-model"}}}}}
++ "\n";
const draft_completed_fixture =
    \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"parent","update":{"sessionUpdate":"subagent_update","subagentSessionId":"sa-001-scout","state":"completed","_meta":{"graff/parentToolCallId":"spawn-1"}}}}
++ "\n";
const background_completed_fixture =
    \\{"jsonrpc":"2.0","method":"graff/subagent_event","params":{"parentSessionId":"parent","subagentSessionId":"sa-001-scout","parentToolCallId":"spawn-1","seq":0,"event":{"type":"spawn","name":"Scout · reader-model","task":"Inspect the parser","provider":"fixture","model":"reader-model"}}}
    \\{"jsonrpc":"2.0","method":"graff/subagent_event","params":{"parentSessionId":"parent","subagentSessionId":"sa-001-scout","parentToolCallId":"spawn-1","seq":1,"event":{"type":"terminal","state":"completed"}}}
++ "\n";

const quota_detail = "openai 429: rate limited, try again later";
const quota_reason = quota_detail ++ " [quota/rate-limit failure, 3 attempts]";

fn failedWhy() subagent_reason.Reason {
    var r: subagent_reason.Reason = .{};
    const report: anyerror![]const u8 = error.Unexpected;
    r.record("failed", report, quota_detail, 3);
    return r;
}

fn lastLine(wire: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, wire, "\n");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return trimmed[start..];
}

fn field(v: std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = v;
    for (path) |key| {
        if (cur != .object) return null;
        cur = cur.object.get(key) orelse return null;
    }
    return cur;
}

fn str(v: std.json.Value, path: []const []const u8) ?[]const u8 {
    const got = field(v, path) orelse return null;
    return if (got == .string) got.string else null;
}

fn progressRun(out: *Io.Writer, outcome: []const u8, why: ?subagent_reason.Why) void {
    const io = std.testing.io;
    var output_lock: Io.Mutex = .init;
    var state: live.State = .{ .out = out, .parent = "parent", .output_lock = &output_lock, .mode = .progress };
    live.install(io, &state);
    defer live.uninstall(io);
    var child: live.ChildSink = .{ .id = "sa-001-scout", .io = io, .progress = .{ .parent_call_id = "spawn-1", .child_id = "sa-001-scout", .name = "Scout", .provider = "fixture", .model = "reader-model" } };
    child.startProgress();
    child.finishProgress(outcome, why);
}

fn draftRun(out: *Io.Writer, outcome: []const u8, why: ?subagent_reason.Why) void {
    const io = std.testing.io;
    var output_lock: Io.Mutex = .init;
    var state: live.State = .{ .out = out, .parent = "parent", .output_lock = &output_lock };
    live.install(io, &state);
    defer live.uninstall(io);
    live.finish(io, "sa-001-scout", outcome, why, "spawn-1");
}

fn backgroundRun(out: *Io.Writer, outcome: []const u8, why: ?subagent_reason.Why) !void {
    const io = std.testing.io;
    var output_lock: Io.Mutex = .init;
    var bg: live.BackgroundState = .{ .out = out, .output_lock = &output_lock };
    live.installBackground(io, &bg);
    defer live.uninstallBackground(io);
    live.configureBackground(io, "parent", true);
    const handle = live.announceBackground(std.testing.allocator, io, "sa-001-scout", "Scout", "Inspect the parser", "spawn-1", "fixture", "reader-model") orelse return error.NotAnnounced;
    defer std.testing.allocator.free(handle.parent);
    live.finishBackground(io, handle, "sa-001-scout", 1, outcome, why);
}

test "progress: a failed child's last row carries the reason in graff/subagent" {
    var buffer: [16384]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const why = failedWhy();
    progressRun(&out, "failed", why.why());
    const wire = out.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lastLine(wire), .{});
    defer parsed.deinit();
    const meta = &[_][]const u8{ "params", "update", "_meta", "graff/subagent" };
    try std.testing.expectEqualStrings("failed", str(parsed.value, meta ++ &[_][]const u8{"state"}).?);
    try std.testing.expectEqualStrings(quota_reason, str(parsed.value, meta ++ &[_][]const u8{"reason"}).?);
    try std.testing.expectEqualStrings("quota", str(parsed.value, meta ++ &[_][]const u8{"failureKind"}).?);
    // The running row before it is unchanged, and no row flips the call's status.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wire, "\"reason\""));
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"status\"") == null);
}

test "progress: a completed child's rows are byte-for-byte unchanged" {
    var buffer: [16384]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var why: subagent_reason.Reason = .{};
    why.record("completed", "the report", null, 1);
    progressRun(&out, "completed", why.why());
    try std.testing.expectEqualStrings(progress_completed_fixture, out.buffered());
}

test "draft: the failed subagent_update carries the reason; cancelled says cancelled" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const why = failedWhy();
    draftRun(&out, "failed", why.why());
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lastLine(out.buffered()), .{});
        defer parsed.deinit();
        const update = &[_][]const u8{ "params", "update" };
        try std.testing.expectEqualStrings("subagent_update", str(parsed.value, update ++ &[_][]const u8{"sessionUpdate"}).?);
        try std.testing.expectEqualStrings("failed", str(parsed.value, update ++ &[_][]const u8{"state"}).?);
        try std.testing.expectEqualStrings("spawn-1", str(parsed.value, update ++ &[_][]const u8{ "_meta", "graff/parentToolCallId" }).?);
        try std.testing.expectEqualStrings(quota_reason, str(parsed.value, update ++ &[_][]const u8{ "_meta", "graff/subagent", "reason" }).?);
        try std.testing.expectEqualStrings("quota", str(parsed.value, update ++ &[_][]const u8{ "_meta", "graff/subagent", "failureKind" }).?);
    }
    out = .fixed(&buffer);
    var stopped: subagent_reason.Reason = .{};
    stopped.record("cancelled", "a partial report", null, 1);
    draftRun(&out, "cancelled", stopped.why());
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lastLine(out.buffered()), .{});
    defer parsed.deinit();
    const meta = &[_][]const u8{ "params", "update", "_meta", "graff/subagent" };
    try std.testing.expectEqualStrings("cancelled", str(parsed.value, &.{ "params", "update", "state" }).?);
    try std.testing.expectEqualStrings("Interrupted [cancelled failure, 1 attempt]", str(parsed.value, meta ++ &[_][]const u8{"reason"}).?);
    try std.testing.expectEqualStrings("cancelled", str(parsed.value, meta ++ &[_][]const u8{"failureKind"}).?);
}

test "draft: a completed subagent_update is byte-for-byte unchanged" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    draftRun(&out, "completed", null);
    try std.testing.expectEqualStrings(draft_completed_fixture, out.buffered());
}

test "background: a failed detached child's terminal event carries the reason" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const why = failedWhy();
    try backgroundRun(&out, "failed", why.why());
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lastLine(out.buffered()), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("graff/subagent_event", str(parsed.value, &.{"method"}).?);
    const event = &[_][]const u8{ "params", "event" };
    try std.testing.expectEqualStrings("terminal", str(parsed.value, event ++ &[_][]const u8{"type"}).?);
    try std.testing.expectEqualStrings("failed", str(parsed.value, event ++ &[_][]const u8{"state"}).?);
    try std.testing.expectEqualStrings(quota_reason, str(parsed.value, event ++ &[_][]const u8{"reason"}).?);
    try std.testing.expectEqualStrings("quota", str(parsed.value, event ++ &[_][]const u8{"failureKind"}).?);
}

test "background: a completed terminal event is byte-for-byte unchanged" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try backgroundRun(&out, "completed", null);
    try std.testing.expectEqualStrings(background_completed_fixture, out.buffered());
}

test "an empty report fails with a reason and no failureKind" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var why: subagent_reason.Reason = .{};
    why.record("failed", "", null, 1);
    try backgroundRun(&out, "failed", why.why());
    const line = lastLine(out.buffered());
    try std.testing.expect(std.mem.indexOf(u8, line, "\"state\":\"failed\",\"reason\":\"" ++ subagent_reason.no_report ++ "\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "failureKind") == null);
}
