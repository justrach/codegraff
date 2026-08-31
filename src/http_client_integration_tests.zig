//! End-to-end model-POST regression for request-construction TLS recovery.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const http_client = @import("http_client.zig");
const Provider = @import("provider.zig").Provider;

fn serveOk(io: Io, server: *std.Io.net.Server) void {
    for (0..2) |_| {
        const conn = server.accept(io) catch return;
        defer conn.close(io);
        var read_buf: [4096]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(conn, io, &read_buf);
        while (true) {
            const line = (reader.interface.takeDelimiter('\n') catch return) orelse return;
            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
        }
        _ = reader.interface.take(2) catch return;
        var write_buf: [256]u8 = undefined;
        var writer = std.Io.net.Stream.Writer.init(conn, io, &write_buf);
        writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok") catch return;
        writer.interface.flush() catch return;
    }
}

test "one TLS-broken generation recovers later ordinary and child model POSTs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var server_future = io.async(serveOk, .{ io, &server });
    defer server_future.await(io);

    const bound = server.socket.address;
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{bound.getPort()});
    const provider: Provider = .{
        .id = "test",
        .kind = .openai,
        .auth = .x_api_key,
        .url = url,
        .api_key = "test",
        .model = "test",
        .context = 0,
    };

    http_client.injectConstructionTlsForTest(0);
    try std.testing.expectError(
        error.TlsRequestConstructionFailed,
        http.postWithConv(gpa, &runtime.client, provider, "{}", "tui-root-failed"),
    );

    const ordinary = try http.postWithConv(gpa, &runtime.client, provider, "{}", "tui-root-later");
    defer gpa.free(ordinary);
    try std.testing.expectEqualStrings("ok", ordinary);

    const child = try http.postWithConv(gpa, &runtime.client, provider, "{}", "tui-child-later");
    defer gpa.free(child);
    try std.testing.expectEqualStrings("ok", child);
}
