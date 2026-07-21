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
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_oauth = @import("mcp_oauth.zig");

pub const Tool = struct {
    server_index: usize,
    original_name: []const u8, // name as the server knows it
    qualified_name: []const u8, // "mcp__<server>__<tool>" shown to the model
    description: []const u8,
    input_schema: Value, // arena-owned parsed JSON Schema
};

/// Recursively rewrite the JSON Schema keyword `oneOf` to `anyOf` (graff's
/// rewrite_one_of_to_any_of). OpenAI's tool-schema validator — including the
/// chatgpt.com /codex/responses endpoint — rejects `oneOf` outright with
/// "'oneOf' is not permitted"; `anyOf` is accepted by both OpenAI and
/// Anthropic and is equivalent for the discriminated unions MCP servers emit
/// in practice. When both keywords are present (rare, ambiguous to merge),
/// the existing `anyOf` wins and `oneOf` is dropped. Runs once per tool at
/// discovery, so the rendered tools JSON stays KV-cache-stable.
fn rewriteOneOf(a: Allocator, v: *Value) Allocator.Error!void {
    switch (v.*) {
        .object => |*obj| {
            if (obj.get("oneOf")) |branches| {
                if (obj.get("anyOf") == null) try obj.put(a, "anyOf", branches);
                _ = obj.swapRemove("oneOf");
            }
            var it = obj.iterator();
            while (it.next()) |e| try rewriteOneOf(a, e.value_ptr);
        },
        .array => |*arr| for (arr.items) |*item| try rewriteOneOf(a, item),
        else => {},
    }
}
/// Latest MCP revision we advertise in `initialize`. MCP versions are dated
/// (there is no "MCP 2.0"); negotiation is built in: the client sends the
/// newest revision it supports and the server answers with that version or
/// the newest *it* supports — we accept whatever it picks because the entire
/// surface we use (initialize / notifications/initialized / tools/list /
/// tools/call with text content blocks) is identical from 2024-11-05 through
/// 2025-11-25. Everything 2025-11-25 added (tasks, extensions, URL-mode
/// elicitation, sampling tool-calls) is opt-in via capabilities, and we
/// declare `capabilities:{}`, so servers can't expect any of it from us.
/// Streamable HTTP additionally carries this revision in each request after
/// initialization. Responses may be JSON or one or more SSE `data:` events.
const latest_protocol = "2025-11-25";
const max_http_response = 1 << 20;
pub const smolify_url = "https://app.smol.ly/mcp";

const shutdown_grace = std.Io.Duration.fromMilliseconds(100);

fn waitChild(child: *std.process.Child, io: Io) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

fn shutdownDeadline(io: Io) void {
    io.sleep(shutdown_grace, .awake) catch {};
}

/// Signal a normal stdio-server shutdown with EOF, but never let a server's
/// SIGTERM handler stall the CLI. A child that does not exit within the grace
/// window is force-killed and reaped so one-shot/SDK callers do not inherit
/// teardown latency or zombies.
fn stopChild(io: Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (child.stdin) |stdin| {
        stdin.close(io);
        child.stdin = null;
    }

    const Done = union(enum) { exited: std.process.Child.WaitError!std.process.Child.Term, deadline: void };
    var done_buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &done_buf);
    sel.concurrent(.exited, waitChild, .{ child, io }) catch {
        child.kill(io);
        return;
    };
    sel.concurrent(.deadline, shutdownDeadline, .{io}) catch {
        _ = sel.await() catch {};
        sel.cancelDiscard();
        return;
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        child.kill(io);
        return;
    };
    sel.cancelDiscard();
    if (first == .exited or child.id == null) return;

    switch (builtin.os.tag) {
        .windows => child.kill(io),
        .wasi => unreachable,
        else => {
            std.posix.kill(child.id.?, .KILL) catch {};
            _ = child.wait(io) catch child.kill(io);
        },
    }
}

const StdioTransport = struct {
    child: std.process.Child,
    stdin_writer: Io.File.Writer,
    stdout_reader: Io.File.Reader,
};

const HttpTransport = struct {
    url: []const u8,
    client: std.http.Client,
    headers: []const std.http.Header = &.{},
    oauth_home: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

const Transport = union(enum) {
    stdio: StdioTransport,
    http: HttpTransport,
};

fn validRemoteUri(uri: std.Uri) bool {
    if (uri.host == null) return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host = uri.host.?.percent_encoded;
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.eql(u8, host, "::1");
}

pub fn validRemoteUrl(url: []const u8) bool {
    return validRemoteUri(std.Uri.parse(url) catch return false);
}

const Server = struct {
    name: []const u8,
    transport: Transport,
    next_id: i64 = 1,
    /// Revision the server negotiated in its `initialize` response ("?" if
    /// it didn't say) — shown in `/mcp` so version skew is visible.
    protocol_version: []const u8 = "?",
};

pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    home: []const u8,
    arena_state: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    servers: []*Server = &.{},
    tools: []Tool = &.{},

    pub fn arena(self: *Registry) Allocator {
        return self.arena_state.allocator();
    }

    /// Load .mcp.json entries containing either `command`/`args`/`env` or a
    /// Streamable HTTP `url`, handshake each server, and collect their tools.
    /// Returns null
    /// (no error) when the config file is absent — MCP is optional.
    pub fn init(gpa: Allocator, io: Io, config_path: []const u8, home: []const u8) !?Registry {
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
        };
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
    pub fn empty(gpa: Allocator, io: Io, home: []const u8) Registry {
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

    /// Connect Smolify's public documentation MCP as a core service. It is a
    /// stateless Streamable HTTP endpoint, so no helper process or Node runtime
    /// is required. Public search/read tools work anonymously.
    pub fn connectSmolify(reg: *Registry) !usize {
        for (reg.servers) |server| if (std.mem.eql(u8, server.name, "smolify")) return 0;
        return reg.addRemoteServer("smolify", smolify_url, &.{});
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
        if (url_v) |url| {
            if (url != .string) return error.BadMcpConfig;
            const uri = std.Uri.parse(url.string) catch return error.BadMcpUrl;
            if (!validRemoteUri(uri)) return error.BadMcpUrl;

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
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, command);
            if (cfg.get("args")) |args| {
                if (args != .array) return error.BadMcpConfig;
                for (args.array.items) |arg| {
                    if (arg != .string) return error.BadMcpConfig;
                    try argv.append(a, arg.string);
                }
            }

            // Optional per-server env overlaid on the parent environment.
            var env_map: ?*std.process.Environ.Map = null;
            if (cfg.get("env")) |env| {
                if (env != .object) return error.BadMcpConfig;
                const m = try a.create(std.process.Environ.Map);
                m.* = std.process.Environ.Map.init(reg.gpa);
                var env_it = env.object.iterator();
                while (env_it.next()) |entry| {
                    if (entry.value_ptr.* != .string) return error.BadMcpConfig;
                    try m.put(entry.key_ptr.*, entry.value_ptr.*.string);
                }
                env_map = m;
            }

            var child = try std.process.spawn(reg.io, .{
                .argv = argv.items,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
                .environ_map = env_map,
            });
            var server_owns_child = false;
            errdefer if (!server_owns_child) {
                stopChild(reg.io, &child);
            };
            const in_buf = try a.alloc(u8, 64 * 1024);
            const out_buf = try a.alloc(u8, 1 << 20);
            server.* = .{
                .name = name,
                .transport = .{ .stdio = .{
                    .child = child,
                    .stdin_writer = child.stdin.?.writerStreaming(reg.io, in_buf),
                    .stdout_reader = child.stdout.?.readerStreaming(reg.io, out_buf),
                } },
            };
            server_owns_child = true;
        }

        var registry_owns_server = false;
        errdefer if (!registry_owns_server) deinitServer(server, reg.io);
        const server_index = servers.items.len;
        const tools_before = tools.items.len;
        errdefer tools.shrinkRetainingCapacity(tools_before);

        // Handshake. The server's reply tells us which revision it picked;
        // record it (we proceed regardless — see `latest_protocol`).
        try initializeServer(server, a, a);

        const listed = try request(server, a, "{}", "tools/list");
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

    pub fn deinit(reg: *Registry) void {
        for (reg.servers) |server| deinitServer(server, reg.io);
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
        const resp = request(server, response_alloc, pw.writer.buffered(), "tools/call") catch |err| switch (err) {
            // Streamable HTTP servers use 404 to expire a session. Re-run the
            // MCP handshake once, then retry the call without the stale ID.
            error.McpSessionExpired => retry: {
                try initializeServer(server, response_alloc, reg.arena());
                break :retry try request(server, response_alloc, pw.writer.buffered(), "tools/call");
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

fn deinitServer(server: *Server, io: Io) void {
    switch (server.transport) {
        .stdio => |*stdio| stopChild(io, &stdio.child),
        .http => |*http| {
            if (http.session_id) |session_id| http.client.allocator.free(session_id);
            http.client.deinit();
        },
    }
}

fn initializeServer(server: *Server, response_alloc: Allocator, session_alloc: Allocator) !void {
    const init_resp = try request(server, response_alloc,
        \\{"protocolVersion":"
    ++ latest_protocol ++
        \\","capabilities":{},"clientInfo":{"name":"simple-harness","version":"0.1"}}
    , "initialize");
    if (init_resp.object.get("result")) |res| if (res == .object) {
        if (res.object.get("protocolVersion")) |pv| if (pv == .string) {
            server.protocol_version = try session_alloc.dupe(u8, pv.string);
        };
    };
    try notify(server, response_alloc, "notifications/initialized");
}

/// JSON-RPC request/response over either transport. `params` is a raw JSON
/// object string. Result Values use `response_alloc`.
fn request(server: *Server, response_alloc: Allocator, params: []const u8, method: []const u8) !Value {
    const id = server.next_id;
    server.next_id += 1;

    switch (server.transport) {
        .stdio => |*stdio| {
            const w = &stdio.stdin_writer.interface;
            try w.print(
                \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
            ++ "\n", .{ id, method, params });
            try w.flush();

            const r = &stdio.stdout_reader.interface;
            while (true) {
                const line = (try r.takeDelimiter('\n')) orelse return error.McpClosed;
                if (matchingResponse(response_alloc, line, id)) |parsed| return parsed;
            }
        },
        .http => |*http| {
            const body = try std.fmt.allocPrint(response_alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
            , .{ id, method, params });
            const protocol_version = if (std.mem.eql(u8, method, "initialize")) latest_protocol else server.protocol_version;
            const response_body = (try httpPost(http, body, protocol_version, id)) orelse return error.BadMcpResponse;
            defer http.client.allocator.free(response_body);
            return parseHttpResponse(response_alloc, response_body, id) orelse error.BadMcpResponse;
        },
    }
}

/// Fire-and-forget JSON-RPC notification (no id, no response).
fn notify(server: *Server, response_alloc: Allocator, method: []const u8) !void {
    switch (server.transport) {
        .stdio => |*stdio| {
            const w = &stdio.stdin_writer.interface;
            try w.print(
                \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
            ++ "\n", .{method});
            try w.flush();
        },
        .http => |*http| {
            const body = try std.fmt.allocPrint(response_alloc,
                \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
            , .{method});
            if (try httpPost(http, body, server.protocol_version, null)) |response_body| {
                http.client.allocator.free(response_body);
            }
        },
    }
}

fn matchingResponse(a: Allocator, bytes: []const u8, id: i64) ?Value {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(Value, a, trimmed, .{ .allocate = .alloc_always }) catch return null;
    if (parsed != .object) return null;
    const got = parsed.object.get("id") orelse return null;
    if (got != .integer or got.integer != id) return null;
    return parsed;
}

/// Streamable HTTP permits either a plain application/json body or an SSE
/// response. MCP JSON-RPC payloads are compact one-line `data:` events; ignore
/// comments/notifications and return the event matching our request id.
fn parseHttpResponse(a: Allocator, body: []const u8, id: i64) ?Value {
    if (matchingResponse(a, body, id)) |parsed| return parsed;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        if (matchingResponse(a, std.mem.trimStart(u8, line["data:".len..], " \t"), id)) |parsed| return parsed;
    }
    return null;
}

fn jsonResponseMatches(gpa: Allocator, bytes: []const u8, expected_id: i64) bool {
    const parsed = std.json.parseFromSlice(Value, gpa, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const id = parsed.value.object.get("id") orelse return false;
    return id == .integer and id.integer == expected_id;
}

/// Read SSE one event at a time and return as soon as the matching JSON-RPC
/// response arrives. This is important for servers that keep the POST stream
/// open after emitting the response. Multiple `data:` fields are joined with
/// newlines per the SSE specification.
fn readSseResponse(gpa: Allocator, reader: *Io.Reader, expected_id: ?i64) !?[]u8 {
    const line_buf = try gpa.alloc(u8, max_http_response);
    defer gpa.free(line_buf);
    var event_data: std.ArrayList(u8) = .empty;
    defer event_data.deinit(gpa);
    var consumed: usize = 0;

    while (consumed < max_http_response) {
        var line_writer = Io.Writer.fixed(line_buf);
        const remaining = max_http_response - consumed;
        const n = reader.streamDelimiterLimit(&line_writer, '\n', .limited(remaining)) catch |err| switch (err) {
            error.StreamTooLong, error.WriteFailed => return error.McpResponseTooLarge,
            else => return err,
        };
        consumed += n;
        const line = std.mem.trimEnd(u8, line_writer.buffered(), "\r");

        var at_eof = false;
        const delimiter = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => blk: {
                at_eof = true;
                break :blk 0;
            },
            else => return err,
        };
        if (!at_eof) {
            std.debug.assert(delimiter == '\n');
            consumed += 1;
        }

        if (std.mem.startsWith(u8, line, "data:")) {
            const data = std.mem.trimStart(u8, line["data:".len..], " \t");
            if (event_data.items.len > 0) try event_data.append(gpa, '\n');
            if (event_data.items.len + data.len > max_http_response) return error.McpResponseTooLarge;
            try event_data.appendSlice(gpa, data);
        }

        if (line.len == 0 or at_eof) {
            if (event_data.items.len > 0) {
                const matches = if (expected_id) |id| jsonResponseMatches(gpa, event_data.items, id) else true;
                if (matches) return try gpa.dupe(u8, event_data.items);
                event_data.clearRetainingCapacity();
            }
        }
        if (at_eof) break;
    }
    if (consumed >= max_http_response) return error.McpResponseTooLarge;
    return null;
}

/// Perform one bounded Streamable HTTP POST, retaining the MCP session ID from
/// initialize and accepting both JSON and SSE responses. A 202 with no body is
/// the normal response to a notification.
fn httpPostUnwatched(http: *HttpTransport, body: []const u8, protocol_version: []const u8, expected_id: ?i64) !?[]u8 {
    var oauth_arena_state = std.heap.ArenaAllocator.init(http.client.allocator);
    defer oauth_arena_state.deinit();
    const oauth_arena = oauth_arena_state.allocator();

    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(http.client.allocator);
    try extra.appendSlice(http.client.allocator, http.headers);
    if (http.oauth_home) |home| if (mcp_oauth.loadAccessToken(http.client.io, http.client.allocator, oauth_arena, home, http.url)) |token| {
        try extra.append(http.client.allocator, .{
            .name = "authorization",
            .value = try std.fmt.allocPrint(oauth_arena, "Bearer {s}", .{token}),
        });
    };
    try extra.append(http.client.allocator, .{ .name = "accept", .value = "application/json, text/event-stream" });
    try extra.append(http.client.allocator, .{ .name = "mcp-protocol-version", .value = protocol_version });
    if (http.session_id) |session_id| try extra.append(http.client.allocator, .{ .name = "mcp-session-id", .value = session_id });

    var req = try http.client.request(.POST, try std.Uri.parse(http.url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = "codegraff-mcp/1" },
        },
        .extra_headers = extra.items,
    });
    defer req.deinit();
    errdefer {
        if (req.connection) |connection| connection.closing = true;
    }

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});

    const status = @intFromEnum(response.head.status);
    if (status == 401 or status == 403) {
        if (req.connection) |connection| connection.closing = true;
        return error.McpAuthenticationRequired;
    }
    if (status == 404 and http.session_id != null) {
        if (req.connection) |connection| connection.closing = true;
        http.client.allocator.free(http.session_id.?);
        http.session_id = null;
        return error.McpSessionExpired;
    }
    if (status < 200 or status >= 300) {
        if (req.connection) |connection| connection.closing = true;
        return error.McpHttpStatus;
    }

    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
            if (http.session_id) |session_id| {
                if (!std.mem.eql(u8, session_id, header.value)) return error.McpSessionChanged;
            } else {
                http.session_id = try http.client.allocator.dupe(u8, header.value);
            }
        }
    }

    if (response.head.content_length == 0) return null;
    const is_sse = if (response.head.content_type) |content_type|
        std.ascii.startsWithIgnoreCase(content_type, "text/event-stream")
    else
        false;
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    if (is_sse) return readSseResponse(http.client.allocator, reader, expected_id);

    const response_buf = try http.client.allocator.alloc(u8, max_http_response);
    errdefer http.client.allocator.free(response_buf);
    var fixed = Io.Writer.fixed(response_buf);
    _ = reader.streamRemaining(&fixed) catch |err| switch (err) {
        error.WriteFailed => return error.McpResponseTooLarge,
        else => return err,
    };
    const len = fixed.buffered().len;
    if (len == 0) {
        http.client.allocator.free(response_buf);
        return null;
    }
    return try http.client.allocator.realloc(response_buf, len);
}

const HttpPostDone = union(enum) {
    posted: anyerror!?[]u8,
    timeout,
};

fn httpPostTask(http: *HttpTransport, body: []const u8, protocol_version: []const u8, expected_id: ?i64) anyerror!?[]u8 {
    return httpPostUnwatched(http, body, protocol_version, expected_id);
}

fn httpPostTimeout(io: Io) void {
    io.sleep(.fromSeconds(15), .awake) catch {};
}

fn freeLateHttpPost(allocator: Allocator, result: anyerror!?[]u8) void {
    if (result) |body| {
        if (body) |bytes| allocator.free(bytes);
    } else |_| {}
}

fn cancelHttpPost(select: *Io.Select(HttpPostDone), allocator: Allocator) void {
    while (select.cancel()) |late| switch (late) {
        .posted => |result| freeLateHttpPost(allocator, result),
        .timeout => {},
    };
}

/// Race network I/O against a hard deadline. Cancellation unwinds the request,
/// whose errdefer poisons the connection so a timed-out socket is never pooled.
fn httpPost(http: *HttpTransport, body: []const u8, protocol_version: []const u8, expected_id: ?i64) !?[]u8 {
    var done_buf: [2]HttpPostDone = undefined;
    var select: Io.Select(HttpPostDone) = .init(http.client.io, &done_buf);
    select.concurrent(.posted, httpPostTask, .{ http, body, protocol_version, expected_id }) catch
        return error.McpRequestTimedOut;
    select.concurrent(.timeout, httpPostTimeout, .{http.client.io}) catch {
        const only = select.await() catch |err| {
            cancelHttpPost(&select, http.client.allocator);
            return err;
        };
        select.cancelDiscard();
        return only.posted;
    };

    const first = select.await() catch |err| {
        cancelHttpPost(&select, http.client.allocator);
        return err;
    };
    switch (first) {
        .posted => |result| {
            select.cancelDiscard();
            return result;
        },
        .timeout => {
            while (select.cancel()) |late| switch (late) {
                .posted => |result| freeLateHttpPost(http.client.allocator, result),
                .timeout => {},
            };
            return error.McpRequestTimedOut;
        },
    }
}

test "remote URLs require HTTPS except on loopback" {
    try std.testing.expect(validRemoteUrl("https://api.mobbin.com/mcp"));
    try std.testing.expect(validRemoteUrl("http://localhost:3000/mcp"));
    try std.testing.expect(validRemoteUrl("http://127.0.0.1:3000/mcp"));
    try std.testing.expect(validRemoteUrl("http://[::1]:3000/mcp"));
    try std.testing.expect(!validRemoteUrl("http://api.mobbin.com/mcp"));
    try std.testing.expect(!validRemoteUrl("ftp://localhost/mcp"));
    try std.testing.expect(!validRemoteUrl("not a URL"));
}

test "parseHttpResponse accepts JSON and Streamable HTTP SSE" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const json = parseHttpResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}", 7).?;
    try std.testing.expect(json.object.get("result") != null);

    const sse = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\n" ++
        "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"tools\":[]}}\r\n\r\n";
    const event = parseHttpResponse(a, sse, 8).?;
    try std.testing.expectEqual(@as(i64, 8), event.object.get("id").?.integer);
    try std.testing.expect(parseHttpResponse(a, sse, 9) == null);
}

test "rewriteOneOf: converts oneOf to anyOf, recursively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"oneOf":[{"type":"string"}],"properties":{"x":{"oneOf":[{"type":"number"},{"type":"null"}]}}}
    , .{});
    try rewriteOneOf(a, &v);
    try std.testing.expect(v.object.get("oneOf") == null);
    try std.testing.expectEqual(@as(usize, 1), v.object.get("anyOf").?.array.items.len);
    const x = v.object.get("properties").?.object.get("x").?;
    try std.testing.expect(x.object.get("oneOf") == null);
    try std.testing.expectEqual(@as(usize, 2), x.object.get("anyOf").?.array.items.len);
}

test "rewriteOneOf: existing anyOf wins when both are present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"anyOf":[{"type":"string"}],"oneOf":[{"type":"number"},{"type":"boolean"}]}
    , .{});
    try rewriteOneOf(a, &v);
    try std.testing.expect(v.object.get("oneOf") == null);
    // the pre-existing single-branch anyOf survives, the oneOf is dropped
    try std.testing.expectEqual(@as(usize, 1), v.object.get("anyOf").?.array.items.len);
}

test "rewriteOneOf: arrays and scalars pass through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"items":[{"oneOf":[1,2]},"plain",42]}
    , .{});
    try rewriteOneOf(a, &v);
    const first = v.object.get("items").?.array.items[0];
    try std.testing.expect(first.object.get("oneOf") == null);
    try std.testing.expect(first.object.get("anyOf") != null);
}
