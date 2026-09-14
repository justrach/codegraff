//! Storage ownership and allocation failures, with leak-tracked backing memory.
const std = @import("std");
const testing = std.testing;
const inbox = @import("peer_inbox.zig");
const Message = @import("presence_chan.zig").Message;
const payload = @import("util.zig").repeatBytes("full body 🙂\n", 200);

fn park(i: usize) !void {
    const from = try std.fmt.allocPrint(testing.allocator, "sender-{d}", .{i});
    defer testing.allocator.free(from);
    const text = try std.fmt.allocPrint(testing.allocator, "body-{d}:{s}", .{ i, payload });
    defer testing.allocator.free(text);
    const m: Message = .{ .from_session = from, .text = text, .to = if (i % 2 == 0) "recipient" else "" };
    const heard = if (i % 2 == 0) inbox.parkHeard(&.{m}, &.{}) else inbox.parkHeard(&.{}, &.{m});
    try testing.expectEqual(@as(usize, 1), heard);
}

fn snapshot() ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer };
    try inbox.writeJson(&json);
    return writer.toOwnedSlice();
}

fn parkingFailure(full: bool, allocation: usize) !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    inbox.setStorageAllocatorForTest(failing.allocator());
    // Must release all allocations while failing is still alive.
    defer inbox.setStorageAllocatorForTest(std.heap.page_allocator);
    if (full) for (0..inbox.inbox_cap + 2) |i| try park(i);
    const before = try snapshot();
    defer testing.allocator.free(before);
    const old_len = inbox.unread();
    const old_loss = inbox.dropped();
    failing.fail_index = failing.alloc_index + allocation;
    try park(99);
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(old_len, inbox.unread());
    try testing.expectEqual(old_loss + 1, inbox.dropped());
    try testing.expect(inbox.pending());
    const after = try snapshot();
    defer testing.allocator.free(after);
    // Byte-exact JSON includes FIFO order, full payloads, senders and flags.
    try testing.expectEqualStrings(before, after);
    const result = try inbox.takeAll(testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "body-99:") == null);
    try testing.expect(!inbox.pending());
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "inbox storage: first parking allocation fails on empty ring" {
    try parkingFailure(false, 0);
}

test "inbox storage: second parking allocation fails on empty ring without leaking sender" {
    try parkingFailure(false, 1);
}

test "inbox storage: first parking allocation fails on wrapped full ring without eviction" {
    try parkingFailure(true, 0);
}

test "inbox storage: second parking allocation fails on wrapped full ring without eviction" {
    try parkingFailure(true, 1);
}

test "inbox storage: eviction restore clear and allocator switch release owned bytes" {
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    inbox.setStorageAllocatorForTest(tracked.allocator());
    defer inbox.setStorageAllocatorForTest(std.heap.page_allocator);
    for (0..inbox.inbox_cap * 3) |i| try park(i);
    const saved = try snapshot();
    defer testing.allocator.free(saved);
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, saved, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        inbox.restoreJson(parsed.value);
    }
    const restored = try snapshot();
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(saved, restored);
    try testing.expectEqual(@as(usize, 0), inbox.dropped());
    inbox.clear();
    inbox.clear();
    try testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
    try park(100);
    inbox.setStorageAllocatorForTest(testing.allocator);
    try testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
    try testing.expect(!inbox.pending());
    try park(101);
    inbox.restoreJson(.null);
    try testing.expect(!inbox.pending());
}

test "inbox storage: output allocation sweep frees partial reads and retains storage until retry" {
    inbox.setStorageAllocatorForTest(testing.allocator);
    defer inbox.setStorageAllocatorForTest(std.heap.page_allocator);
    for (0..inbox.inbox_cap + 2) |i| try park(i);
    const expected = try inbox.takeAll(testing.allocator);
    defer testing.allocator.free(expected);
    for (0..128) |fail_index| {
        for (0..inbox.inbox_cap + 2) |i| try park(i);
        const before = try snapshot();
        defer testing.allocator.free(before);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = inbox.takeAll(failing.allocator()) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            try testing.expectEqual(inbox.inbox_cap, inbox.unread());
            try testing.expectEqual(@as(usize, 2), inbox.dropped());
            const after = try snapshot();
            defer testing.allocator.free(after);
            try testing.expectEqualStrings(before, after);
            const retry = try inbox.takeAll(testing.allocator);
            defer testing.allocator.free(retry);
            try testing.expectEqualStrings(expected, retry);
            try testing.expect(!inbox.pending());
            continue;
        };
        defer failing.allocator().free(result);
        try testing.expect(!failing.has_induced_failure);
        try testing.expect(fail_index > 0);
        try testing.expectEqualStrings(expected, result);
        try testing.expect(!inbox.pending());
        return;
    }
    return error.AllocationSweepDidNotFinish;
}
