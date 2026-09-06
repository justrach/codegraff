//! Production-shaped model-call trajectories that sit above the transport adapter.

const std = @import("std");
const Io = std.Io;
const http_client = @import("http_client.zig");
const support = @import("http_client_integration_tests.zig");
const subagent = @import("subagent.zig");
const tools = @import("tools.zig");

test "background subagent tool recovers TLS and completes through agent_output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http_client.waitForReady(io);
    defer subagent.agentJobsReap(gpa, io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]support.Reply{.{ .body = support.chat_body }};
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(support.serveReplies, .{ io, &server, @as([]const support.Reply, &replies), &accepted });
    defer server_future.await(io);
    defer support.releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    const ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &runtime.client,
        .provider = support.provider(url),
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"description":"tls-background-child","prompt":"reply once","run_in_background":true}
    , .{});
    defer parsed.deinit();

    http_client.injectConstructionTlsForTest(0);
    const spawned = try subagent.execSubagent(ctx, parsed.value);
    defer gpa.free(spawned.text);
    try std.testing.expect(!spawned.is_error);
    const id_start = std.mem.indexOf(u8, spawned.text, "[agent ").? + "[agent ".len;
    const id_end = std.mem.indexOfScalarPos(u8, spawned.text, id_start, ' ').?;
    const id = try std.fmt.parseInt(u32, spawned.text[id_start..id_end], 10);

    const completed = try subagent.agentOutput(gpa, io, id, 1);
    defer gpa.free(completed.text);
    try std.testing.expect(!completed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, completed.text, "child-ok") != null);
    try std.testing.expectEqual(@as(u64, 1), runtime.recovery.stats().active_id);
    try std.testing.expectEqual(@as(usize, 1), accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().active_refs);
}

fn parseAgentId(text: []const u8) !u32 {
    const id_start = (std.mem.indexOf(u8, text, "[agent ") orelse return error.NoAgentId) + "[agent ".len;
    const id_end = std.mem.indexOfScalarPos(u8, text, id_start, ' ') orelse return error.NoAgentId;
    return std.fmt.parseInt(u32, text[id_start..id_end], 10);
}

// #753 happy path, issue-shaped: three background launches, collect, drop the
// live table (reap), collect again. Before the ledger, the second collect
// said "may never have started".
test "#753 backtest: three background handles replay after the live table is gone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ledger = @import("subagent_ledger.zig");
    ledger.reset(gpa);
    defer ledger.reset(gpa);

    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http_client.waitForReady(io);
    defer subagent.agentJobsReap(gpa, io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]support.Reply{
        .{ .body = support.chat_body },
        .{ .body = support.chat_body },
        .{ .body = support.chat_body },
    };
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(support.serveReplies, .{ io, &server, @as([]const support.Reply, &replies), &accepted });
    defer server_future.await(io);
    defer support.releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    const ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &runtime.client,
        .provider = support.provider(url),
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };

    var ids: [3]u32 = undefined;
    for (0..3) |i| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
            \\{"description":"scan","prompt":"reply once","run_in_background":true}
        , .{});
        defer parsed.deinit();
        http_client.injectConstructionTlsForTest(0);
        const spawned = try subagent.execSubagent(ctx, parsed.value);
        defer gpa.free(spawned.text);
        try std.testing.expect(!spawned.is_error);
        ids[i] = try parseAgentId(spawned.text);
    }

    for (ids) |id| {
        const first = try subagent.agentOutput(gpa, io, id, 1);
        defer gpa.free(first.text);
        try std.testing.expect(!first.is_error);
        try std.testing.expect(std.mem.indexOf(u8, first.text, "child-ok") != null);
    }
    try std.testing.expectEqual(@as(usize, 3), accepted.load(.acquire));

    // Session-end reap empties g_agent_jobs. The handles must still replay.
    subagent.agentJobsReap(gpa, io);
    for (ids) |id| {
        const again = try subagent.agentOutput(gpa, io, id, 0);
        defer gpa.free(again.text);
        try std.testing.expect(!again.is_error);
        try std.testing.expect(std.mem.indexOf(u8, again.text, "child-ok") != null);
        try std.testing.expect(std.mem.indexOf(u8, again.text, "may never have started") == null);
    }
}
