//! HTTP client lifecycle matching rust-sdk `ClientLifecycleMode::Auto`.
//!
//! Probe `server/discover` and `tools/list` in parallel (two HTTP clients so
//! the shared `std.http.Client` is never raced). A modern `tools/list` result
//! is enough — the 2026-07-28 spec lets any request be first. A modern
//! `supportedVersions` list without a usable `tools/list` pays one follow-up
//! list. Anything else falls back to the legacy initialize handshake, the
//! same METHOD_NOT_FOUND path as `auto_startup_falls_back_after_discover_method_not_found`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp_http = @import("mcp_http.zig");
const mcp_oauth = @import("mcp_oauth.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_rpc = @import("mcp_rpc.zig");

const modern_protocol = mcp_protocol.modern_protocol;

pub const Fallback = enum { rejected, no_modern_version };

/// rust-sdk Auto: discover (and a parallel tools/list) then maybe initialize.
pub const Decision = union(enum) {
    modern_list,
    legacy_handshake: Fallback,
    retry,
    reject_modern,
    incompatible,
};

pub fn decideDiscover(a: Allocator, status: u16, body: []const u8) Decision {
    if (status >= 200 and status < 300) modern: {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) break :modern;
        const parsed = std.json.parseFromSliceLeaky(Value, a, trimmed, .{ .allocate = .alloc_always }) catch break :modern;
        if (parsed != .object or parsed.object.get("result") == null) break :modern;
        const versions = mcp_protocol.discoverSupportedVersions(parsed) catch
            return .{ .legacy_handshake = .no_modern_version };
        for (versions) |v| {
            if (v == .string and std.mem.eql(u8, v.string, modern_protocol)) return .modern_list;
        }
        return .{ .legacy_handshake = .no_modern_version };
    }
    return switch (mcp_protocol.classifyProbe(a, body)) {
        .legacy => .{ .legacy_handshake = .rejected },
        .modern => .reject_modern,
        .incompatible => .incompatible,
        .unsupported_version => |supported| {
            for (supported) |v| {
                if (v == .string and std.mem.eql(u8, v.string, modern_protocol)) return .retry;
            }
            return .{ .legacy_handshake = .no_modern_version };
        },
    };
}

const ProbeOut = struct {
    reply: mcp_http.ProbeReply,
    id: i64,
};

fn probeMethod(
    io: Io,
    gpa: Allocator,
    url: []const u8,
    headers: []const std.http.Header,
    oauth_home: ?[]const u8,
    method: []const u8,
    id: i64,
) ProbeOut {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var transport: mcp_http.HttpTransport = .{
        .url = url,
        .client = .{ .allocator = gpa, .io = io },
        .headers = headers,
        .oauth_home = oauth_home,
    };
    defer transport.client.deinit();
    const body = mcp_protocol.buildRequest(arena_state.allocator(), id, method, "{}", true) catch
        return .{ .reply = .{ .status = 0, .body = null }, .id = id };
    const reply = mcp_http.probe(&transport, body, .{
        .protocol_version = modern_protocol,
        .method = method,
        .modern = true,
    }) catch return .{ .reply = .{ .status = 0, .body = null }, .id = id };
    return .{ .reply = reply, .id = id };
}

fn listResult(a: Allocator, out: ProbeOut) ?Value {
    if (out.reply.status < 200 or out.reply.status >= 300) return null;
    const body = out.reply.body orelse return null;
    const parsed = mcp_http.parseHttpResponse(a, body, out.id) orelse return null;
    if (parsed != .object or parsed.object.get("result") == null) return null;
    return parsed;
}

fn markModern(server: *mcp_rpc.Server, session_alloc: Allocator) !void {
    server.era = .modern;
    server.protocol_version = try session_alloc.dupe(u8, modern_protocol);
    server.initialized = true;
}

pub fn connectHttp(server: *mcp_rpc.Server, a: Allocator, session_alloc: Allocator, known_era: mcp_rpc.Era) !Value {
    if (known_era == .legacy) {
        server.probe_fallback = .cached_legacy;
        return mcp_rpc.connectLegacy(server, a, session_alloc, null);
    }
    return connectHttpAttempt(server, a, session_alloc, false);
}

fn connectHttpAttempt(server: *mcp_rpc.Server, a: Allocator, session_alloc: Allocator, retried: bool) !Value {
    const http = &server.transport.http;
    const io = http.client.io;
    const gpa = http.client.allocator;

    // Two probes may load the same OAuth file. Refresh once so neither races a mint.
    if (http.oauth_home) |home| {
        var oa = std.heap.ArenaAllocator.init(gpa);
        defer oa.deinit();
        _ = mcp_oauth.loadAccessToken(io, gpa, oa.allocator(), home, http.url);
    }

    const id_discover = server.next_id;
    server.next_id += 1;
    const id_list = server.next_id;
    server.next_id += 1;

    var fut_discover = io.async(probeMethod, .{ io, gpa, http.url, http.headers, http.oauth_home, "server/discover", id_discover });
    var fut_list = io.async(probeMethod, .{ io, gpa, http.url, http.headers, http.oauth_home, "tools/list", id_list });
    const disc = fut_discover.await(io);
    const list = fut_list.await(io);
    defer if (disc.reply.body) |b| gpa.free(b);
    defer if (list.reply.body) |b| gpa.free(b);

    // Spec: any modern request can be first. A real tools/list result is the
    // catalog graff needs, so Auto costs one RTT on a 2026-07-28 server.
    if (listResult(a, list)) |parsed| {
        try markModern(server, session_alloc);
        return parsed;
    }

    switch (decideDiscover(a, disc.reply.status, disc.reply.body orelse &.{})) {
        .modern_list => {
            try markModern(server, session_alloc);
            return mcp_rpc.request(server, a, "{}", "tools/list", null);
        },
        .legacy_handshake => |why| {
            server.probe_fallback = switch (why) {
                .rejected => .rejected,
                .no_modern_version => .no_modern_version,
            };
            return mcp_rpc.connectLegacy(server, a, session_alloc, null);
        },
        .retry => {
            if (!retried) return connectHttpAttempt(server, a, session_alloc, true);
            return error.McpIncompatibleProtocolVersion;
        },
        .reject_modern => return error.McpModernRequestRejected,
        .incompatible => return error.McpIncompatibleProtocolVersion,
    }
}

fn expectDecision(body: []const u8, status: u16, want: std.meta.Tag(Decision)) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = decideDiscover(arena_state.allocator(), status, body);
    try std.testing.expectEqual(want, std.meta.activeTag(got));
}

test "Auto: server/discover listing 2026-07-28 is modern_list" {
    try expectDecision(
        \\{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28","2025-11-25"]}}
    , 200, .modern_list);
}

test "Auto: discover without 2026-07-28 falls back (no_modern_version)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = decideDiscover(arena_state.allocator(), 200,
        \\{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2025-11-25"]}}
    );
    try std.testing.expectEqual(Decision{ .legacy_handshake = .no_modern_version }, got);
}

test "Auto: METHOD_NOT_FOUND (-32601) falls back like rust-sdk Auto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = decideDiscover(arena_state.allocator(), 200,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
    );
    try std.testing.expectEqual(Decision{ .legacy_handshake = .rejected }, got);
}

test "Auto: initialize-first rejection falls back" {
    try expectDecision(
        \\{"jsonrpc":"2.0","error":{"code":-32000,"message":"Bad Request: Server not initialized"},"id":null}
    , 200, .legacy_handshake);
}

test "Auto: -32020 is a modern reject, never a legacy fallback" {
    try expectDecision(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"header mismatch"}}
    , 400, .reject_modern);
}

test "Auto: -32022 listing only 2025-11-25 is a legacy handshake" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = decideDiscover(arena_state.allocator(), 400,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"data":{"supported":["2025-11-25"]}}}
    );
    try std.testing.expectEqual(Decision{ .legacy_handshake = .no_modern_version }, got);
}

test "Auto: -32022 that also lists 2026-07-28 retries once" {
    try expectDecision(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"data":{"supported":["2026-07-28"]}}}
    , 400, .retry);
}

test "Auto: cached legacy era is a first-class Decision path" {
    try std.testing.expectEqual(mcp_rpc.LegacyReason.cached_legacy, .cached_legacy);
}
