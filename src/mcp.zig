//! Minimal MCP (Model Context Protocol) client over the stdio transport.
//!
//! For each server in .mcp.json we spawn the configured command, speak
//! newline-delimited JSON-RPC 2.0 over its stdin/stdout, run the
//! initialize -> initialized -> tools/list handshake, and expose the
//! discovered tools to the agent. Tool calls are routed back via tools/call.
//!
//! Concurrency: tool calls arrive from agent pool threads, but a single
//! server is one bidirectional pipe — so every request/response round trip
//! holds `mutex`, serializing access per registry. MCP calls are rare and
//! fast relative to LLM calls, so global serialization is fine.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

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
/// The HTTP-only parts of the spec (MCP-Protocol-Version header, the
/// HTTP+SSE removal) don't apply to this stdio-only client.
const latest_protocol = "2025-11-25";

const Server = struct {
    name: []const u8,
    child: std.process.Child,
    stdin_writer: Io.File.Writer,
    stdout_reader: Io.File.Reader,
    next_id: i64 = 1,
    /// Revision the server negotiated in its `initialize` response ("?" if
    /// it didn't say) — shown in `/mcp` so version skew is visible.
    protocol_version: []const u8 = "?",
};

pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    arena_state: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    servers: []*Server = &.{},
    tools: []Tool = &.{},

    pub fn arena(self: *Registry) Allocator {
        return self.arena_state.allocator();
    }

    /// Load .mcp.json (`{"mcpServers": {"name": {"command","args","env"}}}`),
    /// spawn each server, handshake, and collect their tools. Returns null
    /// (no error) when the config file is absent — MCP is optional.
    pub fn init(gpa: Allocator, io: Io, config_path: []const u8) !?Registry {
        const text = Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer gpa.free(text);

        var reg: Registry = .{
            .gpa = gpa,
            .io = io,
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
        return .{ .gpa = gpa, .io = io, .arena_state = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Spawn + handshake a server at runtime and append its tools. Returns the
    /// number of tools it exposed. The servers/tools slices are rebuilt (arena);
    /// callers must re-render their tool list afterward. Run between turns only
    /// (no tool calls in flight).
    pub fn addServer(reg: *Registry, name: []const u8, command: []const u8, args: []const []const u8) !usize {
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
        const command = if (cfg.get("command")) |c| (if (c == .string) c.string else return error.BadMcpConfig) else return error.BadMcpConfig;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, command);
        if (cfg.get("args")) |args| if (args == .array) {
            for (args.array.items) |arg| if (arg == .string) try argv.append(a, arg.string);
        };

        // Optional per-server env overlaid on the parent environment.
        var env_map: ?*std.process.Environ.Map = null;
        if (cfg.get("env")) |env| if (env == .object) {
            const m = try a.create(std.process.Environ.Map);
            m.* = std.process.Environ.Map.init(reg.gpa);
            var env_it = env.object.iterator();
            while (env_it.next()) |e| try m.put(e.key_ptr.*, e.value_ptr.*.string);
            env_map = m;
        };

        var child = try std.process.spawn(reg.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore, // server logs/banners stay off our JSON channel
            .environ_map = env_map,
        });
        // Until the server is appended below, we own the child and must kill
        // it on any error path. Once it's in `reg.servers`, `deinit` becomes
        // the sole owner: killing here *and* there would reap the pid twice,
        // and the second kill panics on ESRCH in debug builds (a server whose
        // handshake fails — McpClosed — has an already-dead child).
        var registry_owns_child = false;
        errdefer if (!registry_owns_child) {
            _ = child.kill(reg.io);
        };

        const server = try a.create(Server);
        const in_buf = try a.alloc(u8, 64 * 1024);
        const out_buf = try a.alloc(u8, 1 << 20);
        server.* = .{
            .name = name,
            .child = child,
            .stdin_writer = child.stdin.?.writerStreaming(reg.io, in_buf),
            .stdout_reader = child.stdout.?.readerStreaming(reg.io, out_buf),
        };
        const server_index = servers.items.len;
        try servers.append(a, server);
        registry_owns_child = true; // deinit now owns the child; don't double-kill

        // Handshake. The server's reply tells us which revision it picked;
        // record it (we proceed regardless — see `latest_protocol`).
        const init_resp = try request(server, a,
            \\{"protocolVersion":"
        ++ latest_protocol ++
            \\","capabilities":{},"clientInfo":{"name":"simple-harness","version":"0.1"}}
        , "initialize");
        if (init_resp.object.get("result")) |res| if (res == .object) {
            if (res.object.get("protocolVersion")) |pv| if (pv == .string) {
                server.protocol_version = try a.dupe(u8, pv.string);
            };
        };
        try notify(server, "notifications/initialized");

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
        std.debug.print("  [mcp:{s}] connected (mcp {s}) — {d} tool(s)\n", .{ name, server.protocol_version, tools_v.array.items.len });
    }

    pub fn deinit(reg: *Registry) void {
        for (reg.servers) |server| _ = server.child.kill(reg.io);
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

        const a = reg.arena(); // response Values; freed at session end
        const resp = try request(server, a, pw.writer.buffered(), "tools/call");

        if (resp.object.get("error")) |e| {
            // Protocol-level failure (unknown tool, invalid args, server
            // crash) — distinct from a tool that ran and *returned* an error
            // (isError below). Keep the JSON-RPC code: models retry better
            // when they can tell -32602 bad-params from a tool-side failure.
            const msg = if (e.object.get("message")) |m| m.string else "MCP error";
            const code: i64 = if (e.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
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

/// JSON-RPC request/response over one server's stdio pipe. `params` is a raw
/// JSON object string. Skips interleaved notifications (messages without our
/// id) until the matching response arrives. Result Values are arena-owned.
fn request(server: *Server, a: Allocator, params: []const u8, method: []const u8) !Value {
    const id = server.next_id;
    server.next_id += 1;

    const w = &server.stdin_writer.interface;
    try w.print(
        \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
    ++ "\n", .{ id, method, params });
    try w.flush();

    const r = &server.stdout_reader.interface;
    while (true) {
        const line = (try r.takeDelimiter('\n')) orelse return error.McpClosed;
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch continue;
        if (parsed != .object) continue;
        const got = parsed.object.get("id") orelse continue; // notification
        if (got == .integer and got.integer == id) return parsed;
    }
}

/// Fire-and-forget JSON-RPC notification (no id, no response).
fn notify(server: *Server, method: []const u8) !void {
    const w = &server.stdin_writer.interface;
    try w.print(
        \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
    ++ "\n", .{method});
    try w.flush();
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
