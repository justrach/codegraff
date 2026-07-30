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

const stdio_probe_timeout: Io.Duration = .fromSeconds(3);

fn stdioProbeReadTask(server: *Server, response_alloc: Allocator, id: i64) anyerror!Value {
    const stdio = &server.transport.stdio;
    const r = &stdio.stdout_reader.interface;
    while (true) {
        const line = (try r.takeDelimiter('\n')) orelse return error.McpClosed;
        if (mcp_http.matchingResponse(response_alloc, line, id)) |parsed| return parsed;
    }
}

fn stdioProbeTimeoutTask(io: Io) void {
    io.sleep(stdio_probe_timeout, .awake) catch {};
}

const StdioProbeDone = union(enum) {
    replied: anyerror!Value,
    timeout,
};

pub const StdioProbeOutcome = enum { modern, legacy, closed };

fn classifyStdioProbe(result: anyerror!Value) StdioProbeOutcome {
    const response = result catch |err| switch (err) {
        error.McpClosed => return .closed,
        else => return .legacy, // any other error (incl. a malformed line) — never treat as modern
    };
    // A recognized modern *error* here (-32020/-32021/-32022) still reads as
    // legacy for stdio specifically: unlike the HTTP probe, graff has no
    // real modern stdio server to validate a "fail loudly" path against
    // (population ~0 today), so the conservative choice is the one that
    // degrades to the handshake graff already knows works.
    if (response.object.get("error") != null) return .legacy;
    const supported = mcp_protocol.discoverSupportedVersions(response) catch return .legacy;
    for (supported) |v| if (v == .string and std.mem.eql(u8, v.string, modern_protocol)) return .modern;
    return .legacy;
}

/// Attempt the `server/discover` probe, bounded to `stdio_probe_timeout` so
/// a legacy server that silently ignores an unrecognized pre-`initialize`
/// method can never hang graff at startup (stdio § Backward Compatibility:
/// fall back "on any error that is not a recognized modern error, or no
/// response within a reasonable timeout"). `Select.cancel` blocks until the
/// read task has actually stopped before returning, so by the time this
/// function returns on a timeout, nothing is still touching the reader —
/// the caller's subsequent (unbounded, as today) legacy `request()` reads
/// pick up cleanly on the same stream.
///
/// `.closed` (the child exited or closed stdout) is reported distinctly
/// from `.legacy` (a reply arrived, or the wait simply timed out) because
/// only `.closed` needs the caller to respawn: some legacy SDK servers
/// exit on an unrecognized pre-initialize message, and writing the
/// `initialize` request to a dead child's closed stdin would just error.
pub fn probeStdio(server: *Server, a: Allocator, io: Io) !StdioProbeOutcome {
    const id = server.next_id;
    server.next_id += 1;
    {
        const stdio = &server.transport.stdio;
        const w = &stdio.stdin_writer.interface;
        try w.print(
            \\{{"jsonrpc":"2.0","id":{d},"method":"server/discover","params":{{}}}}
        ++ "\n", .{id});
        try w.flush();
    }

    var done_buf: [2]StdioProbeDone = undefined;
    var select: Io.Select(StdioProbeDone) = .init(io, &done_buf);
    select.concurrent(.replied, stdioProbeReadTask, .{ server, a, id }) catch return .legacy;
    select.concurrent(.timeout, stdioProbeTimeoutTask, .{io}) catch {
        const only = select.await() catch return .legacy;
        select.cancelDiscard();
        return classifyStdioProbe(only.replied);
    };

    const first = select.await() catch return .legacy;
    switch (first) {
        .replied => |result| {
            select.cancelDiscard();
            return classifyStdioProbe(result);
        },
        .timeout => {
            _ = select.cancel(); // blocks until the read task has actually stopped
            return .legacy;
        },
    }
}

/// Connect a stdio server. Always legacy — the gated `server/discover`
/// probe (`GRAFF_MCP_PROBE=1`, default off) is orchestrated by mcp.zig's
/// `startServer` instead of here: only it has the argv/env needed to
/// respawn a server whose process closes during the probe. This is
/// byte-identical to graff's pre-migration behavior either way.
pub fn connectStdio(server: *Server, a: Allocator, session_alloc: Allocator) !Value {
    return connectLegacy(server, a, session_alloc);
}

/// Finish connecting a stdio server that `probeStdio` found modern: no
/// handshake, just the modern-enveloped `tools/list` (era is set first so
/// `request` picks the modern wire format).
pub fn finishModernStdio(server: *Server, a: Allocator, session_alloc: Allocator) !Value {
    server.era = .modern;
    server.protocol_version = try session_alloc.dupe(u8, modern_protocol);
    server.initialized = true;
    return request(server, a, "{}", "tools/list", null);
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

    // A 2xx alone does NOT mean modern. JSON-RPC carries application errors in
    // a 200 body, and a legacy server that enforces "initialize first" answers
    // this probe with exactly that: 200 plus an error object. Treating it as
    // modern skipped the fallback and broke every such server. Only a real
    // `result` proves the server understood a request sent with no handshake.
    if (reply.status >= 200 and reply.status < 300) modern: {
        const body = reply.body orelse break :modern;
        const parsed = mcp_http.parseHttpResponse(a, body, probe_id) orelse break :modern;
        if (parsed != .object or parsed.object.get("result") == null) break :modern;
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

test "a late reply for a stale id cannot be mistaken for the id actually awaited" {
    // The exact loop body `request`'s stdio branch and `stdioProbeReadTask`
    // both use: takeDelimiter, then filter by id via
    // mcp_http.matchingResponse, skipping any line whose id doesn't match.
    // Proves that if a `server/discover` probe times out but its reply
    // arrives later, it cannot be mistaken for the `initialize` response
    // that follows it on the same stream — the ids differ (discover used
    // an earlier next_id).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var reader: Io.Reader = .fixed(
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}
        \\
    );
    var found: ?Value = null;
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse break;
        if (mcp_http.matchingResponse(a, line, 2)) |parsed| {
            found = parsed;
            break;
        }
    }
    const result = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 2), result.object.get("id").?.integer);
    try std.testing.expect(result.object.get("result").?.object.get("tools") != null);
}
