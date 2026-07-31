//! Minimal MCP (Model Context Protocol) client over stdio and Streamable HTTP.
//!
//! A .mcp.json entry may contain either `command`/`args` (a child process using
//! newline-delimited JSON-RPC on stdio) or `url` (JSON-RPC POSTs using MCP's
//! Streamable HTTP transport). Both run the initialize -> initialized ->
//! tools/list handshake and expose discovered tools to the agent.
//!
//! Concurrency: tool calls arrive from agent pool threads, but transport state
//! (stdio pipes, HTTP session IDs) is sequential, so every request/response
//! round trip holds `mutex`. MCP calls are rare relative to LLM calls, so
//! registry-wide serialization is fine.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_http = @import("mcp_http.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const mcp_teardown = @import("mcp_teardown.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const smolify_manifest = @import("smolify_manifest.zig");

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
pub const smolify_url = "https://app.smol.ly/mcp";

pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    home: []const u8,
    arena_state: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    servers: []*Server = &.{},
    tools: []Tool = &.{},
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

    pub fn arena(self: *Registry) Allocator {
        return self.arena_state.allocator();
    }

    /// Load .mcp.json entries containing either `command`/`args`/`env` or a
    /// Streamable HTTP `url`, handshake each server, and collect their tools.
    /// Returns null
    /// (no error) when the config file is absent — MCP is optional.
    pub fn init(gpa: Allocator, io: Io, config_path: []const u8, home: []const u8, environ_map: anytype) !?Registry {
        const text = Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer gpa.free(text);

        var reg: Registry = .{
            .gpa = gpa,
            .io = io,
            .home = home,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .stdio_probe = if (environ_map.get("GRAFF_MCP_PROBE")) |v| !std.mem.eql(u8, v, "0") else true,
        };
        mcp_rpc.applyHandshakeTimeoutEnv(environ_map); // #275: GRAFF_MCP_HANDSHAKE_SECS, read on the same pass as the probe flag

        errdefer reg.deinit();
        const a = reg.arena();

        const parsed = try std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
        const servers_obj = (parsed.object.get("mcpServers") orelse return reg).object;

        var servers: std.ArrayList(*Server) = .empty;
        var tools: std.ArrayList(Tool) = .empty;

        var it = servers_obj.iterator();
        while (it.next()) |entry| {
            // The core Smolify name is pinned below and cannot be shadowed by
            // repository configuration.
            if (std.mem.eql(u8, entry.key_ptr.*, "smolify")) continue;
            const name = try a.dupe(u8, entry.key_ptr.*);
            const cfg = entry.value_ptr.*.object;
            reg.startServer(a, &servers, &tools, name, cfg) catch |err| {
                std.debug.print("  [mcp:{s}] failed to start: {t}\n", .{ name, err });
            };
        }

        reg.servers = try a.dupe(*Server, servers.items);
        reg.tools = try a.dupe(Tool, tools.items);
        return reg;
    }

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
        if (std.mem.eql(u8, name, "smolify")) return error.ReservedMcpServerName;
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
        if (std.mem.eql(u8, name, "smolify") and (!std.mem.eql(u8, url, smolify_url) or headers.len != 0)) return error.ReservedMcpServerName;
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

    /// Advertise bundled Smolify schemas without dialing the hosted endpoint.
    /// The first approved tool call performs the MCP handshake. Default mode
    /// is anonymous and public-read-only; full access also loads OAuth state.
    pub fn connectSmolify(reg: *Registry, full_access: bool) !usize {
        for (reg.servers) |server| if (std.mem.eql(u8, server.name, "smolify")) return 0;
        const a = reg.arena();
        var servers: std.ArrayList(*Server) = .empty;
        try servers.appendSlice(a, reg.servers);
        var tools: std.ArrayList(Tool) = .empty;
        try tools.appendSlice(a, reg.tools);
        const server = try a.create(Server);
        server.* = .{
            .name = "smolify",
            .transport = .{ .http = .{
                .url = smolify_url,
                .client = .{ .allocator = reg.gpa, .io = reg.io },
                .oauth_home = if (full_access and reg.home.len != 0) try a.dupe(u8, reg.home) else null,
            } },
            .initialized = false,
            .protocol_version = "on-demand",
        };
        var registry_owns_server = false;
        errdefer if (!registry_owns_server) deinitServer(server, reg.io, .init(reg.io, mcp_teardown.teardown_grace)); // fresh window: not the exit path (#305)
        const added = try smolify_manifest.appendTools(Tool, a, &tools, servers.items.len, full_access);
        try servers.append(a, server);
        const new_servers = try a.dupe(*Server, servers.items);
        const new_tools = try a.dupe(Tool, tools.items);
        reg.servers = new_servers;
        reg.tools = new_tools;
        registry_owns_server = true;
        return added;
    }

    /// Connect any workspace `.mcp.json` servers not already running — the
    /// in-session equivalent of having started with `--yolo`, so a user who
    /// declined the startup consent prompt can opt in later without a restart.
    /// Replays the `init` connect path (so per-server `env` is preserved, which
    /// `addServer` drops), skipping servers already in the registry by name
    /// (idempotent: won't double-spawn an auto-activated muonry). Returns the
    /// number of servers newly connected. Caller must re-render its tool list.
    /// Run between turns only (no tool calls in flight).
    pub fn trustWorkspace(reg: *Registry, config_path: []const u8) !usize {
        const a = reg.arena();
        const text = Io.Dir.cwd().readFileAlloc(reg.io, config_path, a, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        const parsed = try std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
        if (parsed != .object) return 0;
        const servers_v = parsed.object.get("mcpServers") orelse return 0;
        if (servers_v != .object) return 0;

        var servers: std.ArrayList(*Server) = .empty;
        try servers.appendSlice(a, reg.servers);
        var tools: std.ArrayList(Tool) = .empty;
        try tools.appendSlice(a, reg.tools);
        const before = servers.items.len;

        var it = servers_v.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.eql(u8, name, "smolify")) continue;
            if (entry.value_ptr.* != .object) continue;
            // Already connected (auto-activated muonry, or a prior /mcp trust)? skip.
            var present = false;
            for (reg.servers) |s| if (std.mem.eql(u8, s.name, name)) {
                present = true;
                break;
            };
            if (present) continue;
            reg.startServer(a, &servers, &tools, try a.dupe(u8, name), entry.value_ptr.*.object) catch |err| {
                std.debug.print("  [mcp:{s}] failed to start: {t}\n", .{ name, err });
            };
        }
        reg.servers = try a.dupe(*Server, servers.items);
        reg.tools = try a.dupe(Tool, tools.items);
        return servers.items.len - before;
    }

    /// How many workspace `.mcp.json` servers are NOT yet connected — drives
    /// the `/mcp trust` discoverability hint. Mirrors `trustWorkspace`'s
    /// skip-by-name logic; best-effort (any read/parse failure → 0).
    pub fn pendingWorkspace(reg: *Registry, config_path: []const u8) usize {
        const a = reg.arena();
        const text = Io.Dir.cwd().readFileAlloc(reg.io, config_path, a, .limited(1 << 20)) catch return 0;
        const parsed = std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) catch return 0;
        if (parsed != .object) return 0;
        const servers_v = parsed.object.get("mcpServers") orelse return 0;
        if (servers_v != .object) return 0;
        var n: usize = 0;
        var it = servers_v.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "smolify")) continue;
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
    fn spawnStdio(reg: *Registry, a: Allocator, argv: []const []const u8, env_map: ?*std.process.Environ.Map) !Transport {
        var child = try std.process.spawn(reg.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .environ_map = env_map,
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

    fn startServer(
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

            server.* = .{ .name = name, .transport = try spawnStdio(reg, a, stdio_argv.items, stdio_env_map) };
        }

        var registry_owns_server = false;
        errdefer if (!registry_owns_server) deinitServer(server, reg.io, .init(reg.io, mcp_teardown.teardown_grace)); // fresh window: not the exit path (#305)
        const server_index = servers.items.len;
        const tools_before = tools.items.len;
        errdefer tools.shrinkRetainingCapacity(tools_before);

        // Probe-then-fallback for HTTP (mcp_rpc.connectHttp), the unchanged
        // legacy handshake for stdio unless GRAFF_MCP_PROBE=1 opts into the
        // gated server/discover probe (mcp_rpc.probeStdio) — either way,
        // server.era and server.protocol_version are set by the time this
        // returns, and the model sees whichever revision was negotiated.
        const listed = switch (server.transport) {
            .http => try mcp_rpc.connectHttp(server, a, a),
            .stdio => stdio_listed: {
                if (!reg.stdio_probe) break :stdio_listed try mcp_rpc.connectStdio(server, a, a, reg.io);
                switch (try mcp_rpc.probeStdio(server, a, reg.io)) {
                    .modern => break :stdio_listed try mcp_rpc.finishModernStdio(server, a, a, reg.io),
                    .legacy => break :stdio_listed try mcp_rpc.connectStdio(server, a, a, reg.io),
                    .closed => {
                        // The probe write/read found a dead process (some
                        // legacy SDK servers exit on an unrecognized
                        // pre-initialize message) — respawn once and go
                        // straight to legacy on the fresh process, no
                        // second probe against a server that already
                        // proved it can't tolerate one.
                        mcp_stdio.stopChild(reg.io, &server.transport.stdio.child);
                        server.transport = try spawnStdio(reg, a, stdio_argv.items, stdio_env_map);
                        break :stdio_listed try mcp_rpc.connectStdio(server, a, a, reg.io);
                    },
                }
            },
        };
        const result_v = listed.object.get("result") orelse return error.BadMcpResponse;
        if (result_v != .object) return error.BadMcpResponse;
        const tools_v = result_v.object.get("tools") orelse return error.BadMcpResponse;
        if (tools_v != .array) return error.BadMcpResponse;
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
        std.debug.print("  [mcp:{s}] connected (mcp {s}) — {d} tool(s)\n", .{ name, server.protocol_version, tools_v.array.items.len });
    }

    /// One shared window bounds the whole teardown: the loop is sequential, so
    /// a per-server grace cost N graces for N stalled peers (#305).
    pub fn deinit(reg: *Registry) void {
        const budget: mcp_teardown.Budget = .init(reg.io, mcp_teardown.teardown_grace);
        for (reg.servers) |server| deinitServer(server, reg.io, budget);
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

        // result.content is an array of {type:"text", text:...} blocks.
        var ow: Io.Writer.Allocating = .init(out_alloc);
        errdefer ow.deinit();
        if (result.get("content")) |content| if (content == .array) {
            for (content.array.items) |block| {
                if (block == .object) if (block.object.get("text")) |txt| if (txt == .string) {
                    if (ow.writer.buffered().len > 0) try ow.writer.writeByte('\n');
                    try ow.writer.writeAll(txt.string);
                };
            }
        };
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
