//! One newline-framed record from a protocol stdin (ACP, `--json`). A record
//! is bounded by `max_bytes`, not by the reader's buffer: prompts with pasted
//! files or base64 image attachments are routinely larger than the 64 KiB
//! stdin buffer. Reader.takeDelimiter reports that as StreamTooLong, which the
//! inbox pumps treated as end of input, so the session exited silently.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_bytes: usize = 64 * 1024 * 1024;

pub const Record = union(enum) {
    /// Owned by the caller's allocator.
    line: []u8,
    /// Over the limit; consumed through its newline and dropped.
    too_long,
    eof,
};

pub fn take(reader: *Io.Reader, gpa: Allocator, limit: usize) error{ ReadFailed, OutOfMemory }!Record {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const n = reader.streamDelimiterLimit(&aw.writer, '\n', .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => {
            _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return .eof,
                error.ReadFailed => return error.ReadFailed,
            };
            return .too_long;
        },
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };
    // streamDelimiterLimit leaves the newline in the reader; a final record
    // without one ends at EOF instead.
    _ = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => if (n == 0) return .eof,
        error.ReadFailed => return error.ReadFailed,
    };
    return .{ .line = try aw.toOwnedSlice() };
}

test "records larger than the reader buffer are returned whole" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 200 * 1024);
    defer gpa.free(big);
    @memset(big, 'a');
    const input = try std.mem.concat(gpa, u8, &.{ "{\"id\":1}\n", big, "\n{\"id\":2}" });
    defer gpa.free(input);
    // A 64-byte buffer in front of the source, like the 64 KiB stdin buffer in
    // front of a 200 KiB+ ACP prompt.
    var src: Io.Reader = .fixed(input);
    var buf: [64]u8 = undefined;
    var ri: std.testing.ReaderIndirect = .init(&src, &buf);
    const r = &ri.interface;
    const first = try take(r, gpa, max_bytes);
    defer gpa.free(first.line);
    try std.testing.expectEqualStrings("{\"id\":1}", first.line);
    const second = try take(r, gpa, max_bytes);
    defer gpa.free(second.line);
    try std.testing.expectEqual(big.len, second.line.len);
    const third = try take(r, gpa, max_bytes);
    defer gpa.free(third.line);
    try std.testing.expectEqualStrings("{\"id\":2}", third.line);
    try std.testing.expect((try take(r, gpa, max_bytes)) == .eof);
}

test "an over-limit record is dropped and the next one still arrives" {
    const gpa = std.testing.allocator;
    var r: Io.Reader = .fixed("0123456789abcdef\n{\"ok\":true}\n");
    try std.testing.expect((try take(&r, gpa, 8)) == .too_long);
    const next = try take(&r, gpa, 8 * 1024);
    defer gpa.free(next.line);
    try std.testing.expectEqualStrings("{\"ok\":true}", next.line);
    try std.testing.expect((try take(&r, gpa, 8)) == .eof);
}

test "empty lines are records, and a trailing newline is not an extra one" {
    const gpa = std.testing.allocator;
    var r: Io.Reader = .fixed("\nx\n");
    const empty = try take(&r, gpa, 1024);
    defer gpa.free(empty.line);
    try std.testing.expectEqual(@as(usize, 0), empty.line.len);
    const x = try take(&r, gpa, 1024);
    defer gpa.free(x.line);
    try std.testing.expectEqualStrings("x", x.line);
    try std.testing.expect((try take(&r, gpa, 1024)) == .eof);
}
