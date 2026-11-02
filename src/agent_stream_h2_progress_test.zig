//! The production H2 line race must observe DATA bytes before the first LF.
//! Scripted HTTP/2 frames only: no sockets, TLS, provider, or user data.
const std = @import("std");
const Io = std.Io;
const http_zig = @import("http_zig");
const h2 = @import("agent_stream_h2.zig");
const H2Lines = @import("stream_read_progress.zig").H2Lines;

const idle_ms: u64 = 250;
const frame_delay_ms: i64 = 25;
const fragments: usize = 40;
const control_frames: usize = 80;
const fragment: [128]u8 = @splat('A');

/// Like the pinned dependency's RecordReader, refill the Reader buffer instead
/// of bypassing it through the Writer. Each refill exposes one complete frame,
/// so even a read that requests more bytes cannot swallow the whole script.
const PacedReader = struct {
    interface: Io.Reader = undefined,
    buffer: [1024]u8 = undefined,
    bytes: []const u8 = &.{},
    io: Io = undefined,
    hold_open: bool = false,
    data_seen: usize = 0,
    controls_seen: usize = 0,

    fn init(self: *PacedReader, io: Io, bytes: []const u8, hold_open: bool) void {
        self.io = io;
        self.bytes = bytes;
        self.hold_open = hold_open;
        self.interface = .{ .vtable = &.{ .stream = stream }, .buffer = &self.buffer, .seek = 0, .end = 0 };
    }

    fn stream(r: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        const self: *PacedReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.bytes.len == 0) {
            // Sleep is cancellable: raceLine.cancelDiscard joins this read
            // before the fixture, connection, or destination is deinitialized.
            while (self.hold_open) self.io.sleep(.fromMilliseconds(10), .awake) catch return error.ReadFailed;
            return error.EndOfStream;
        }
        if (self.bytes.len < 9) return error.ReadFailed;
        const n = 9 + (@as(usize, self.bytes[0]) << 16) + (@as(usize, self.bytes[1]) << 8) + self.bytes[2];
        if (n > self.bytes.len) return error.ReadFailed;
        const typ = self.bytes[3];
        if (typ == 0 or typ == 6) {
            self.io.sleep(.fromMilliseconds(frame_delay_ms), .awake) catch return error.ReadFailed;
        }
        const pending = r.buffered();
        if (pending.len + n > r.buffer.len) return error.ReadFailed;
        @memmove(r.buffer[0..pending.len], pending);
        @memcpy(r.buffer[pending.len..][0..n], self.bytes[0..n]);
        r.seek = 0;
        r.end = pending.len + n;
        self.bytes = self.bytes[n..];
        if (typ == 0) self.data_seen += 1;
        if (typ == 6) self.controls_seen += 1;
        return 0;
    }
};

fn writeHead(w: *Io.Writer) !void {
    try http_zig.frame.write(w, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    // HPACK's static-table :status 200, END_HEADERS, without END_STREAM.
    try http_zig.frame.write(w, .{ .typ = .headers, .flags = 0x4, .stream_id = 1, .payload = &.{0x88} });
}

fn writeData(w: *Io.Writer, bytes: []const u8, end_stream: bool) !void {
    try http_zig.frame.write(w, .{ .typ = .data, .flags = if (end_stream) 0x1 else 0, .stream_id = 1, .payload = bytes });
}

fn readLine(reader: *H2Lines, line: *std.ArrayList(u8)) !bool {
    const got = h2.raceLine(std.testing.io, reader, line, std.testing.allocator, false, idle_ms) orelse return error.NoReadTask;
    return switch (got) {
        .line => |result| try result,
        .stall => error.UnexpectedStall,
    };
}

fn elapsedMs(start: Io.Timestamp) u64 {
    const ns = Io.Timestamp.now(std.testing.io, .awake).nanoseconds - start.nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

test "HTTP/2 SSE byte progress keeps a fragmented line alive beyond its idle budget" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var wire: Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    try writeHead(&wire.writer);
    try writeData(&wire.writer, "data: ", false);
    for (0..fragments) |_| try writeData(&wire.writer, &fragment, false);
    // Both the blank line and an unterminated final line share the last frame:
    // subsequent races must retain bytes beyond the first delimiter.
    try writeData(&wire.writer, "\n\ndata: tail", true);

    var peer: PacedReader = .{};
    peer.init(io, wire.written(), false);
    var client: Io.Writer.Allocating = .init(gpa);
    defer client.deinit();
    var conn = http_zig.Conn.init(gpa, &peer.interface, &client.writer);
    defer conn.deinit();
    var source = try conn.startLines(.{ .method = "POST", .scheme = "https", .authority = "fixture.invalid", .path = "/events", .body = "{}" });
    defer source.deinit();
    try std.testing.expectEqual(@as(u16, 200), try source.waitStatus());
    var reader: H2Lines = .{ .source = &source };
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);

    const start = Io.Timestamp.now(io, .awake);
    try std.testing.expect(try readLine(&reader, &line));
    // Forty 25 ms fragments take at least four idle budgets, while every
    // individual DATA gap has a tenfold allowance for scheduling jitter.
    try std.testing.expect(elapsedMs(start) >= 3 * idle_ms);
    try std.testing.expectEqual(@as(usize, 6 + fragments * fragment.len), line.items.len);
    try std.testing.expectEqualStrings("data: ", line.items[0..6]);
    for (line.items[6..]) |byte| try std.testing.expectEqual(@as(u8, 'A'), byte);
    try std.testing.expectEqual(@as(usize, fragments + 2), peer.data_seen);
    try std.testing.expect(try readLine(&reader, &line));
    try std.testing.expectEqualStrings("", line.items);
    try std.testing.expect(try readLine(&reader, &line));
    try std.testing.expectEqualStrings("data: tail", line.items);
    try std.testing.expect(!try readLine(&reader, &line));
    try std.testing.expect(source.ended);
}

fn expectStoppedPartial(with_controls: bool) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var wire: Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    try writeHead(&wire.writer);
    try writeData(&wire.writer, "data: partial", false);
    if (with_controls) {
        // ACKs need no response. They exercise Conn.readFrame's control loop
        // without adding any response-body bytes or completing the SSE line.
        for (0..control_frames) |_| try http_zig.frame.write(&wire.writer, .{ .typ = .ping, .flags = 0x1, .stream_id = 0, .payload = "12345678" });
    }

    var peer: PacedReader = .{};
    peer.init(io, wire.written(), true);
    var client: Io.Writer.Allocating = .init(gpa);
    defer client.deinit();
    var conn = http_zig.Conn.init(gpa, &peer.interface, &client.writer);
    defer conn.deinit();
    var source = try conn.startLines(.{ .method = "POST", .scheme = "https", .authority = "fixture.invalid", .path = "/events", .body = "{}" });
    defer source.deinit();
    try std.testing.expectEqual(@as(u16, 200), try source.waitStatus());
    var reader: H2Lines = .{ .source = &source };
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);

    const start = Io.Timestamp.now(io, .awake);
    const got = h2.raceLine(io, &reader, &line, gpa, false, idle_ms) orelse return error.NoReadTask;
    switch (got) {
        .stall => |reason| try std.testing.expectEqual(.deadline, reason),
        .line => |result| {
            _ = try result;
            return error.ExpectedIdleTimeout;
        },
    }
    try std.testing.expect(elapsedMs(start) >= idle_ms);
    try std.testing.expectEqual(@as(usize, 1), peer.data_seen);
    try std.testing.expectEqualStrings("data: partial", line.items);
    try std.testing.expect(!source.ended);
    if (with_controls) {
        try std.testing.expect(peer.controls_seen > 0);
        // A timeout only after all two seconds of PINGs would falsely treat
        // transport traffic as progress. Require cancellation during them.
        try std.testing.expect(peer.controls_seen < control_frames);
        try std.testing.expect(peer.bytes.len > 0);
    }
}

test "HTTP/2 SSE byte progress still times out a stopped partial line" {
    try expectStoppedPartial(false);
}

test "HTTP/2 SSE byte progress ignores control traffic after a partial line" {
    try expectStoppedPartial(true);
}
