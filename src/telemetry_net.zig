//! OTLP/HTTP transport helpers for telemetry.zig: collector auth-key
//! validation, signal-URL derivation, and the mock collectors + tests that
//! exercise the bounded-deadline POST path. Split out of telemetry.zig
//! (600-line goal); telemetry.zig re-exports the shared names.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const telemetry_mod = @import("telemetry.zig");
const Telemetry = telemetry_mod.Telemetry;

pub fn validatedAuthKey(value: ?[]const u8) ?[]const u8 {
    const key = value orelse return null;
    if (key.len == 0 or key.len > 1024) return null;
    // Header values must not admit control/whitespace injection. Collector keys
    // are intentionally a single visible token rather than generic OTLP header
    // syntax, which also keeps secrets out of parsing diagnostics.
    for (key) |byte| if (byte < 0x21 or byte > 0x7e) return null;
    return key;
}

pub fn otlpLogsUrl(gpa: Allocator, endpoint: []const u8) !?[]u8 {
    // Append the signal path to the URL path rather than to a query value. URL
    // fragments are client-side only and must not be sent to the collector.
    const fragment_at = std.mem.indexOfScalar(u8, endpoint, '#') orelse endpoint.len;
    const without_fragment = endpoint[0..fragment_at];
    const query_at = std.mem.indexOfScalar(u8, without_fragment, '?') orelse without_fragment.len;
    const query = without_fragment[query_at..];
    const base = std.mem.trimEnd(u8, without_fragment[0..query_at], "/");
    if (base.len == 0) return null;
    if (std.mem.endsWith(u8, base, "/v1/logs")) return try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, query });
    return try std.fmt.allocPrint(gpa, "{s}/v1/logs{s}", .{ base, query });
}

fn stallTelemetryCollector(io: Io, server: *Io.net.Server, accepted: *std.atomic.Value(bool)) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    accepted.store(true, .release);
    io.sleep(.fromSeconds(5), .awake) catch {};
}

fn answerTelemetryCollector(
    io: Io,
    server: *Io.net.Server,
    expected_key: []const u8,
    saw_key: *std.atomic.Value(bool),
) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buf);
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        if (std.mem.eql(u8, line, "\r") or line.len == 0) break;
        const prefix = "x-harness-key:";
        if (!std.ascii.startsWithIgnoreCase(line, prefix)) continue;
        const value = std.mem.trim(u8, line[prefix.len..], " \t\r\n");
        saw_key.store(std.mem.eql(u8, value, expected_key), .release);
    }
    const response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    var write_buf: [256]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buf);
    writer.interface.writeAll(response) catch return;
    writer.interface.flush() catch {};
}

test "telemetry collector key accepts one bounded visible token" {
    try std.testing.expectEqual(@as(?[]const u8, null), validatedAuthKey(null));
    try std.testing.expectEqual(@as(?[]const u8, null), validatedAuthKey(""));
    try std.testing.expectEqual(@as(?[]const u8, null), validatedAuthKey("secret key"));
    try std.testing.expectEqual(@as(?[]const u8, null), validatedAuthKey("secret\r\ninjected"));
    try std.testing.expectEqual(@as(?[]const u8, null), validatedAuthKey("nön-ascii"));
    try std.testing.expectEqualStrings("safe-token_123", validatedAuthKey("safe-token_123").?);
}

test "OTLP URL derivation preserves queries and drops fragments" {
    const gpa = std.testing.allocator;
    const appended = (try otlpLogsUrl(gpa, "https://collector.example/base/?token=x#ignored")).?;
    defer gpa.free(appended);
    try std.testing.expectEqualStrings("https://collector.example/base/v1/logs?token=x", appended);

    const exact = (try otlpLogsUrl(gpa, "https://collector.example/v1/logs/?token=x#ignored")).?;
    defer gpa.free(exact);
    try std.testing.expectEqualStrings("https://collector.example/v1/logs?token=x", exact);

    var long_host: [600]u8 = undefined;
    @memset(&long_host, 'a');
    const long_endpoint = try std.fmt.allocPrint(gpa, "https://{s}.example?token=x", .{long_host});
    defer gpa.free(long_endpoint);
    const long_url = (try otlpLogsUrl(gpa, long_endpoint)).?;
    defer gpa.free(long_url);
    try std.testing.expect(long_url.len > 512);
    try std.testing.expect(std.mem.endsWith(u8, long_url, ".example/v1/logs?token=x"));
}

test "OTLP POST sends the collector key" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var saw_key: std.atomic.Value(bool) = .init(false);
    var server_group: Io.Group = .init;
    defer server_group.cancel(io);
    try server_group.concurrent(io, answerTelemetryCollector, .{ io, &server, "collector-secret", &saw_key });

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}/v1/logs", .{server.socket.address.getPort()});
    try std.testing.expect(Telemetry.postOtlp(&client, endpoint, "{}", "collector-secret"));
    try std.testing.expect(saw_key.load(.acquire));
}

test "OTLP flush arms its deadline before network I/O" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var accepted: std.atomic.Value(bool) = .init(false);
    var server_group: Io.Group = .init;
    defer server_group.cancel(io);
    try server_group.concurrent(io, stallTelemetryCollector, .{ io, &server, &accepted });

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var telemetry: Telemetry = .{
        .io = io,
        .gpa = gpa,
        .endpoint = endpoint,
        .client = &client,
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = 0,
    };
    defer telemetry.deinit();
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    telemetry.sendBatchWithDeadline(&.{}, true, .fromMilliseconds(250));
    const elapsed = Io.Timestamp.now(io, .awake).nanoseconds - started;
    try std.testing.expect(accepted.load(.acquire));
    try std.testing.expect(elapsed >= 100 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < 3 * std.time.ns_per_s);
}
