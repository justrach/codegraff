//! Loopback Streamable HTTP adapter; task execution remains in mcp_server.
const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp_server.zig");
const Value = std.json.Value;
const Session = struct { id: [32]u8, server: mcp.Server };
const State = struct {
    io: Io,
    allocator: std.mem.Allocator,
    token: []const u8,
    port: u16,
    prototype: mcp.Server,
    mutex: Io.Mutex = .init,
    sessions: [64]?Session = @splat(null),
    next: usize = 0,
};

pub fn run(io: Io, a: std.mem.Allocator, port: u16, token: []const u8, prototype: mcp.Server) !void {
    if (token.len < 32 or std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidMcpHttpToken;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    var state: State = .{ .io = io, .allocator = a, .token = token, .port = port, .prototype = prototype };
    @import("serve.zig").serveLog(io, "Codegraff MCP listening at http://127.0.0.1:{d}/mcp", .{port});
    while (true) {
        const stream = try listener.accept(io);
        group.concurrent(io, connection, .{ &state, stream }) catch stream.close(io);
    }
}

fn connection(st: *State, stream: Io.net.Stream) void {
    defer stream.close(st.io);
    var rb: [16 * 1024]u8 = undefined;
    var wb: [4096]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, st.io, &rb);
    var writer = Io.net.Stream.Writer.init(stream, st.io, &wb);
    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch return;
    handle(st, &request) catch return;
}

fn respond(req: *std.http.Server.Request, status: std.http.Status, body: []const u8, sid: ?[]const u8) !void {
    var headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "Mcp-Session-Id", .value = sid orelse "" },
    };
    try req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = headers[0..if (sid != null) 3 else 2] });
}

fn handle(st: *State, req: *std.http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(st.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!std.mem.eql(u8, req.head.target, "/mcp")) return respond(req, .not_found, "{}", null);
    const host = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{st.port});
    const origin = try std.fmt.allocPrint(a, "http://{s}", .{host});
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{st.token});
    var authorized = false;
    var host_ok = false;
    var sid: ?[]const u8 = null;
    var json_type = false;
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host_ok = std.mem.eql(u8, h.value, host);
        if (std.ascii.eqlIgnoreCase(h.name, "origin") and !std.mem.eql(u8, h.value, origin)) return respond(req, .forbidden, "{}", null);
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorized = equalToken(h.value, bearer);
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) sid = try a.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) json_type = std.mem.eql(u8, h.value, "application/json") or std.mem.startsWith(u8, h.value, "application/json;");
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-protocol-version") and !std.mem.eql(u8, h.value, "2025-06-18") and !std.mem.eql(u8, h.value, "2025-03-26") and !std.mem.eql(u8, h.value, "2024-11-05")) return respond(req, .bad_request, "{}", null);
    }
    if (!host_ok) return respond(req, .forbidden, "{}", null);
    if (!authorized) return respond(req, .unauthorized, "{}", null);
    if (req.head.method != .POST and req.head.method != .DELETE) return respond(req, .method_not_allowed, "{}", null);
    try st.mutex.lock(st.io);
    defer st.mutex.unlock(st.io);
    var slot: ?*?Session = null;
    if (sid) |id| {
        for (&st.sessions) |*entry| if (entry.*) |s| {
            if (std.mem.eql(u8, &s.id, id)) {
                slot = entry;
                break;
            }
        };
        if (slot == null) return respond(req, .not_found, "{}", null);
    }
    if (req.head.method == .DELETE) {
        if (slot) |entry| entry.* = null else return respond(req, .bad_request, "{}", null);
        return respond(req, .no_content, "", null);
    }
    if (!json_type) return respond(req, .unsupported_media_type, "{}", null);
    if (req.head.content_length) |length| {
        if (length > 65536) return respond(req, .payload_too_large, "{}", null);
    }
    var buffer: [4096]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&buffer);
    const body = body_reader.allocRemaining(a, .limited(65536)) catch return respond(req, .payload_too_large, "{}", null);
    const value = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch return respond(req, .bad_request, "{}", null);
    if (value != .object) return respond(req, .bad_request, "{}", null);
    const method = value.object.get("method") orelse return respond(req, .bad_request, "{}", null);
    const initializing = method == .string and std.mem.eql(u8, method.string, "initialize");
    var fresh = st.prototype;
    const server = if (slot) |entry| &entry.*.?.server else &fresh;
    if (slot == null and !initializing) return respond(req, .bad_request, "{}", null);
    var output: Io.Writer.Allocating = .init(a);
    try server.handle(a, &output.writer, body);
    var new_id: ?[]const u8 = null;
    if (slot == null and fresh.initialized) {
        var bytes: [16]u8 = undefined;
        st.io.random(&bytes);
        const id = std.fmt.bytesToHex(bytes, .lower);
        st.sessions[st.next] = .{ .id = id, .server = fresh };
        new_id = &st.sessions[st.next].?.id;
        st.next = (st.next + 1) % st.sessions.len;
    }
    return respond(req, if (output.written().len == 0) .accepted else .ok, output.written(), new_id);
}

pub fn equalToken(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}
