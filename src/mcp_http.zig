//! MCP Streamable HTTP transport.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_oauth = @import("mcp_oauth.zig");

const max_http_response = 1 << 20;

pub const HttpTransport = struct {
    url: []const u8,
    client: std.http.Client,
    headers: []const std.http.Header = &.{},
    oauth_home: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
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

pub fn matchingResponse(a: Allocator, bytes: []const u8, id: i64) ?Value {
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
pub fn parseHttpResponse(a: Allocator, body: []const u8, id: i64) ?Value {
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
pub fn post(http: *HttpTransport, body: []const u8, protocol_version: []const u8, expected_id: ?i64) !?[]u8 {
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
