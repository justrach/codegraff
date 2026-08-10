//! MCP registry boot: config load + the server connect fan-out, split from
//! mcp.zig under the 600-line ceiling (#123). The fan-out is the point: each
//! server's handshake is a network or process round trip, so connecting them
//! serially charged every startup the SUM of the latencies. They now run
//! concurrently (one task per server) and merge in config order, so the
//! resulting tool list is identical to the serial build — only the wait is
//! shorter: max(latency) instead of sum(latency).

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const mcp_config = @import("mcp_config.zig");
const mcp_rpc = @import("mcp_rpc.zig");

const Registry = mcp.Registry;

/// One server's connect attempt. The server record and its tools live in a
/// PER-TASK arena — the registry arena is not thread-safe — and the arena
/// travels with the outcome so the registry can free it at deinit, after the
/// transports referencing it are torn down.
const StartOutcome = struct {
    server: ?*mcp_rpc.Server = null,
    tools: []mcp.Tool = &.{},
    arena_state: ?std.heap.ArenaAllocator = null,
};

fn startServerTask(reg: *Registry, name: []const u8, cfg: std.json.ObjectMap) StartOutcome {
    var outcome: StartOutcome = .{};
    var arena_state = std.heap.ArenaAllocator.init(reg.gpa);
    const a = arena_state.allocator();
    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    reg.startServer(a, &servers, &tools, name, cfg) catch |err| {
        if (reg.show_diagnostics) std.debug.print("  [mcp:{s}] failed to start: {t}\n", .{ name, err });
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
pub fn init(gpa: Allocator, io: Io, config_path: []const u8, global_path: ?[]const u8, home: []const u8, show_diagnostics: bool, environ_map: anytype) !?Registry {
    var reg: Registry = .{
        .gpa = gpa,
        .io = io,
        .home = home,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .stdio_probe = if (environ_map.get("GRAFF_MCP_PROBE")) |v| !std.mem.eql(u8, v, "0") else true,
        .show_diagnostics = show_diagnostics,
        .global_config_path = global_path,
    };
    mcp_rpc.applyHandshakeTimeoutEnv(environ_map); // #275 GRAFF_MCP_HANDSHAKE_SECS + #327 GRAFF_MCP_PROBE_MS, on the same pass as the probe flag

    errdefer reg.deinit();
    const a = reg.arena();

    const merged = mcp_config.load(io, a, Io.Dir.cwd(), config_path, global_path);
    if (!merged.found) {
        reg.arena_state.deinit(); // nothing was started; no transports to tear down
        return null;
    }

    // Collect the entries first, in config order: the fan-out consumes them
    // concurrently, and a hash-map iterator is not a thing tasks can share.
    // The core Smolify name is pinned and cannot be shadowed by repository or
    // user configuration.
    const Entry = struct { name: []const u8, cfg: std.json.ObjectMap };
    var entries: std.ArrayList(Entry) = .empty;
    var it = merged.servers.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "smolify")) continue;
        if (entry.value_ptr.* != .object) continue;
        try entries.append(a, .{ .name = try a.dupe(u8, entry.key_ptr.*), .cfg = entry.value_ptr.*.object });
    }

    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    var task_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty;

    const futures = try gpa.alloc(Io.Future(StartOutcome), entries.items.len);
    defer gpa.free(futures);
    for (entries.items, futures) |e, *fut| fut.* = io.async(startServerTask, .{ &reg, e.name, e.cfg });
    // Join in config order: every tool's server_index is rewritten to its
    // server's final slot, so the merged lists match the serial build exactly.
    for (futures) |*fut| {
        const outcome = fut.await(io);
        const server = outcome.server orelse continue;
        const server_index = servers.items.len;
        try servers.append(a, server);
        for (outcome.tools) |*t| t.server_index = server_index;
        try tools.appendSlice(a, outcome.tools);
        if (outcome.arena_state) |ta| try task_arenas.append(a, ta);
    }

    reg.servers = try a.dupe(*mcp_rpc.Server, servers.items);
    reg.tools = try a.dupe(mcp.Tool, tools.items);
    reg.task_arenas = try a.dupe(std.heap.ArenaAllocator, task_arenas.items);
    return reg;
}
