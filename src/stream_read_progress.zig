//! SSE inactivity is lack of body-byte progress, not lack of a complete line.
//! The read task owns all buffers; its watchdog observes only an atomic clock.
const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const Agent = @import("agent.zig").Agent;
const cancel_source = @import("cancel_source.zig");

pub const Limits = struct {
    idle_ms: u64,
    // A peer dripping bytes cannot hold an unfinished event open forever.
    total_ms: u64 = 15 * 60 * 1000,
    max_bytes: usize = 128 * 1024 * 1024,
};

pub fn expired(start_ms: i64, last_ms: i64, now_ms: i64, limits: Limits) bool {
    const idle: u64 = @intCast(@max(now_ms - last_ms, 0));
    const total: u64 = @intCast(@max(now_ms - start_ms, 0));
    return idle >= limits.idle_ms or total >= @max(limits.total_ms, limits.idle_ms);
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

pub const Progress = struct {
    io: Io,
    limits: Limits,
    started_ms: i64,
    last_ms: std.atomic.Value(i64),
    assembly_expired: bool = false, // read only after the watchdog has joined

    pub fn init(io: Io, limits: Limits) Progress {
        const now = nowMs(io);
        return .{ .io = io, .limits = limits, .started_ms = now, .last_ms = .init(now) };
    }

    pub fn note(self: *Progress) void {
        self.last_ms.store(nowMs(self.io), .monotonic);
    }

    pub fn watch(self: *Progress, poll_stdin: bool) http.WatchdogFired {
        while (!expired(self.started_ms, self.last_ms.load(.monotonic), nowMs(self.io), self.limits)) {
            self.io.sleep(.fromMilliseconds(10), .awake) catch return .deadline;
            if (poll_stdin and Agent.drainSteerStdin(true)) {
                cancel_source.cancelFromStdin();
                return .esc;
            }
            if (Agent.esc_cancel.load(.acquire)) return .esc;
        }
        const elapsed: u64 = @intCast(@max(nowMs(self.io) - self.started_ms, 0));
        self.assembly_expired = elapsed >= @max(self.limits.total_ms, self.limits.idle_ms);
        return .deadline;
    }

    pub fn deadlineError(self: *const Progress) anyerror {
        return if (self.assembly_expired) error.StreamEventDeadline else error.StreamStalled;
    }
};

/// An unbuffered forwarding writer observes each fragment the delimiter reader
/// consumes, including fragments much smaller than a normal writer buffer.
const Writer = struct {
    out: *Io.Writer,
    progress: *Progress,
    bytes: usize = 0,
    too_long: bool = false,
    writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{}, .end = 0 },

    fn write(self: *Writer, bytes: []const u8) Io.Writer.Error!void {
        if (bytes.len > self.progress.limits.max_bytes - self.bytes) {
            self.too_long = true;
            return error.WriteFailed;
        }
        try self.out.writeAll(bytes);
        self.bytes += bytes.len;
        if (bytes.len > 0) self.progress.note();
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("writer", w));
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.write(part);
            written += part.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.write(pattern);
        return written + pattern.len * splat;
    }
};

pub fn lineTask(reader: *Io.Reader, out: *Io.Writer, progress: *Progress) !usize {
    var writer: Writer = .{ .out = out, .progress = progress };
    return reader.streamDelimiterEnding(&writer.writer, '\n') catch |err| {
        if (writer.too_long) return error.StreamTooLong;
        return err;
    };
}

/// http-zig's readLine hides DATA progress until LF. Consume its body chunks
/// instead, retaining any bytes beyond LF across successive line reads. Control
/// frames and DATA for other streams do not count as this response's progress.
pub const H2Lines = struct {
    source: *@import("http_zig").LineStream,
    buffer: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn readLine(self: *H2Lines, dest: *std.ArrayList(u8), gpa: std.mem.Allocator, progress: *Progress) !bool {
        dest.clearRetainingCapacity();
        while (true) {
            if (self.start == self.end) {
                self.start = 0;
                self.end = try self.source.readChunk(&self.buffer);
                if (self.end == 0) return dest.items.len > 0;
                progress.note();
            }
            const bytes = self.buffer[self.start..self.end];
            const end = std.mem.indexOfScalar(u8, bytes, '\n');
            const n = end orelse bytes.len;
            if (n > progress.limits.max_bytes - dest.items.len) return error.StreamTooLong;
            try dest.appendSlice(gpa, bytes[0..n]);
            self.start += n;
            if (end != null) {
                self.start += 1;
                return true;
            }
        }
    }
};

test "SSE byte progress resets idle time but not the unfinished-event deadline" {
    const limits: Limits = .{ .idle_ms = 100, .total_ms = 500 };
    try std.testing.expect(!expired(0, 90, 100, limits));
    try std.testing.expect(expired(0, 90, 190, limits));
    try std.testing.expect(expired(0, 490, 500, limits));
    try std.testing.expect(!expired(0, 490, 499, limits));
    // An explicitly longer silence allowance is not shortened by the cap.
    try std.testing.expect(!expired(0, 590, 600, .{ .idle_ms = 700, .total_ms = 500 }));
}

test "SSE byte progress bounds an oversized unfinished event before appending it" {
    var reader: Io.Reader = .fixed("abcdefgh\n");
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var progress = Progress.init(std.testing.io, .{ .idle_ms = 100, .max_bytes = 4 });
    try std.testing.expectError(error.StreamTooLong, lineTask(&reader, &out.writer, &progress));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "SSE byte progress still ends a peer that drips an event forever" {
    const Drip = struct {
        fn run(progress: *Progress, done: *std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                progress.note();
                progress.io.sleep(.fromMilliseconds(20), .awake) catch return;
            }
        }
    };
    var progress = Progress.init(std.testing.io, .{ .idle_ms = 150, .total_ms = 300 });
    var done: std.atomic.Value(bool) = .init(false);
    var peer = std.testing.io.async(Drip.run, .{ &progress, &done });
    defer peer.await(std.testing.io);
    defer done.store(true, .release);
    try std.testing.expectEqual(http.WatchdogFired.deadline, progress.watch(false));
    const elapsed = nowMs(std.testing.io) - progress.started_ms;
    try std.testing.expect(elapsed >= 300 and elapsed < 2000);
    try std.testing.expectEqual(error.StreamEventDeadline, progress.deadlineError());
}
