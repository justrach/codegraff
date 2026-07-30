//! MCP JSON-RPC transport plumbing, split out of mcp.zig to keep it under
//! the repo's 600-line cap: the per-server transport union/state, the
//! legacy `initialize` handshake, and raw request/notify framing over
//! either stdio or Streamable HTTP. mcp.zig keeps the higher-level
//! `Registry` (server lifecycle, tool discovery, tool dispatch) and aliases
//! `Server`/`Transport` from here.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_http = @import("mcp_http.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const mcp_teardown = @import("mcp_teardown.zig");

const latest_protocol = mcp_protocol.latest_protocol;

pub const StdioTransport = struct {
    child: std.process.Child,
    stdin_writer: Io.File.Writer,
    stdout_reader: Io.File.Reader,
};

pub const Transport = union(enum) {
    stdio: StdioTransport,
    http: mcp_http.HttpTransport,
};

pub const Server = struct {
    name: []const u8,
    transport: Transport,
    next_id: i64 = 1,
    initialized: bool = true,
    /// Revision the server negotiated in its validated `initialize` response,
    /// shown in `/mcp` so version skew is visible.
    protocol_version: []const u8 = "?",
};

pub fn deinitServer(server: *Server, io: Io, budget: mcp_teardown.Budget) void {
    switch (server.transport) {
        .stdio => |*stdio| mcp_stdio.stopChild(io, &stdio.child),
        .http => |*http| { // never waits on a peer: bounded by `budget` (#305)
            if (http.session_id) |session_id| http.client.allocator.free(session_id);
            http.session_id = null;
            mcp_teardown.deinitHttpClient(&http.client, io, budget);
        },
    }
}

pub fn initializeServer(server: *Server, response_alloc: Allocator, session_alloc: Allocator) !void {
    const init_resp = try request(server, response_alloc,
        \\{"protocolVersion":"
    ++ latest_protocol ++
        \\","capabilities":{},"clientInfo":{"name":"simple-harness","version":"0.1"}}
    , "initialize");
    const protocol_transport: mcp_protocol.Transport = switch (server.transport) {
        .stdio => .stdio,
        .http => .streamable_http,
    };
    const protocol_version = try mcp_protocol.negotiatedProtocol(init_resp, protocol_transport);
    server.protocol_version = try session_alloc.dupe(u8, protocol_version);
    try notify(server, response_alloc, "notifications/initialized");
    server.initialized = true;
}

/// JSON-RPC request/response over either transport. `params` is a raw JSON
/// object string. Result Values use `response_alloc`.
pub fn request(server: *Server, response_alloc: Allocator, params: []const u8, method: []const u8) !Value {
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
                if (mcp_http.matchingResponse(response_alloc, line, id)) |parsed| return parsed;
            }
        },
        .http => |*http| {
            const body = try std.fmt.allocPrint(response_alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
            , .{ id, method, params });
            const protocol_version = if (std.mem.eql(u8, method, "initialize")) latest_protocol else server.protocol_version;
            const response_body = (try mcp_http.post(http, body, protocol_version, id)) orelse return error.BadMcpResponse;
            defer http.client.allocator.free(response_body);
            return mcp_http.parseHttpResponse(response_alloc, response_body, id) orelse error.BadMcpResponse;
        },
    }
}

/// Fire-and-forget JSON-RPC notification (no id, no response).
pub fn notify(server: *Server, response_alloc: Allocator, method: []const u8) !void {
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
            if (try mcp_http.post(http, body, server.protocol_version, null)) |response_body| {
                http.client.allocator.free(response_body);
            }
        },
    }
}
