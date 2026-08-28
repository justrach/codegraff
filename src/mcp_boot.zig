//! MCP registry boot: config load + the server connect fan-out, split from
//! mcp.zig under the 600-line ceiling (#123). The fan-out is the point: each
//! server's handshake is a network or process round trip, so connecting them
//! serially charged every startup the SUM of the latencies. They now run
//! concurrently (one `io.concurrent` task per server — `io.async` can run
//! inline and would serialize again) and merge in config order, so the
//! resulting tool list is identical to the serial build — only the wait is
//! shorter: max(latency) instead of sum(latency).
//!
//! Interactive `--yolo` sets `defer_join`: tasks start immediately but the
//! REPL prompt is not blocked. `joinBeforeRequest` merges them on the *second*
//! model call (ADR 0035) so the first turn is not charged the handshake.
//! `joinPending` still blocks for `/mcp` and teardown.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const mcp_config = @import("mcp_config.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_teardown = @import("mcp_teardown.zig");

const Registry = mcp.Registry;

/// One server's connect attempt. The server record and its tools live in a
/// PER-TASK arena — the registry arena is not thread-safe — and the arena
/// travels with the outcome so the registry can free it at deinit, after the
/// transports referencing it are torn down.
pub const StartOutcome = struct {
    server: ?*mcp_rpc.Server = null,
    tools: []mcp.Tool = &.{},
    arena_state: ?std.heap.ArenaAllocator = null,
};

const StartCtx = struct {
    gpa: Allocator,
    io: Io,
    home: []const u8,
    show_diagnostics: bool,
    stdio_probe: bool,
};

fn startServerTask(ctx: StartCtx, name: []const u8, cfg: std.json.ObjectMap) StartOutcome {
    var outcome: StartOutcome = .{};
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    const a = arena_state.allocator();
    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    // Task-local Registry: only gpa/io/home/flags are read by startServer.
    // Must not point at init()'s stack `reg` — that dies when defer_join returns.
    var tmp: Registry = .{
        .gpa = ctx.gpa,
        .io = ctx.io,
        .home = ctx.home,
        .arena_state = std.heap.ArenaAllocator.init(ctx.gpa),
        .stdio_probe = ctx.stdio_probe,
        .show_diagnostics = ctx.show_diagnostics,
    };
    defer tmp.arena_state.deinit();
    tmp.startServer(a, &servers, &tools, name, cfg) catch |err| {
        if (ctx.show_diagnostics) std.debug.print("  [mcp:{s}] failed to start: {t}\n", .{ name, err });
        arena_state.deinit();
        return outcome;
    };
    outcome.server = servers.items[0];
    outcome.tools = tools.items;
    outcome.arena_state = arena_state;
    return outcome;
}
/// Load the workspace `.mcp.json` merged with the user-level global config,
/// then handshake every server CONCURRENTLY. Returns null (no error) when
/// neither file exists — MCP is optional. `global_path` is borrowed: it must
/// outlive the registry, which re-reads it on `/mcp trust`.
/// `defer_join` starts the handshakes but returns before they finish.
pub fn init(gpa: Allocator, io: Io, config_path: []const u8, global_path: ?[]const u8, home: []const u8, show_diagnostics: bool, environ_map: anytype, defer_join: bool) !?Registry {
    var reg: Registry = .{
        .gpa = gpa,
        .io = io,
        .home = home,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .stdio_probe = if (environ_map.get("GRAFF_MCP_PROBE")) |v| !std.mem.eql(u8, v, "0") else true,
        .show_diagnostics = show_diagnostics,
        .global_config_path = global_path,
        .global_is_override = mcp_config.isEnvOverride(environ_map),
    };
    mcp_rpc.applyHandshakeTimeoutEnv(environ_map); // #275 GRAFF_MCP_HANDSHAKE_SECS + #327 GRAFF_MCP_PROBE_MS, on the same pass as the probe flag

    errdefer reg.deinit();
    const a = reg.arena();

    const merged = mcp_config.load(io, a, Io.Dir.cwd(), config_path, global_path, home, reg.global_is_override);
    if (!merged.found) {
        reg.arena_state.deinit(); // nothing was started; no transports to tear down
        return null;
    }

    // Collect the entries first, in config order: the fan-out consumes them
    // concurrently, and a hash-map iterator is not a thing tasks can share.
    const Entry = struct { name: []const u8, cfg: std.json.ObjectMap };
    var entries: std.ArrayList(Entry) = .empty;
    var it = merged.servers.iterator();
    while (it.next()) |entry| {
        if (@import("tool_surface.zig").skipOptionalServer(entry.key_ptr.*, environ_map)) continue;
        if (entry.value_ptr.* != .object) continue;
        try entries.append(a, .{ .name = try a.dupe(u8, entry.key_ptr.*), .cfg = entry.value_ptr.*.object });
    }

    const futures = try gpa.alloc(Io.Future(StartOutcome), entries.items.len);
    const started_names = try a.alloc([]const u8, entries.items.len);
    // concurrent, not async: io.async may run the handshake inline, so two
    // remote servers paid SUM(latency) instead of max(latency) at REPL start.
    // defer_join must not take that fallback — inline handshake is the TUI hang.
    const ctx = StartCtx{
        .gpa = gpa,
        .io = io,
        .home = home,
        .show_diagnostics = show_diagnostics,
        .stdio_probe = reg.stdio_probe,
    };
    var started: usize = 0;
    for (entries.items) |e| {
        const args = .{ ctx, e.name, e.cfg };
        if (io.concurrent(startServerTask, args)) |fut| {
            futures[started] = fut;
            started_names[started] = e.name;
            started += 1;
        } else |_| {
            if (defer_join) continue;
            futures[started] = io.async(startServerTask, args);
            started_names[started] = e.name;
            started += 1;
        }
    }
    if (defer_join) {
        if (started == 0) {
            gpa.free(futures);
            return reg;
        }
        if (started < futures.len) {
            const slim = try gpa.alloc(Io.Future(StartOutcome), started);
            @memcpy(slim, futures[0..started]);
            gpa.free(futures);
            reg.pending_starts = slim;
        } else {
            reg.pending_starts = futures;
        }
        reg.pending_names = started_names[0..started];
        return reg;
    }
    defer gpa.free(futures);
    mergeOutcomes(&reg, futures[0..started]);
    return reg;
}

/// True when `name` is already live or queued on a deferred boot.
pub fn alreadyStarting(reg: *const Registry, name: []const u8) bool {
    for (reg.servers) |s| if (std.mem.eql(u8, s.name, name)) return true;
    for (reg.pending_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn startCtx(reg: *const Registry) StartCtx {
    return .{
        .gpa = reg.gpa,
        .io = reg.io,
        .home = reg.home,
        .show_diagnostics = reg.show_diagnostics,
        .stdio_probe = reg.stdio_probe,
    };
}

/// Queue a stdio server onto `pending_starts` without waiting. Used by
/// companion auto-connect so first paint is not the handshake. If the
/// thread pool cannot take the task, skip — do not run `io.async` inline.
pub fn queueStdio(reg: *Registry, name: []const u8, command: []const u8, args: []const []const u8) void {
    if (alreadyStarting(reg, name)) return;
    const a = reg.arena();
    const n = a.dupe(u8, name) catch return;
    var cfg: std.json.ObjectMap = .empty;
    cfg.put(a, "command", .{ .string = a.dupe(u8, command) catch return }) catch return;
    var argv = std.json.Array.init(a);
    for (args) |arg| argv.append(.{ .string = a.dupe(u8, arg) catch return }) catch return;
    cfg.put(a, "args", .{ .array = argv }) catch return;
    const fut = reg.io.concurrent(startServerTask, .{ startCtx(reg), n, cfg }) catch return;
    appendPending(reg, fut, n);
}

fn appendPending(reg: *Registry, fut: Io.Future(StartOutcome), name: []const u8) void {
    const old = reg.pending_starts;
    const next = reg.gpa.alloc(Io.Future(StartOutcome), old.len + 1) catch return;
    @memcpy(next[0..old.len], old);
    next[old.len] = fut;
    if (old.len > 0) reg.gpa.free(old);
    reg.pending_starts = next;
    const a = reg.arena();
    const names = a.alloc([]const u8, reg.pending_names.len + 1) catch return;
    @memcpy(names[0..reg.pending_names.len], reg.pending_names);
    names[reg.pending_names.len] = name;
    reg.pending_names = names;
}

fn mergeOutcomes(reg: *Registry, futures: []Io.Future(StartOutcome)) void {
    const a = reg.arena();
    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    var task_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty;
    servers.appendSlice(a, reg.servers) catch {};
    tools.appendSlice(a, reg.tools) catch {};
    task_arenas.appendSlice(a, reg.task_arenas) catch {};
    for (futures) |*fut| {
        const outcome = fut.await(reg.io);
        const server = outcome.server orelse continue;
        // A companion (eager codedb-pro) or /mcp trust can connect this server
        // while its deferred start is still in flight. Appending the outcome
        // anyway advertises every tool twice, and a strict Responses endpoint
        // (xAI) rejects the whole request over one duplicate (#505). First
        // registration wins; tear the latecomer down but keep its arena in
        // task_arenas so its memory follows the normal teardown lifecycle.
        var already_connected = false;
        for (servers.items) |existing| {
            if (std.mem.eql(u8, existing.name, server.name)) {
                already_connected = true;
                break;
            }
        }
        if (already_connected) {
            mcp_rpc.deinitServer(server, reg.io, .init(reg.io, mcp_teardown.teardown_grace));
            if (outcome.arena_state) |ta| task_arenas.append(a, ta) catch {};
            continue;
        }
        const server_index = servers.items.len;
        servers.append(a, server) catch continue;
        for (outcome.tools) |*tool| tool.server_index = server_index;
        tools.appendSlice(a, outcome.tools) catch {};
        if (outcome.arena_state) |ta| task_arenas.append(a, ta) catch {};
    }
    reg.servers = a.dupe(*mcp_rpc.Server, servers.items) catch reg.servers;
    reg.tools = a.dupe(mcp.Tool, tools.items) catch reg.tools;
    reg.task_arenas = a.dupe(std.heap.ArenaAllocator, task_arenas.items) catch reg.task_arenas;
}

/// Pure policy for the first model call after a deferred MCP boot. The
/// handshake tasks are already running; waiting here is the delay before
/// any native tool can start. Skip once, then join.
pub fn firstRequestJoin(pending_len: usize, already_skipped: *bool) enum { none, skip, join } {
    if (pending_len == 0) return .none;
    if (!already_skipped.*) {
        already_skipped.* = true;
        return .skip;
    }
    return .join;
}

fn noteMcpDeferred(io: Io) void {
    const sink = @import("engine_sink.zig").hostedSink() orelse return;
    sink.emit(io, .{ .session_notice = .{
        .text = "MCP still connecting — native tools this turn",
        .tone = .dim,
    } });
}

/// First model call: do not wait for deferred MCP handshakes (ADR 0035).
/// Later requests, `/mcp`, and teardown still `joinPending`.
pub fn joinBeforeRequest(reg: *Registry) bool {
    switch (firstRequestJoin(reg.pending_starts.len, &reg.first_request_join_skipped)) {
        .none => return false,
        .skip => {
            noteMcpDeferred(reg.io);
            return false;
        },
        .join => return joinPending(reg),
    }
}

/// Await deferred startServer tasks and append them to the live registry
/// (companion servers may already be present). Idempotent. Returns true
/// when this call actually merged something, so the agent can rebuild catalogs.
pub fn joinPending(reg: *Registry) bool {
    if (reg.pending_starts.len == 0) return false;
    const t0 = Io.Timestamp.now(reg.io, .awake);
    const futures = reg.pending_starts;
    reg.pending_starts = &.{};
    reg.pending_names = &.{};
    mergeOutcomes(reg, futures);
    reg.gpa.free(futures);
    const waited = @max(0, t0.untilNow(reg.io, .awake).toMilliseconds());
    if (waited >= 80) {
        if (@import("engine_sink.zig").hostedSink()) |sink| {
            var buf: [80]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "MCP connect waited {d}ms", .{waited}) catch "";
            if (text.len > 0) sink.emit(reg.io, .{ .session_notice = .{ .text = text, .tone = .dim } });
        }
    }
    return true;
}

test "MCP boot fans server handshakes out with io.concurrent" {
    const src = @embedFile("mcp_boot.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "io.concurrent(startServerTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "io.async(startServerTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "defer_join") != null);
}

test "defer_join does not fall back to inline io.async" {
    const src = @embedFile("mcp_boot.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "if (defer_join) continue") != null);
}

test "alreadyStarting sees pending names before the handshake finishes" {
    const io = std.testing.io;
    var reg = Registry.empty(std.testing.allocator, io);
    defer reg.deinit();
    try std.testing.expect(!alreadyStarting(&reg, "codedbpro"));
    const pending = [_][]const u8{"codedbpro"};
    reg.pending_names = &pending;
    try std.testing.expect(alreadyStarting(&reg, "codedbpro"));
    try std.testing.expect(!alreadyStarting(&reg, "other"));
    reg.pending_names = &.{};
}

test "joinPending is a no-op on an empty registry" {
    const io = std.testing.io;
    var reg = Registry.empty(std.testing.allocator, io);
    defer reg.deinit();
    try std.testing.expect(!joinPending(&reg));
    try std.testing.expect(!joinBeforeRequest(&reg));
}

test "firstRequestJoin skips once, then joins" {
    var skipped = false;
    try std.testing.expectEqual(.none, firstRequestJoin(0, &skipped));
    try std.testing.expect(!skipped);
    try std.testing.expectEqual(.skip, firstRequestJoin(2, &skipped));
    try std.testing.expect(skipped);
    try std.testing.expectEqual(.join, firstRequestJoin(2, &skipped));
    try std.testing.expectEqual(.none, firstRequestJoin(0, &skipped));
}
