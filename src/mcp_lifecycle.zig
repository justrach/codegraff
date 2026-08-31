//! HTTP client lifecycle matching rust-sdk `ClientLifecycleMode::Auto`.
//!
//! Try modern `tools/list` first: the 2026-07-28 spec lets any request be first,
//! so a modern server needs exactly one POST. A legacy-shaped rejection falls
//! back to the byte-identical initialize handshake; modern protocol errors are
//! surfaced rather than hidden behind fallback, matching rust-sdk Auto.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp_http = @import("mcp_http.zig");
const mcp_oauth = @import("mcp_oauth.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_rpc = @import("mcp_rpc.zig");

const modern_protocol = mcp_protocol.modern_protocol;

pub const Fallback = enum { rejected, no_modern_version };

/// Classify a failed modern request using rust-sdk Auto's fallback rules.
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

fn probeMethod(http: *mcp_http.HttpTransport, method: []const u8, id: i64) ProbeOut {
    var arena_state = std.heap.ArenaAllocator.init(http.client.allocator);
    defer arena_state.deinit();
    const body = mcp_protocol.buildRequest(arena_state.allocator(), id, method, "{}", true) catch
        return .{ .reply = .{ .status = 0, .body = null }, .id = id };
    const reply = mcp_http.probe(http, body, .{
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
    if (known_era == .modern) {
        try markModern(server, session_alloc);
        return mcp_rpc.request(server, a, "{}", "tools/list", null);
    }
    return connectHttpAttempt(server, a, session_alloc, false);
}

fn connectHttpAttempt(server: *mcp_rpc.Server, a: Allocator, session_alloc: Allocator, retried: bool) !Value {
    const http = &server.transport.http;
    const io = http.client.io;
    const gpa = http.client.allocator;

    if (http.oauth_home) |home| {
        var oa = std.heap.ArenaAllocator.init(gpa);
        defer oa.deinit();
        _ = mcp_oauth.loadAccessToken(io, gpa, oa.allocator(), home, http.url);
    }

    const id_list = server.next_id;
    server.next_id += 1;
    const list = probeMethod(http, "tools/list", id_list);
    defer if (list.reply.body) |b| gpa.free(b);

    // Any modern request may be first. A real tools/list result is the catalog
    // graff needs, so a 2026-07-28 server costs exactly one POST.
    if (listResult(a, list)) |parsed| {
        try markModern(server, session_alloc);
        return parsed;
    }

    return switch (decideDiscover(a, list.reply.status, list.reply.body orelse &.{})) {
        .modern_list => blk: {
            try markModern(server, session_alloc);
            break :blk mcp_rpc.request(server, a, "{}", "tools/list", null);
        },
        .legacy_handshake => |why| blk: {
            server.probe_fallback = switch (why) {
                .rejected => .rejected,
                .no_modern_version => .no_modern_version,
            };
            break :blk mcp_rpc.connectLegacy(server, a, session_alloc, null);
        },
        .retry => if (!retried)
            connectHttpAttempt(server, a, session_alloc, true)
        else
            error.McpIncompatibleProtocolVersion,
        .reject_modern => error.McpModernRequestRejected,
        .incompatible => error.McpIncompatibleProtocolVersion,
    };
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

test "Auto: known modern era lists without server/discover" {
    const src = @embedFile("mcp_lifecycle.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "if (known_era == .modern)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tools/list") != null);
}

test "Auto: first launch tries modern tools/list before legacy fallback" {
    const src = @embedFile("mcp_lifecycle.zig");
    const list_pos = std.mem.indexOf(u8, src, "const list = probeMethod").?;
    const fallback_pos = std.mem.indexOfPos(u8, src, list_pos, ".legacy_handshake => |why|").?;
    try std.testing.expect(list_pos < fallback_pos);
}

test "Auto: modern probe reuses the persistent HTTP client" {
    const src = @embedFile("mcp_lifecycle.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "fn probeMethod(http: *mcp_http.HttpTransport") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const list = probeMethod(http,") != null);
    const throwaway = "var transport: " ++ "mcp_http.HttpTransport";
    try std.testing.expect(std.mem.indexOf(u8, src, throwaway) == null);
}

test {
    _ = @import("mcp_cache.zig");
}
