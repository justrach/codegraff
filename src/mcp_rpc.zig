//! MCP JSON-RPC transport plumbing, split out of mcp.zig to keep it under
//! the repo's 600-line cap: the per-server transport union/state, the
//! legacy `initialize` handshake, era detection, and raw request/notify
//! framing over either stdio or Streamable HTTP. mcp.zig keeps the
//! higher-level `Registry` (server lifecycle, tool discovery, tool
//! dispatch) and aliases `Server`/`Transport` from here.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_http = @import("mcp_http.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const mcp_teardown = @import("mcp_teardown.zig");

const legacy_protocol = mcp_protocol.legacy_protocol;
const modern_protocol = mcp_protocol.modern_protocol;

pub const StdioTransport = struct {
    child: std.process.Child,
    stdin_writer: Io.File.Writer,
    stdout_reader: Io.File.Reader,
};

pub const Transport = union(enum) {
    stdio: StdioTransport,
    http: mcp_http.HttpTransport,
};

/// A property of the server, not the request (versioning § Backward
/// Compatibility): determined once at connect and cached for the process
/// lifetime, never re-probed per tool call.
pub const Era = enum { unknown, modern, legacy };

pub const Server = struct {
    name: []const u8,
    transport: Transport,
    next_id: i64 = 1,
    initialized: bool = true,
    era: Era = .unknown,
    /// Revision the server negotiated (legacy) or `modern_protocol` (modern),
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
    ++ legacy_protocol ++
        \\","capabilities":{},"clientInfo":{"name":"simple-harness","version":"0.1"}}
    , "initialize", null);
    const protocol_transport: mcp_protocol.Transport = switch (server.transport) {
        .stdio => .stdio,
        .http => .streamable_http,
    };
    const protocol_version = try mcp_protocol.negotiatedProtocol(init_resp, protocol_transport);
    server.protocol_version = try session_alloc.dupe(u8, protocol_version);
    try notify(server, response_alloc, "notifications/initialized");
    server.initialized = true;
    server.era = .legacy;
}

/// JSON-RPC request/response over either transport. `params` is a raw JSON
/// object string; `name` is the tool name for a `tools/call` (rendered as
/// `Mcp-Name` on a modern request) and null for everything else. Result
/// Values use `response_alloc`.
///
/// LOAD-BEARING: when `server.era != .modern`, `mcp_protocol.buildRequest`'s
/// `modern=false` path reproduces the exact pre-migration bytes — no `_meta`,
/// nothing added — so this is byte-identical to the client graff shipped
/// before 2026-07-28 for every server that has not been probed into the
/// modern era (today, that is every server).
pub fn request(server: *Server, response_alloc: Allocator, params: []const u8, method: []const u8, name: ?[]const u8) !Value {
    const id = server.next_id;
    server.next_id += 1;
    const modern = server.era == .modern;
    const body = try mcp_protocol.buildRequest(response_alloc, id, method, params, modern);

    switch (server.transport) {
        .stdio => |*stdio| {
            const w = &stdio.stdin_writer.interface;
            try w.writeAll(body);
            try w.writeByte('\n');
            try w.flush();

            const r = &stdio.stdout_reader.interface;
            while (true) {
                const line = (try r.takeDelimiter('\n')) orelse return error.McpClosed;
                if (mcp_http.matchingResponse(response_alloc, line, id)) |parsed| return parsed;
            }
        },
        .http => |*http| {
            const protocol_version = if (modern) modern_protocol else if (std.mem.eql(u8, method, "initialize")) legacy_protocol else server.protocol_version;
            const response_body = (try mcp_http.post(http, body, .{
                .protocol_version = protocol_version,
                .method = method,
                .name = name,
                .modern = modern,
            }, id)) orelse return error.BadMcpResponse;
            defer http.client.allocator.free(response_body);
            return mcp_http.parseHttpResponse(response_alloc, response_body, id) orelse error.BadMcpResponse;
        },
    }
}

/// Fire-and-forget JSON-RPC notification (no id, no response). Only ever
/// sent on the legacy `initialize` handshake — the modern wire format has no
/// notifications/initialized to send.
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
            if (try mcp_http.post(http, body, .{
                .protocol_version = server.protocol_version,
                .method = method,
                .modern = false,
            }, null)) |response_body| {
                http.client.allocator.free(response_body);
            }
        },
    }
}

fn connectLegacy(server: *Server, a: Allocator, session_alloc: Allocator) !Value {
    try initializeServer(server, a, session_alloc); // sets server.era = .legacy
    return request(server, a, "{}", "tools/list", null);
}

/// Connect a stdio server. Always legacy today — the `server/discover`
/// probe lands gated behind `GRAFF_MCP_PROBE` in a later commit; with the
/// gate off (the default), this is byte-identical to graff's pre-migration
/// behavior.
pub fn connectStdio(server: *Server, a: Allocator, session_alloc: Allocator) !Value {
    return connectLegacy(server, a, session_alloc);
}

/// Connect a Streamable HTTP server: attempt a modern (2026-07-28)
/// `tools/list` first — it doubles as the discovery call graff needs
/// anyway, so a modern server costs one POST where the legacy handshake
/// costs three. Falls back to the legacy `initialize` ->
/// `notifications/initialized` -> `tools/list` handshake on anything that
/// is not a recognized modern error (versioning § Backward Compatibility).
/// See mcp_protocol.classifyProbe for the exact classification rules.
pub fn connectHttp(server: *Server, a: Allocator, session_alloc: Allocator) !Value {
    return connectHttpAttempt(server, a, session_alloc, false);
}

fn connectHttpAttempt(server: *Server, a: Allocator, session_alloc: Allocator, retried: bool) !Value {
    const http = &server.transport.http;
    const probe_id = server.next_id;
    server.next_id += 1;
    const probe_body = try mcp_protocol.buildRequest(a, probe_id, "tools/list", "{}", true);
    const reply = try mcp_http.probe(http, probe_body, .{
        .protocol_version = modern_protocol,
        .method = "tools/list",
        .modern = true,
    });
    defer if (reply.body) |b| http.client.allocator.free(b);

    if (reply.status >= 200 and reply.status < 300) {
        const parsed = (if (reply.body) |b| mcp_http.parseHttpResponse(a, b, probe_id) else null) orelse return error.BadMcpResponse;
        server.era = .modern;
        server.protocol_version = try session_alloc.dupe(u8, modern_protocol);
        server.initialized = true;
        return parsed;
    }

    switch (mcp_protocol.classifyProbe(a, reply.body orelse &.{})) {
        .legacy => return connectLegacy(server, a, session_alloc),
        // -32020/-32021: graff's own request was malformed. That is a graff
        // bug, not a version mismatch — surface it loudly rather than
        // falling back and hiding it behind a legacy handshake that will
        // just fail differently.
        .modern => return error.McpModernRequestRejected,
        .incompatible => return error.McpIncompatibleProtocolVersion,
        .unsupported_version => |supported| {
            var has_modern = false;
            for (supported) |v| if (v == .string and std.mem.eql(u8, v.string, modern_protocol)) {
                has_modern = true;
            };
            if (has_modern) {
                // We asked for modern_protocol and the server both rejected
                // it AND claims to support it — contradictory, but retry
                // once (single-shot: this is idempotent, so a second
                // identical answer means give up, not loop).
                if (!retried) return connectHttpAttempt(server, a, session_alloc, true);
                return error.McpIncompatibleProtocolVersion;
            }
            // No overlap with modern_protocol, but classifyProbe only
            // returns this variant when `supported` overlaps something we
            // speak — so it must be a legacy revision: dual-era server.
            return connectLegacy(server, a, session_alloc);
        },
    }
}
