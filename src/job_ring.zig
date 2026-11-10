//! Bounded unread ring and consumed-prefix reclamation for background bash jobs.
//!
//! Background jobs previously appended into `job.buf` for their entire lifetime
//! and advanced `job.cursor` without reclaiming `0..job.cursor`, while `capUnread`
//! shifted all 256 KiB via `replaceRange` on every pipe fill once unread output
//! hit `job_unread_cap`.
//!
//! This module bounds both memory and copy traffic:
//!   1. `capUnread` advances `cursor` in O(1) when unread exceeds `cap`, and
//!      compacts the unread tail back to offset 0 only once `cursor >= cap`
//!      (at most one 256 KiB copy per 256 KiB of dropped output, with total
//!      buffer length strictly `<= 2 * cap`).
//!   2. `consumeUnread` resets `buf.items.len = 0` and `cursor = 0` as soon as
//!      `bash_output` or `waitForeground` consumes the unread slice, freeing
//!      consumed output immediately instead of accumulating across the session.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const unread_cap: usize = 256 * 1024;
pub const settled_cap: usize = 16 * 1024;

pub const Step = struct {
    next_len: usize,
    next_cursor: usize,
    dropped: bool,
    compacted: bool,
};

/// Pure state transition verified in `lean-proofs/Graff/PromptStable.lean`.
pub fn capStep(buf_len: usize, cursor: usize, cap: usize) Step {
    const valid_cursor = @min(cursor, buf_len);
    if (buf_len - valid_cursor <= cap) {
        return .{
            .next_len = buf_len,
            .next_cursor = valid_cursor,
            .dropped = false,
            .compacted = false,
        };
    }
    const advanced_cursor = buf_len - cap;
    if (advanced_cursor >= cap and cap > 0) {
        return .{
            .next_len = cap,
            .next_cursor = 0,
            .dropped = true,
            .compacted = true,
        };
    }
    return .{
        .next_len = buf_len,
        .next_cursor = advanced_cursor,
        .dropped = true,
        .compacted = false,
    };
}

/// Pure read/consume transition: all unread bytes are handed to the caller and
/// the buffer resets to empty (`next_len = 0, next_cursor = 0`).
pub fn readStep(buf_len: usize, cursor: usize) struct { unread_len: usize, next_len: usize, next_cursor: usize } {
    const valid_cursor = @min(cursor, buf_len);
    return .{
        .unread_len = buf_len - valid_cursor,
        .next_len = 0,
        .next_cursor = 0,
    };
}

/// Enforce the unread cap in-place without reallocating.
pub fn capUnread(buf: *std.ArrayList(u8), cursor: *usize, dropped: *bool, cap: usize) void {
    const step = capStep(buf.items.len, cursor.*, cap);
    if (!step.dropped) {
        cursor.* = step.next_cursor;
        return;
    }
    dropped.* = true;
    if (step.compacted) {
        std.mem.copyForwards(u8, buf.items[0..cap], buf.items[buf.items.len - cap ..]);
        buf.items.len = cap;
        cursor.* = 0;
    } else {
        cursor.* = step.next_cursor;
    }
}

/// Reclaim all consumed bytes after `jobOutput` or `waitForeground` reads `buf.items[cursor..]`.
pub fn consumeUnread(gpa: Allocator, buf: *std.ArrayList(u8), cursor: *usize) void {
    cursor.* = 0;
    if (buf.capacity > unread_cap * 2) {
        buf.shrinkAndFree(gpa, unread_cap);
        buf.clearRetainingCapacity();
    } else {
        buf.clearRetainingCapacity();
    }
}

test "job_ring: capUnread bounds unread bytes at cap and compacts only once cursor reaches cap" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var cursor: usize = 0;
    var dropped = false;
    const cap: usize = 64;

    var chunk: [16]u8 = undefined;
    for (0..8) |i| {
        @memset(&chunk, @intCast('a' + i));
        try buf.appendSlice(gpa, &chunk);
        capUnread(&buf, &cursor, &dropped, cap);
        try std.testing.expect(buf.items.len - cursor <= cap);
        try std.testing.expect(buf.items.len <= cap * 2);
    }
    try std.testing.expect(dropped);
    try std.testing.expectEqual(@as(usize, cap), buf.items.len - cursor);
    try std.testing.expectEqual(@as(u8, 'e'), buf.items[cursor]);
    try std.testing.expectEqual(@as(u8, 'h'), buf.items[buf.items.len - 1]);
}

test "job_ring: consumeUnread reclaims consumed prefix so repeated reads never grow buf" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var cursor: usize = 0;

    for (0..20) |_| {
        try buf.appendSlice(gpa, "hello-world-chunk\n");
        const step = readStep(buf.items.len, cursor);
        try std.testing.expectEqual(@as(usize, 18), step.unread_len);
        consumeUnread(gpa, &buf, &cursor);
        try std.testing.expectEqual(@as(usize, 0), buf.items.len);
        try std.testing.expectEqual(@as(usize, 0), cursor);
    }
    try std.testing.expect(buf.capacity <= unread_cap * 2);
}
