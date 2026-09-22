//! Graff's HTTP/2 request/response contract over the pinned http-zig transport.
//!
//! `agent_stream_h2.postStream` is only reachable through a TLS `http2_pool`
//! session, and the repo has no TLS test server to mock one against. So this
//! drives the same contract one layer down, with graff's own code on both ends
//! of it: graff's `providerHeadersWithConv` extras and request body go out
//! through `http_zig.Conn.startLines`, and the response comes back through the
//! `LineStream.readLine` loop that postStream runs. The peer is scripted HTTP/2
//! frame bytes over a fixed Reader/Writer -- no socket, TLS or network.
//!
//! The body is deliberately larger than both the 16384 frame cap and the 65535
//! initial windows. That is the case http-zig used to send as one DATA frame,
//! earning FRAME_SIZE_ERROR / FLOW_CONTROL_ERROR and -- because Session maps
//! those onto a fallback -- a silent drop to HTTP/1.1 that no test could see.

const std = @import("std");
const Io = std.Io;
const http_zig = @import("http_zig");
const http_headers = @import("http_headers.zig");
const ict = @import("http_client_integration_tests.zig");

const sse_body =
    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"root-ok\"}\n\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";

/// The shape postStream builds from providerHeadersWithConv: lower-cased names
/// in an http_zig.Header array. Copied rather than skipped so a change to the
/// header names or their casing fails here and not only against a live provider.
fn h2Extras(std_hdrs: []const std.http.Header, out: *[20]http_zig.Header, store: *[16][64]u8) []http_zig.Header {
    var n: usize = 0;
    for (std_hdrs, 0..) |h, i| {
        if (i >= store.len or n >= out.len) break;
        out[n] = .{
            .name = std.ascii.lowerString(&store[i], h.name),
            .value = h.value,
        };
        n += 1;
    }
    return out[0..n];
}

/// DATA frames the client emitted: count, widest frame, where END_STREAM sat.
fn scanData(gpa: std.mem.Allocator, written: []const u8, out: *std.ArrayList(u8)) !struct { frames: usize, biggest: usize, end_stream_frame: usize } {
    out.clearRetainingCapacity();
    var i: usize = 0;
    if (std.mem.startsWith(u8, written, http_zig.preface)) i = http_zig.preface.len;
    var frames: usize = 0;
    var biggest: usize = 0;
    var end_stream_frame: usize = 0;
    while (i + 9 <= written.len) {
        const len = (@as(usize, written[i]) << 16) | (@as(usize, written[i + 1]) << 8) | written[i + 2];
        if (i + 9 + len > written.len) break;
        if (written[i + 3] == 0) { // DATA
            frames += 1;
            if (len > biggest) biggest = len;
            if (written[i + 4] & 0x1 != 0) end_stream_frame = frames;
            try out.appendSlice(gpa, written[i + 9 ..][0..len]);
        }
        i += 9 + len;
    }
    return .{ .frames = frames, .biggest = biggest, .end_stream_frame = end_stream_frame };
}

test "graff's request body reaches an HTTP/2 peer in flow-controlled chunks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A realistic model request body: far past the 16384 frame cap and past the
    // 65535 initial windows, so it must both chunk and wait for credit.
    const body = try gpa.alloc(u8, 70000);
    defer gpa.free(body);
    @memset(body, '{');

    // Peer: SETTINGS, credit for both windows, then an SSE response split
    // across two DATA frames.
    var srv: std.Io.Writer.Allocating = .init(gpa);
    defer srv.deinit();
    try http_zig.frame.write(&srv.writer, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    var wu: [4]u8 = undefined;
    std.mem.writeInt(u32, &wu, 200_000, .big);
    try http_zig.frame.write(&srv.writer, .{ .typ = .window_update, .flags = 0, .stream_id = 0, .payload = &wu });
    try http_zig.frame.write(&srv.writer, .{ .typ = .window_update, .flags = 0, .stream_id = 1, .payload = &wu });
    const hdr = [_]u8{
        0x88, // :status 200
        0x40,
        0x0c,
        'c',
        'o',
        'n',
        't',
        'e',
        'n',
        't',
        '-',
        't',
        'y',
        'p',
        'e',
        0x11,
        't',
        'e',
        'x',
        't',
        '/',
        'e',
        'v',
        'e',
        'n',
        't',
        '-',
        's',
        't',
        'r',
        'e',
        'a',
        'm',
    };
    try http_zig.frame.write(&srv.writer, .{ .typ = .headers, .flags = 0x4, .stream_id = 1, .payload = &hdr });
    const cut = sse_body.len / 2;
    try http_zig.frame.write(&srv.writer, .{ .typ = .data, .flags = 0, .stream_id = 1, .payload = sse_body[0..cut] });
    try http_zig.frame.write(&srv.writer, .{ .typ = .data, .flags = 0x1, .stream_id = 1, .payload = sse_body[cut..] });
    const peer_bytes = try gpa.dupe(u8, srv.written());
    defer gpa.free(peer_bytes);

    var reader: std.Io.Reader = .fixed(peer_bytes);
    var client: std.Io.Writer.Allocating = .init(gpa);
    defer client.deinit();
    var conn = http_zig.Conn.init(gpa, &reader, &client.writer);
    defer conn.deinit();

    // graff's real request: its real extras, its real body.
    const p = ict.provider("https://api.x.ai/v1/responses");
    var hbuf: [12]std.http.Header = undefined;
    const std_hdrs = http_headers.providerHeadersWithConv(io, p, "", &hbuf, null);
    var out_hdrs: [20]http_zig.Header = undefined;
    var store: [16][64]u8 = undefined;
    const extras = h2Extras(std_hdrs, &out_hdrs, &store);

    var lines = try conn.startLines(.{
        .method = "POST",
        .scheme = "https",
        .authority = "api.x.ai",
        .path = "/v1/responses",
        .extra = extras,
        .body = body,
    });
    defer lines.deinit();

    try std.testing.expectEqual(@as(u16, 200), try lines.waitStatus());
    try std.testing.expectEqualStrings("text/event-stream", lines.header("content-type") orelse "");

    // The loop postStream runs: readLine until END_STREAM.
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    while (try lines.readLine(&line)) {
        try got.appendSlice(gpa, line.items);
        try got.append(gpa, '\n');
    }
    try std.testing.expect(lines.ended);
    try std.testing.expectEqualStrings(sse_body, got.items);

    // The request framing: chunked, never over the frame cap, END_STREAM last.
    var sent: std.ArrayList(u8) = .empty;
    defer sent.deinit(gpa);
    const scan = try scanData(gpa, client.written(), &sent);
    try std.testing.expectEqual(@as(usize, 5), scan.frames); // 4x16383/16384 + tail
    try std.testing.expect(scan.biggest <= 16384);
    try std.testing.expectEqual(scan.frames, scan.end_stream_frame);
    try std.testing.expectEqual(@as(usize, 70000), sent.items.len);
    try std.testing.expectEqualStrings(body, sent.items);
}

test "an SSE line split across HTTP/2 DATA frames is reassembled" {
    const gpa = std.testing.allocator;
    var srv: std.Io.Writer.Allocating = .init(gpa);
    defer srv.deinit();
    try http_zig.frame.write(&srv.writer, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    const hdr = [_]u8{0x88};
    try http_zig.frame.write(&srv.writer, .{ .typ = .headers, .flags = 0x4, .stream_id = 1, .payload = &hdr });
    // "data: AB\n\n" torn mid-line across two DATA frames.
    try http_zig.frame.write(&srv.writer, .{ .typ = .data, .flags = 0, .stream_id = 1, .payload = "data: A" });
    try http_zig.frame.write(&srv.writer, .{ .typ = .data, .flags = 0x1, .stream_id = 1, .payload = "B\n\n" });
    const peer_bytes = try gpa.dupe(u8, srv.written());
    defer gpa.free(peer_bytes);

    var reader: std.Io.Reader = .fixed(peer_bytes);
    var client: std.Io.Writer.Allocating = .init(gpa);
    defer client.deinit();
    var conn = http_zig.Conn.init(gpa, &reader, &client.writer);
    defer conn.deinit();

    var lines = try conn.startLines(.{ .method = "POST", .scheme = "https", .authority = "api.x.ai", .path = "/v1/responses", .body = "{}" });
    defer lines.deinit();
    try std.testing.expectEqual(@as(u16, 200), try lines.waitStatus());

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try std.testing.expect(try lines.readLine(&line));
    try std.testing.expectEqualStrings("data: AB", line.items);
    // The blank line that terminates the SSE event is a line of its own.
    try std.testing.expect(try lines.readLine(&line));
    try std.testing.expectEqualStrings("", line.items);
    try std.testing.expect(!try lines.readLine(&line));
}
