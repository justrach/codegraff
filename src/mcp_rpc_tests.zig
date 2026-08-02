//! #327 regression tests for the stdio `server/discover` probe: which
//! outcomes may downgrade a connection to the legacy protocol, and which must
//! not. Split out of mcp_rpc.zig (already near the 600-line ceiling) and
//! pulled in by its trailing `test { _ = @import("mcp_rpc_tests.zig"); }`.
//!
//! The bug these pin: every failure arm of `probeStdio` used to
//! `catch return .legacy`, so a probe that could not even be *spawned* was
//! indistinguishable from a server that answered "I only speak the legacy
//! protocol" — and the resulting downgrade was invisible in the connect line
//! and in `/mcp`.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Value = std.json.Value;

const mcp_rpc = @import("mcp_rpc.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const modern_protocol = @import("mcp_protocol.zig").modern_protocol;
const Server = mcp_rpc.Server;

fn parse(a: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, json, .{ .allocate = .alloc_always });
}

test "classifyStdioProbe: a modern supportedVersions list is the only path to .modern" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const modern = try parse(a,
        \\{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],"serverInfo":{"name":"fixture","version":"1"}}}
    );
    try std.testing.expectEqual(mcp_rpc.StdioProbeOutcome.modern, try mcp_rpc.classifyStdioProbe(modern));
}

test "classifyStdioProbe: a clean rejection falls back, and says which kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The server answered `server/discover` with a JSON-RPC error: it does
    // not speak the modern protocol. A legitimate, spec-sanctioned downgrade.
    const rejected = try parse(a,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
    );
    try std.testing.expectEqual(mcp_rpc.LegacyReason.rejected, (try mcp_rpc.classifyStdioProbe(rejected)).legacy);

    // It answered, but lists only pre-modern revisions.
    const old_only = try parse(a,
        \\{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2025-11-25","2025-06-18"]}}
    );
    try std.testing.expectEqual(mcp_rpc.LegacyReason.no_modern_version, (try mcp_rpc.classifyStdioProbe(old_only)).legacy);

    // An answer with no version list at all is still an answer, not a fault.
    const no_list = try parse(a,
        \\{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"fixture","version":"1"}}}
    );
    try std.testing.expectEqual(mcp_rpc.LegacyReason.no_modern_version, (try mcp_rpc.classifyStdioProbe(no_list)).legacy);
}

test "classifyStdioProbe (#327): a transport error propagates instead of downgrading" {
    // The regression in one line: a read that FAILED says nothing about the
    // server's protocol, so it must never be answered with `.legacy` — that
    // pinned the era for the whole process life with nothing to see.
    const failed: anyerror!Value = error.ReadFailed;
    try std.testing.expectError(error.ReadFailed, mcp_rpc.classifyStdioProbe(failed));
    const canceled: anyerror!Value = error.Canceled;
    try std.testing.expectError(error.Canceled, mcp_rpc.classifyStdioProbe(canceled));

    // `McpClosed` is the one error with a defined meaning: the child exited.
    // It stays a distinct outcome (the caller respawns), not a silent legacy.
    const closed: anyerror!Value = error.McpClosed;
    try std.testing.expectEqual(mcp_rpc.StdioProbeOutcome.closed, try mcp_rpc.classifyStdioProbe(closed));
}

test "GRAFF_MCP_PROBE_MS (#327): the deadline that decides the fallback is tunable" {
    const saved = mcp_rpc.stdio_probe_timeout_ms;
    defer mcp_rpc.stdio_probe_timeout_ms = saved;

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    // The measured #327 case: a server whose first answer takes ~1.5s is
    // modern, but 600ms says legacy. This is the way out of that.
    try env.put("GRAFF_MCP_PROBE_MS", "2500");
    mcp_rpc.applyProbeTimeoutEnv(&env);
    try std.testing.expectEqual(@as(i64, 2500), mcp_rpc.stdio_probe_timeout_ms);

    // Garbage and 0 leave the previous bound alone rather than disabling it.
    try env.put("GRAFF_MCP_PROBE_MS", "not-a-number");
    mcp_rpc.applyProbeTimeoutEnv(&env);
    try std.testing.expectEqual(@as(i64, 2500), mcp_rpc.stdio_probe_timeout_ms);
    try env.put("GRAFF_MCP_PROBE_MS", "0");
    mcp_rpc.applyProbeTimeoutEnv(&env);
    try std.testing.expectEqual(@as(i64, 2500), mcp_rpc.stdio_probe_timeout_ms);

    // Clamped, so a fat-fingered value cannot re-create the #275 hang.
    try env.put("GRAFF_MCP_PROBE_MS", "99999999");
    mcp_rpc.applyProbeTimeoutEnv(&env);
    try std.testing.expectEqual(@as(i64, 60_000), mcp_rpc.stdio_probe_timeout_ms);
}

/// A stdio child that answers the first line it is fed with `reply`, then
/// holds both pipes open so nothing races on teardown. The probe always uses
/// id 1 (`Server.next_id` starts there), so `reply` can be a canned line.
fn spawnReplying(a: std.mem.Allocator, io: Io, script: []const u8) !struct { child: std.process.Child, server: *Server } {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer mcp_stdio.stopChild(io, &child);
    const server = try a.create(Server);
    server.* = .{
        .name = "fixture",
        .transport = .{ .stdio = .{
            .child = child,
            .stdin_writer = child.stdin.?.writerStreaming(io, try a.alloc(u8, 4096)),
            .stdout_reader = child.stdout.?.readerStreaming(io, try a.alloc(u8, 4096)),
        } },
    };
    return .{ .child = child, .server = server };
}

test "probeStdio: a server that answers with a modern version list negotiates modern" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const saved = mcp_rpc.stdio_probe_timeout_ms;
    mcp_rpc.stdio_probe_timeout_ms = 10_000; // the classification is under test, not the deadline
    defer mcp_rpc.stdio_probe_timeout_ms = saved;

    var spawned = try spawnReplying(a, io,
        \\read line; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"]}}'; cat >/dev/null
    );
    defer mcp_stdio.stopChild(io, &spawned.child);

    try std.testing.expectEqual(mcp_rpc.StdioProbeOutcome.modern, try mcp_rpc.probeStdio(spawned.server, a, io));
    try std.testing.expect(spawned.server.probe_fallback == null);
}

test "probeStdio: a server that rejects server/discover falls back to legacy, with a reason" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const saved = mcp_rpc.stdio_probe_timeout_ms;
    mcp_rpc.stdio_probe_timeout_ms = 10_000;
    defer mcp_rpc.stdio_probe_timeout_ms = saved;

    var spawned = try spawnReplying(a, io,
        \\read line; printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}'; cat >/dev/null
    );
    defer mcp_stdio.stopChild(io, &spawned.child);

    const outcome = try mcp_rpc.probeStdio(spawned.server, a, io);
    try std.testing.expectEqual(mcp_rpc.LegacyReason.rejected, outcome.legacy);
    // Reported, not silent: the reason renders into the connect line / `/mcp`.
    try std.testing.expect(std.mem.indexOf(u8, outcome.legacy.note(), "rejected") != null);
}

test "probeStdio (#327): a probe that cannot be spawned errors instead of silently degrading" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Reads stdin so the probe write still succeeds; the failure under test is
    // graff's own, on the client side.
    var spawned = try spawnReplying(a, io, "cat >/dev/null");
    defer mcp_stdio.stopChild(io, &spawned.child);

    // An Io that refuses concurrency reproduces the exact arm that used to
    // read `select.concurrent(...) catch return .legacy`: no reader task, no
    // deadline task, and — before the fix — a permanent, invisible downgrade
    // of a server that was never even asked.
    const no_concurrency = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectError(error.McpProbeUnavailable, mcp_rpc.probeStdio(spawned.server, a, no_concurrency));
    try std.testing.expect(spawned.server.probe_fallback == null);
}

test "probeStdioResilient (#327): retries, then downgrades only with a visible reason" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var spawned = try spawnReplying(a, io, "cat >/dev/null");
    defer mcp_stdio.stopChild(io, &spawned.child);

    const no_concurrency = std.Io.Threaded.global_single_threaded.io();
    const outcome = try mcp_rpc.probeStdioResilient(spawned.server, a, no_concurrency);
    // Connecting still succeeds (never worse than before), but the era is
    // attributed to graff, not to the server, and it is printed.
    try std.testing.expectEqual(mcp_rpc.LegacyReason.probe_unavailable, outcome.legacy);
    try std.testing.expect(std.mem.indexOf(u8, outcome.legacy.note(), "graff could not run") != null);
    // Every reason renders something a user can read.
    for ([_]mcp_rpc.LegacyReason{ .rejected, .no_modern_version, .timeout, .probe_unavailable, .server_exited }) |reason| {
        try std.testing.expect(reason.note().len > 0);
    }
    try std.testing.expect(std.mem.indexOf(u8, mcp_rpc.LegacyReason.no_modern_version.note(), modern_protocol) != null);
}
