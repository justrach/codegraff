//! Serialize complete ACP JSONL frames with notifications from background
//! workers. Each writer has its own staging buffer; the transport is shared.
const std = @import("std");
const Io = std.Io;

pub const LineWriter = struct {
    io: Io,
    out: *Io.Writer,
    lock: *Io.Mutex,
    pending: std.ArrayList(u8) = .empty,
    buf: [4096]u8 = undefined,
    writer: Io.Writer = undefined,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    pub fn init(self: *LineWriter, io: Io, out: *Io.Writer, lock: *Io.Mutex) void {
        self.* = .{ .io = io, .out = out, .lock = lock, .writer = .{ .vtable = &vtable, .buffer = &self.buf, .end = 0 } };
    }

    pub fn deinit(self: *LineWriter) void {
        self.writer.flush() catch {};
        self.pending.deinit(std.heap.page_allocator);
    }

    fn writeLine(self: *LineWriter, line: []const u8) Io.Writer.Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.out.writeAll(line);
        try self.out.flush();
    }

    fn feed(self: *LineWriter, bytes: []const u8) Io.Writer.Error!void {
        self.pending.appendSlice(std.heap.page_allocator, bytes) catch return error.WriteFailed;
        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |end| {
            try self.writeLine(self.pending.items[0 .. end + 1]);
            std.mem.copyForwards(u8, self.pending.items, self.pending.items[end + 1 ..]);
            self.pending.shrinkRetainingCapacity(self.pending.items.len - end - 1);
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *LineWriter = @alignCast(@fieldParentPtr("writer", w));
        try self.feed(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.feed(part);
            n += part.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.feed(pattern);
        return n + pattern.len * splat;
    }
};

test "ACP writer does not expose partial JSON lines" {
    const io = std.testing.io;
    var transport_buf: [256]u8 = undefined;
    var transport: Io.Writer = .fixed(&transport_buf);
    var lock: Io.Mutex = .init;
    var framed: LineWriter = undefined;
    framed.init(io, &transport, &lock);
    defer framed.deinit();
    try framed.writer.writeAll("{\"id\":1");
    try framed.writer.flush();
    try std.testing.expectEqual(@as(usize, 0), transport.buffered().len);
    try framed.writer.writeAll("}\n{\"id\":2}\n");
    try framed.writer.flush();
    try std.testing.expectEqualStrings("{\"id\":1}\n{\"id\":2}\n", transport.buffered());
}
