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

const Registry = @import("mcp.zig").Registry;

fn fixtureRegistry(reg: *Registry, server: *Server) !void {
    const a = reg.arena();
    reg.servers = try a.dupe(*Server, &.{server});
    reg.tools = try a.dupe(@import("mcp.zig").Tool, &.{.{
        .server_index = 0,
        .server_name = "fixture",
        .original_name = "whoami",
        .qualified_name = "mcp__fixture__whoami",
        .description = "fixture identity",
        .input_schema = try parse(a, "{\"type\":\"object\"}"),
    }});
}

test "MCP recovery #1467: first call EOF returns restart guidance without replay" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var reg = Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const spawned = try spawnReplying(reg.arena(), reg.io, "read line; exit 0");
    try fixtureRegistry(&reg, spawned.server);
    const gate = @import("mcp_schema_gate.zig");
    gate.reset();
    defer gate.reset();
    _ = try gate.loadInto(reg.arena(), reg.tools, try parse(reg.arena(), "{\"tools\":[\"mcp__fixture__whoami\"]}"));
    var agent: @import("agent.zig").Agent = undefined;
    agent.arena = reg.arena();
    agent.sub = false;
    agent.registry = &reg;
    agent.tools_responses = "";
    agent.provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "fixture", .model = "grok-4.6", .context = 100_000 };
    try agent.ensureRootTools(.responses);
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "mcp__fixture__whoami") != null);
    const result = try reg.call(std.testing.allocator, "mcp__fixture__whoami", try parse(reg.arena(), "{}"));
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "McpClosed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "/mcp reconnect <server>") != null);
    try std.testing.expectEqual(@as(i64, 2), spawned.server.next_id);
    try std.testing.expectEqual(@as(usize, 0), (try reg.snapshotTools(reg.arena())).len);
    try std.testing.expect(reg.catalog_dirty.load(.acquire));
    try agent.ensureRootTools(.responses);
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "mcp__fixture__whoami") == null);
    try std.testing.expect(!reg.catalog_dirty.load(.acquire));
}

test "MCP recovery #1465: stale schema reports current registration and reload guidance" {
    var reg = Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const result = try reg.call(std.testing.allocator, "mcp__fixture__whoami", .null);
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "schema may be stale") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "reload its schema") != null);
    try std.testing.expect(reg.catalog_dirty.load(.acquire));
}

test "MCP recovery #1465: advertised loaded schema dispatches across consecutive calls" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gate = @import("mcp_schema_gate.zig");
    gate.reset();
    defer gate.reset();
    var reg = Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const spawned = try spawnReplying(reg.arena(), reg.io,
        \\read line; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}'
        \\read line; printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}'
        \\cat >/dev/null
    );
    try fixtureRegistry(&reg, spawned.server);
    const a = reg.arena();
    const loaded = try gate.loadInto(a, try reg.snapshotTools(a), try parse(a, "{\"tools\":[\"mcp__fixture__whoami\"]}"));
    try std.testing.expect(!loaded.is_error);
    try std.testing.expectEqual(@as(usize, 1), loaded.loaded);
    for (0..2) |_| {
        const result = try reg.call(std.testing.allocator, "mcp__fixture__whoami", try parse(a, "{}"));
        defer std.testing.allocator.free(result.text);
        try std.testing.expect(!result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.text, "ok") != null);
    }
}

test "MCP MRTR registry dispatch resolves input requests before rendering" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var reg = Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const spawned = try spawnReplying(reg.arena(), reg.io,
        \\read line; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"input_required","inputRequests":{"roots":{"method":"roots/list"}},"requestState":"state"}}'
        \\read line
        \\case "$line" in *inputResponses*requestState*) ;; *) exit 1 ;; esac
        \\printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"done"}]}}'
        \\cat >/dev/null
    );
    try fixtureRegistry(&reg, spawned.server);
    const result = try reg.call(std.testing.allocator, "mcp__fixture__whoami", try parse(reg.arena(), "{}"));
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqual(@as(i64, 3), spawned.server.next_id);
    try std.testing.expect(!reg.catalog_dirty.load(.acquire));
}

test "MCP recovery during MRTR withdraws tools without replay" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var reg = Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const spawned = try spawnReplying(reg.arena(), reg.io,
        \\read line; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"input_required","inputRequests":{"roots":{"method":"roots/list"}}}}'
        \\read line; exit 0
    );
    try fixtureRegistry(&reg, spawned.server);
    const result = try reg.call(std.testing.allocator, "mcp__fixture__whoami", try parse(reg.arena(), "{}"));
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "McpClosed") != null);
    try std.testing.expectEqual(@as(i64, 3), spawned.server.next_id);
    try std.testing.expectEqual(@as(usize, 0), (try reg.snapshotTools(reg.arena())).len);
    try std.testing.expect(reg.catalog_dirty.load(.acquire));
}

test "MCP recovery #1523: after a sibling call closes the connection, later calls and loads name the closed service" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var reg = Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    const spawned = try spawnReplying(reg.arena(), reg.io, "read line; exit 0");
    try fixtureRegistry(&reg, spawned.server);
    const a = reg.arena();
    var both: std.ArrayList(@import("mcp.zig").Tool) = .empty;
    try both.appendSlice(a, reg.tools);
    var search = reg.tools[0];
    search.original_name = "search";
    search.qualified_name = "mcp__fixture__search";
    try both.append(a, search);
    reg.tools = both.items;
    const call_mod = @import("mcp_call.zig");
    try std.testing.expect(call_mod.unavailableLoad(&reg, a, try parse(a, "{\"tools\":[\"mcp__fixture__search\"]}")) == null);

    const first = try reg.call(std.testing.allocator, "mcp__fixture__whoami", try parse(a, "{}"));
    defer std.testing.allocator.free(first.text);
    try std.testing.expect(std.mem.indexOf(u8, first.text, "McpClosed") != null);
    // The sibling in the same batch reports the same closed service, not an
    // unregistered tool with a stale schema.
    const sibling = try reg.call(std.testing.allocator, "mcp__fixture__search", try parse(a, "{}"));
    defer std.testing.allocator.free(sibling.text);
    try std.testing.expect(sibling.is_error);
    try std.testing.expect(std.mem.indexOf(u8, sibling.text, "closed or failed earlier in this session (McpClosed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sibling.text, "not registered") == null);
    try std.testing.expectEqual(@as(i64, 2), spawned.server.next_id); // nothing more was sent

    // Loading its schema now names the unavailable service instead of enabling it.
    const by_tool = call_mod.unavailableLoad(&reg, a, try parse(a, "{\"tools\":[\"mcp__fixture__search\"]}")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, by_tool, "MCP service fixture is unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_tool, "McpClosed") != null);
    try std.testing.expect(call_mod.unavailableLoad(&reg, a, try parse(a, "{\"server\":\"fixture\"}")) != null);
    try std.testing.expect(call_mod.unavailableLoad(&reg, a, try parse(a, "{\"tools\":[\"mcp__other__x\"]}")) == null);
}

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

test "probeStdio (#327): the DEFAULT deadline covers a cold-starting server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The reported symptom itself, and the one no amount of labelling fixed:
    // the deadline has to be survivable by a child that is still booting. A
    // second concurrent codedb-pro answers its first request in ~1.5s; this
    // fixture stands in for it at 1.2s. Deliberately NO override of
    // `stdio_probe_timeout_ms` — the value under test is the shipped default,
    // which at 600ms classified this server (and so the auto-connected
    // companion, on every single run) as legacy for the whole session.
    try std.testing.expect(mcp_rpc.stdio_probe_timeout_ms >= 3_000);

    var spawned = try spawnReplying(a, io,
        \\read line; sleep 1.2; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"]}}'; cat >/dev/null
    );
    defer mcp_stdio.stopChild(io, &spawned.child);

    try std.testing.expectEqual(mcp_rpc.StdioProbeOutcome.modern, try mcp_rpc.probeStdio(spawned.server, a, io));
    try std.testing.expect(spawned.server.probe_fallback == null);
}

test "request: a mid-call form elicitation is declined and the call still completes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // First JSON-RPC id is 1 (`Server.next_id`). The fixture emits a form
    // elicitation, then the tools/call result only after it reads the decline.
    var spawned = try spawnReplying(a, io,
        \\read line
        \\printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"elicitation/create","params":{"message":"Inspect app state","requestedSchema":{"type":"object","properties":{}}}}'
        \\read reply
        \\case "$reply" in *'"action":"decline"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}' ;; esac
        \\cat >/dev/null
    );
    defer mcp_stdio.stopChild(io, &spawned.child);
    spawned.server.era = .legacy;
    spawned.server.initialized = true;
    const resp = try mcp_rpc.request(spawned.server, a, "{\"name\":\"js\",\"arguments\":{}}", "tools/call", "js");
    try std.testing.expect(resp.object.get("result").?.object.get("ok").?.bool);
}
