//! Minimal MCP (Model Context Protocol) client over stdio and Streamable HTTP.
//!
//! A config entry — from the workspace `.mcp.json`, from the user-level
//! `~/.codegraff/mcp.json`, or from the two merged (mcp_config.zig) — may
//! contain either `command`/`args` (a child process using newline-delimited
//! JSON-RPC on stdio) or `url` (JSON-RPC POSTs using MCP's Streamable HTTP
//! transport). Both run the initialize -> initialized -> tools/list handshake
//! and expose discovered tools to the agent.
//!
//! Concurrency: tool calls arrive from agent pool threads, but transport state
//! (stdio pipes, HTTP session IDs) is sequential, so every request/response
//! round trip holds `mutex`. MCP calls are rare relative to LLM calls, so
//! registry-wide serialization is fine.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_config = @import("mcp_config.zig"); // #345: .mcp.json merged with the user-level ~/.codegraff/mcp.json
const mcp_boot = @import("mcp_boot.zig"); // parallel connect fan-out; Registry.init re-exports it
const mcp_http = @import("mcp_http.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const mcp_teardown = @import("mcp_teardown.zig");
const shutdown_trace = @import("shutdown_trace.zig"); // #364: teardown phase stamps
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_cache = @import("mcp_cache.zig");
const util = @import("util.zig");
const vision = @import("vision.zig"); // #249: MCP image results become staged vision blocks
const renderContent = @import("mcp_content.zig").renderContent;

const rewriteOneOf = mcp_protocol.rewriteOneOf;
const HttpTransport = mcp_http.HttpTransport;
pub const validRemoteUrl = mcp_http.validRemoteUrl;
const Server = mcp_rpc.Server;
const Transport = mcp_rpc.Transport;
const deinitServer = mcp_rpc.deinitServer;
const initializeServer = mcp_rpc.initializeServer;
const request = mcp_rpc.request;

pub const Tool = struct {
    server_index: usize,
    original_name: []const u8, // name as the server knows it
    qualified_name: []const u8, // "mcp__<server>__<tool>" shown to the model
    description: []const u8,
    input_schema: Value, // arena-owned parsed JSON Schema
};

pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    home: []const u8,
    arena_state: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    servers: []*Server = &.{},
    tools: []Tool = &.{},
    /// Startup connection/failure lines are developer diagnostics, not normal REPL output.
    show_diagnostics: bool = false,
    /// The stdio spec's backward-compatibility SHOULD: a dual-era client
    /// probes `server/discover` before assuming legacy. ON by default;
    /// `GRAFF_MCP_PROBE=0` opts out.
    /// The cost was measured against the stdio server this repo actually
    /// ships with, timing to the "connected" line rather than to process
    /// exit: probe on and off are within run-to-run noise, because a legacy
    /// server either answers the unknown method with an error at once or
    /// closes stdout and is respawned. Only a server that SILENTLY IGNORES it
    /// pays the timeout above, and it pays it once per process.
    /// Only `Registry.init` reads the environment, so a `Registry.empty*`-
    /// constructed registry keeps this field default (true) and cannot be
    /// opted out of the probe by `GRAFF_MCP_PROBE=0` — the env var reaches
    /// only the config-file path.
    stdio_probe: bool = true,
    /// An image an MCP tool returned, waiting for the next turn to collect it
    /// (#249). Written under `mutex` by `call`, drained by
    /// `vision.mcpImageHandoff` — the registry cannot reach the agent itself.
    pending_image: ?vision.PendingImage = null,
    /// Whether the active model accepts image blocks. The registry cannot see
    /// the provider, so the same per-turn handoff refreshes it; false until it
    /// does, so a result explains the drop rather than promising an attachment.
    vision_capable: bool = false,
    /// Resolved user-level MCP config (`~/.codegraff/mcp.json` or the
    /// `GRAFF_MCP_CONFIG` override), borrowed from the caller. Null when there
    /// is no global config. Kept on the registry because `/mcp trust` re-reads
    /// it mid-session — including on the consent-declined path, where the
    /// registry came from `empty*` and `init` never ran, so session_start sets
    /// this field either way.
    global_config_path: ?[]const u8 = null,
    /// Per-server arenas from mcp_boot's parallel connect fan-out (the
    /// registry arena is not thread-safe, so each task allocated its own).
    /// Freed in deinit AFTER the transports referencing them are torn down.
    task_arenas: []std.heap.ArenaAllocator = &.{},
    /// Unjoined startServer futures from a deferred --yolo boot.
    pending_starts: []Io.Future(mcp_boot.StartOutcome) = &.{},
    /// First model call already declined to wait on `pending_starts` (ADR 0035).
    first_request_join_skipped: bool = false,

    pub fn arena(self: *Registry) Allocator {
        return self.arena_state.allocator();
    }

    /// Load the workspace `.mcp.json` merged with the user-level global config
    /// at `global_path` (see mcp_config.zig; project entries win on a name
    /// clash), where an entry holds either `command`/`args`/`env` or a
    /// Streamable HTTP `url`; handshake each server and collect their tools.
    /// Returns null (no error) when NEITHER file exists — MCP is optional.
    /// `global_path` is borrowed, not copied: it must outlive the registry,
    /// which re-reads it on `/mcp trust`.
    /// The fan-out lives in mcp_boot.zig (600-line ceiling): servers connect
    /// CONCURRENTLY and merge in config order, so startup pays the slowest
    /// handshake, not the sum of them.
    pub const init = mcp_boot.init;

    /// An empty registry (no config file present), so the harness can still
    /// accept servers added at runtime via `addServer`.
    pub fn empty(gpa: Allocator, io: Io) Registry {
        return emptyWithOAuthHome(gpa, io, "");
    }

    /// An empty registry that can load OAuth tokens rooted under `home`.
    pub fn emptyWithOAuthHome(gpa: Allocator, io: Io, home: []const u8) Registry {
        return .{ .gpa = gpa, .io = io, .home = home, .arena_state = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Spawn + handshake a server at runtime and append its tools. Returns the
    /// number of tools it exposed. The servers/tools slices are rebuilt (arena);
    /// callers must re-render their tool list afterward. Run between turns only
    /// (no tool calls in flight).
    pub fn addServer(reg: *Registry, name: []const u8, command: []const u8, args: []const []const u8) !usize {
        for (reg.servers) |server| if (std.mem.eql(u8, server.name, name)) return error.McpServerAlreadyConnected;
        const a = reg.arena();
        var servers: std.ArrayList(*Server) = .empty;
        try servers.appendSlice(a, reg.servers);
        var tools: std.ArrayList(Tool) = .empty;
        try tools.appendSlice(a, reg.tools);
        const before = tools.items.len;

        var cfg: std.json.ObjectMap = .empty;
        try cfg.put(a, "command", .{ .string = try a.dupe(u8, command) });
        var argv = std.json.Array.init(a);
        for (args) |arg| try argv.append(.{ .string = try a.dupe(u8, arg) });
        try cfg.put(a, "args", .{ .array = argv });

        try reg.startServer(a, &servers, &tools, try a.dupe(u8, name), cfg);
        reg.servers = try a.dupe(*Server, servers.items);
        reg.tools = try a.dupe(Tool, tools.items);
        return tools.items.len - before;
    }

    /// Connect a Streamable HTTP server at runtime. `headers` are copied into
    /// registry storage and sent on every request (for example Authorization).
    pub fn addRemoteServer(reg: *Registry, name: []const u8, url: []const u8, headers: []const std.http.Header) !usize {
        for (reg.servers) |server| if (std.mem.eql(u8, server.name, name)) return error.McpServerAlreadyConnected;
        const a = reg.arena();
        var servers: std.ArrayList(*Server) = .empty;
        try servers.appendSlice(a, reg.servers);
        var tools: std.ArrayList(Tool) = .empty;
        try tools.appendSlice(a, reg.tools);
        const before = tools.items.len;

        var cfg: std.json.ObjectMap = .empty;
        try cfg.put(a, "url", .{ .string = try a.dupe(u8, url) });
        if (headers.len > 0) {
            var header_obj: std.json.ObjectMap = .empty;
            for (headers) |header| try header_obj.put(a, try a.dupe(u8, header.name), .{ .string = try a.dupe(u8, header.value) });
            try cfg.put(a, "headers", .{ .object = header_obj });
        }

        try reg.startServer(a, &servers, &tools, try a.dupe(u8, name), cfg);
        reg.servers = try a.dupe(*Server, servers.items);
        reg.tools = try a.dupe(Tool, tools.items);
        return tools.items.len - before;
    }

    /// Connect any configured server not already running — the in-session
    /// equivalent of having started with `--yolo`, so a user who declined the
    /// startup consent prompt can opt in later without a restart. Reads the
    /// same merged project + global set `init` does, so a `~/.codegraff/mcp.json`
    /// entry is trusted here too. Replays the `init` connect path (so
    /// per-server `env` is preserved, which `addServer` drops), skipping
    /// servers already in the registry by name (idempotent: won't double-spawn
    /// an auto-activated muonry). Returns the number of servers newly
    /// connected. Caller must re-render its tool list. Run between turns only
    /// (no tool calls in flight).
    pub fn trustWorkspace(reg: *Registry, config_path: []const u8) !usize {
        const a = reg.arena();
        const merged = mcp_config.load(reg.io, a, Io.Dir.cwd(), config_path, reg.global_config_path, reg.home);

        var servers: std.ArrayList(*Server) = .empty;
        try servers.appendSlice(a, reg.servers);
        var tools: std.ArrayList(Tool) = .empty;
        try tools.appendSlice(a, reg.tools);
        const before = servers.items.len;

        var it = merged.servers.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (entry.value_ptr.* != .object) continue;
            // Already connected (auto-activated muonry, or a prior /mcp trust)? skip.
            var present = false;
            for (reg.servers) |s| if (std.mem.eql(u8, s.name, name)) {
                present = true;
                break;
            };
            if (present) continue;
            reg.startServer(a, &servers, &tools, try a.dupe(u8, name), entry.value_ptr.*.object) catch |err| {
                if (reg.show_diagnostics) std.debug.print("  [mcp:{s}] failed to start: {t}\n", .{ name, err });
            };
        }
        reg.servers = try a.dupe(*Server, servers.items);
        reg.tools = try a.dupe(Tool, tools.items);
        return servers.items.len - before;
    }

    /// How many configured MCP servers are NOT yet connected — drives the
    /// `/mcp trust` discoverability hint. Mirrors `trustWorkspace`'s
    /// skip-by-name logic over the same merged (project + global) set;
    /// best-effort (any read/parse failure contributes nothing).
    pub fn pendingWorkspace(reg: *Registry, config_path: []const u8) usize {
        const a = reg.arena();
        const merged = mcp_config.load(reg.io, a, Io.Dir.cwd(), config_path, reg.global_config_path, reg.home);
        var n: usize = 0;
        var it = merged.servers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            var present = false;
            for (reg.servers) |s| if (std.mem.eql(u8, s.name, entry.key_ptr.*)) {
                present = true;
                break;
            };
            if (!present) n += 1;
        }
        return n;
    }

    /// Number of tools a given server (by index) contributed — for `/mcp`.
    pub fn toolCount(reg: *Registry, server_index: usize) usize {
        var n: usize = 0;
        for (reg.tools) |t| if (t.server_index == server_index) {
            n += 1;
        };
        return n;
    }
    /// Spawn a stdio child and wire up its transport. Factored out of
    /// `startServer` so the `GRAFF_MCP_PROBE` path can call it a second
    /// time: some legacy SDK servers close stdout on an unrecognized
    /// pre-`initialize` message (`server/discover`), and the only fix is a
    /// fresh process — the closed one can't be un-closed.
    fn spawnStdio(reg: *Registry, a: Allocator, argv: []const []const u8, env_map: ?*std.process.Environ.Map, cwd: ?[]const u8) !Transport {
        var child = try std.process.spawn(reg.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .environ_map = env_map,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        });
        errdefer mcp_stdio.stopChild(reg.io, &child);
        const in_buf = try a.alloc(u8, 64 * 1024);
        const out_buf = try a.alloc(u8, 1 << 20);
        return .{ .stdio = .{
            .child = child,
            .stdin_writer = child.stdin.?.writerStreaming(reg.io, in_buf),
            .stdout_reader = child.stdout.?.readerStreaming(reg.io, out_buf),
        } };
    }

    pub fn startServer(
        reg: *Registry,
        a: Allocator,
        servers: *std.ArrayList(*Server),
        tools: *std.ArrayList(Tool),
        name: []const u8,
        cfg: std.json.ObjectMap,
    ) !void {
        const command_v = cfg.get("command");
        const url_v = cfg.get("url");
        if ((command_v == null) == (url_v == null)) return error.BadMcpConfig;

        const server = try a.create(Server);
        // Hoisted out of the `else` branch below (rather than local to it)
        // so the GRAFF_MCP_PROBE respawn path -- which runs after this
        // if/else, once the era-detection dispatch below finds a closed
        // stdio child -- can spawn a fresh process with the same argv/env.
        var stdio_argv: std.ArrayList([]const u8) = .empty;
        var stdio_env_map: ?*std.process.Environ.Map = null;
        var stdio_cwd: ?[]const u8 = null;
        // Environ.Map owns its key/value copies with reg.gpa even though the
        // map struct itself is arena-backed. Spawn consumes the environment;
        // keep it through the possible probe respawn below, then release it.
        defer if (stdio_env_map) |map| map.deinit();
        if (url_v) |url| {
            if (url != .string) return error.BadMcpConfig;
            if (!validRemoteUrl(url.string)) return error.BadMcpUrl;

            var headers: std.ArrayList(std.http.Header) = .empty;
            var has_authorization = false;
            if (cfg.get("headers")) |headers_v| {
                if (headers_v != .object) return error.BadMcpConfig;
                var header_it = headers_v.object.iterator();
                while (header_it.next()) |entry| {
                    if (entry.value_ptr.* != .string) return error.BadMcpConfig;
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "authorization")) has_authorization = true;
                    try headers.append(a, .{
                        .name = try a.dupe(u8, entry.key_ptr.*),
                        .value = try a.dupe(u8, entry.value_ptr.*.string),
                    });
                }
            }
            server.* = .{
                .name = name,
                .transport = .{ .http = .{
                    .url = try a.dupe(u8, url.string),
                    .client = .{ .allocator = reg.gpa, .io = reg.io },
                    .headers = try a.dupe(std.http.Header, headers.items),
                    .oauth_home = if (!has_authorization and reg.home.len != 0) try a.dupe(u8, reg.home) else null,
                } },
            };
        } else {
            const command = if (command_v.? == .string) command_v.?.string else return error.BadMcpConfig;
            try stdio_argv.append(a, command);
            if (cfg.get("args")) |args| {
                if (args != .array) return error.BadMcpConfig;
                for (args.array.items) |arg| {
                    if (arg != .string) return error.BadMcpConfig;
                    try stdio_argv.append(a, arg.string);
                }
            }

            if (cfg.get("cwd")) |cwd| {
                if (cwd != .string or cwd.string.len == 0) return error.BadMcpConfig;
                stdio_cwd = cwd.string;
            }

            // Optional per-server env overlaid on the parent environment.
            if (cfg.get("env")) |env| {
                if (env != .object) return error.BadMcpConfig;
                const m = try a.create(std.process.Environ.Map);
                m.* = std.process.Environ.Map.init(reg.gpa);
                var env_it = env.object.iterator();
                while (env_it.next()) |entry| {
                    if (entry.value_ptr.* != .string) return error.BadMcpConfig;
                    try m.put(entry.key_ptr.*, entry.value_ptr.*.string);
                }
                stdio_env_map = m;
            }

            server.* = .{ .name = name, .transport = try spawnStdio(reg, a, stdio_argv.items, stdio_env_map, stdio_cwd) };
        }

        var registry_owns_server = false;
        errdefer if (!registry_owns_server) deinitServer(server, reg.io, .init(reg.io, mcp_teardown.teardown_grace)); // fresh window: not the exit path (#305)
        const server_index = servers.items.len;
        const tools_before = tools.items.len;
        errdefer tools.shrinkRetainingCapacity(tools_before);

        // A fresh process can reuse last session's tools/list (MCP 2026-07-28
        // CacheableResult). HTTP hits skip the network; call() initializes a
        // 2025-11-25 session on first tools/call. Live stdio still handshakes.
        const cache_key = mcp_cache.keyFor(a, cfg);
        const now_ms = util.unixMs(reg.io);
        const looked = mcp_cache.lookup(reg.io, a, reg.home, cache_key, now_ms);
        const era_hint = looked.era;
        var listed_result: ?Value = null;
        const tools_v: Value = if (looked.hit) |hit| blk: {
            server.era = hit.era;
            server.protocol_version = try a.dupe(u8, hit.protocol_version);
            // HTTP: advertise the cached catalog and let call() initialize.
            // stdio legacy: the child is already live, so complete the session.
            if (mcp_cache.handshakeOnCacheHit(hit.era, server.transport == .http)) {
                try mcp_rpc.initializeServer(server, a, a, reg.io);
            } else {
                server.initialized = hit.era == .modern;
            }
            break :blk hit.tools;
        } else blk: {
            const listed = switch (server.transport) {
                .http => try mcp_rpc.connectHttp(server, a, a, era_hint),
                .stdio => stdio_listed: {
                    if (!reg.stdio_probe) break :stdio_listed try mcp_rpc.connectStdio(server, a, a, reg.io);
                    switch (try mcp_rpc.probeStdioResilient(server, a, reg.io)) {
                        .modern => break :stdio_listed try mcp_rpc.finishModernStdio(server, a, a, reg.io),
                        .legacy => |reason| {
                            server.probe_fallback = reason;
                            break :stdio_listed try mcp_rpc.connectStdio(server, a, a, reg.io);
                        },
                        .closed => {
                            server.probe_fallback = .server_exited;
                            mcp_stdio.stopChild(reg.io, &server.transport.stdio.child);
                            server.transport = try spawnStdio(reg, a, stdio_argv.items, stdio_env_map, stdio_cwd);
                            break :stdio_listed try mcp_rpc.connectStdio(server, a, a, reg.io);
                        },
                    }
                },
            };
            const result_v = listed.object.get("result") orelse return error.BadMcpResponse;
            if (result_v != .object) return error.BadMcpResponse;
            const tv = result_v.object.get("tools") orelse return error.BadMcpResponse;
            if (tv != .array) return error.BadMcpResponse;
            listed_result = result_v;
            break :blk tv;
        };
        for (tools_v.array.items) |t| {
            if (t != .object) continue;
            const name_v = t.object.get("name") orelse continue;
            if (name_v != .string) continue;
            const orig = try a.dupe(u8, name_v.string);
            const qualified = try std.fmt.allocPrint(a, "mcp__{s}__{s}", .{ name, orig });
            // Prefer description; fall back to the 2025-06-18+ human-readable
            // title so a metadata-only tool isn't blank to the model.
            const desc = if (t.object.get("description")) |d| (if (d == .string) d.string else "") else if (t.object.get("title")) |ti| (if (ti == .string) ti.string else "") else "";
            var schema = t.object.get("inputSchema") orelse Value{ .object = .empty };
            try rewriteOneOf(a, &schema);
            // ...then lower any TOP-LEVEL combinator: Anthropic rejects the
            // whole request over one, so a single server advertising it would
            // break every turn (codedbpro's `replace`, "path or paths").
            try mcp_protocol.flattenTopLevel(a, &schema);
            try tools.append(a, .{
                .server_index = server_index,
                .original_name = orig,
                .qualified_name = qualified,
                .description = try a.dupe(u8, desc),
                .input_schema = schema,
            });
        }
        try servers.append(a, server);
        registry_owns_server = true;
        if (listed_result) |rv| mcp_cache.store(reg.io, a, reg.home, cache_key, server.era, server.protocol_version, rv, now_ms);
        const probe_note = if (server.probe_fallback) |reason| reason.note() else ""; // #327: a downgrade is never silent
        if (reg.show_diagnostics) std.debug.print("  [mcp:{s}] connected (mcp {s}) — {d} tool(s){s}\n", .{ name, server.protocol_version, tools_v.array.items.len, probe_note });
    }

    /// One shared window bounds the whole teardown: the loop is sequential, so
    /// a per-server grace cost N graces for N stalled peers (#305).
    /// Registry teardown for the EXIT path. If any transport was abandoned, a
    /// detached thread still holds this Io, so leave immediately rather than let
    /// a later defer tear that Io down underneath it (#325). Kept separate from
    /// `deinit` because tests and mid-session callers must never exit.
    pub fn deinitAtExit(reg: *Registry) void {
        shutdown_trace.mark("mcp-teardown"); // #364
        reg.deinit();
        mcp_teardown.exitIfAbandoned();
    }

    pub fn deinit(reg: *Registry) void {
        _ = mcp_boot.joinPending(reg);
        const budget: mcp_teardown.Budget = .init(reg.io, mcp_teardown.teardown_grace);
        for (reg.servers) |server| deinitServer(server, reg.io, budget);
        for (reg.task_arenas) |*ta| ta.deinit();
        reg.arena_state.deinit();
    }

    pub fn isMcp(name: []const u8) bool {
        return std.mem.startsWith(u8, name, "mcp__");
    }

    /// Invoke a tool by its qualified name. `input` is the model-supplied
    /// argument object. Returns result text (caller-owned, allocated with
    /// `out_alloc`) and whether the server reported an error.
    pub fn call(reg: *Registry, out_alloc: Allocator, qualified: []const u8, input: Value) !struct { text: []u8, is_error: bool } {
        const tool = for (reg.tools) |t| {
            if (std.mem.eql(u8, t.qualified_name, qualified)) break t;
        } else return .{ .text = try out_alloc.dupe(u8, "unknown MCP tool"), .is_error = true };

        const server = reg.servers[tool.server_index];

        // Build the tools/call params: {"name":..., "arguments":{...}}.
        var pw: Io.Writer.Allocating = .init(reg.gpa);
        defer pw.deinit();
        var s: std.json.Stringify = .{ .writer = &pw.writer };
        try s.beginObject();
        try s.objectField("name");
        try s.write(tool.original_name);
        try s.objectField("arguments");
        try s.write(input);
        try s.endObject();

        reg.mutex.lockUncancelable(reg.io);
        defer reg.mutex.unlock(reg.io);

        // Tool responses can be large and numerous; keep them out of the
        // session arena. Only the returned text is copied to `out_alloc`.
        var response_arena_state = std.heap.ArenaAllocator.init(reg.gpa);
        defer response_arena_state.deinit();
        const response_alloc = response_arena_state.allocator();
        if (!server.initialized) try initializeServer(server, response_alloc, reg.arena(), null);
        const resp = request(server, response_alloc, pw.writer.buffered(), "tools/call", tool.original_name) catch |err| switch (err) {
            // Streamable HTTP servers use 404 to expire a session. Re-run the
            // MCP handshake once, then retry the call without the stale ID.
            // A modern-era server never carries a session id in the first
            // place (mcp_http never sends/stores one for a modern request),
            // so this cannot structurally fire for one — the explicit guard
            // is defense-in-depth against a future refactor resurrecting a
            // re-handshake loop against a server that has no `initialize`.
            error.McpSessionExpired => retry: {
                if (server.era != .legacy) return err;
                try initializeServer(server, response_alloc, reg.arena(), null);
                break :retry try request(server, response_alloc, pw.writer.buffered(), "tools/call", tool.original_name);
            },
            else => return err,
        };

        if (resp.object.get("error")) |e| {
            // Protocol-level failure (unknown tool, invalid args, server
            // crash) — distinct from a tool that ran and *returned* an error
            // (isError below). Keep the JSON-RPC code: models retry better
            // when they can tell -32602 bad-params from a tool-side failure.
            const msg = if (e == .object) blk: {
                const m = e.object.get("message") orelse break :blk "MCP error";
                break :blk if (m == .string) m.string else "MCP error";
            } else "MCP error";
            const code: i64 = if (e == .object) blk: {
                const c = e.object.get("code") orelse break :blk 0;
                break :blk if (c == .integer) c.integer else 0;
            } else 0;
            const text = if (code != 0)
                try std.fmt.allocPrint(out_alloc, "MCP error {d}: {s}", .{ code, msg })
            else
                try out_alloc.dupe(u8, msg);
            return .{ .text = text, .is_error = true };
        }
        // A well-formed JSON-RPC reply has `result` xor `error`; `error` was
        // handled above. Guard a malformed server that sends neither (or a
        // non-object result) instead of force-unwrapping into a panic.
        const result_val = resp.object.get("result") orelse
            return .{ .text = try out_alloc.dupe(u8, "MCP response had neither result nor error"), .is_error = true };
        if (result_val != .object)
            return .{ .text = try out_alloc.dupe(u8, "MCP response result was not an object"), .is_error = true };
        const result = result_val.object;
        // resultType absent MUST read as "complete" (every server graff has
        // ever talked to). MRTR (inputRequests/inputResponses) is not
        // implemented — surface a clear error instead of silently returning
        // "" with is_error=false, which is what fell through here before.
        if (!mcp_protocol.resultIsComplete(result))
            return .{ .text = try out_alloc.dupe(u8, "MCP server returned an input_required result (MRTR); codegraff does not implement it"), .is_error = true };
        const is_error = if (result.get("isError")) |v| (v == .bool and v.bool) else false;

        var ow: Io.Writer.Allocating = .init(out_alloc);
        errdefer ow.deinit();
        if (result.get("content")) |content| try renderContent(&ow.writer, content, .{
            .arena = reg.arena(),
            .slot = &reg.pending_image,
            .label = qualified,
            .supports_vision = reg.vision_capable,
        });
        // 2025-06-18+ structured tool output: if the server sent only
        // structuredContent (no text blocks), surface it instead of "".
        if (ow.writer.buffered().len == 0) {
            if (result.get("structuredContent")) |sc| {
                var sw: std.json.Stringify = .{ .writer = &ow.writer };
                try sw.write(sc);
            }
        }
        return .{ .text = try ow.toOwnedSlice(), .is_error = is_error };
    }
};

test {
    _ = @import("mcp_cache.zig");
    _ = @import("mcp_boot.zig");
}
