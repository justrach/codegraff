//! Allocation failures must not consume a pull inbox, including tool dispatch.
const std = @import("std");
const testing = std.testing;
const inbox = @import("peer_inbox.zig");
const channel = @import("peer_channel.zig");
const Agent = @import("agent.zig").Agent;
const ToolCall = @import("tools.zig").ToolCall;

const payload = @import("util.zig").repeatBytes("complete message body — keep this UTF-8 text, not a clipped preview.\n", 40);

fn seed(a: std.mem.Allocator) !void {
    inbox.resetForTest();
    for (0..inbox.inbox_cap + 2) |i| {
        const from = try std.fmt.allocPrint(a, "session-with-a-name-longer-than-the-old-forty-eight-byte-limit-{d}", .{i});
        const body = try std.fmt.allocPrint(a, "BEGIN-{d}\n{s}END-{d}", .{ i, payload, i });
        const message = @import("presence_chan.zig").Message{
            .from_session = from,
            .text = body,
            .to = if (i % 2 == 0) "recipient" else "",
        };
        if (i % 2 == 0) {
            _ = inbox.parkHeard(&.{message}, &.{});
        } else {
            _ = inbox.parkHeard(&.{}, &.{message});
        }
    }
    try expectPending();
}

fn expectPending() !void {
    try testing.expect(inbox.pending());
    try testing.expectEqual(inbox.inbox_cap, inbox.unread());
    try testing.expectEqual(@as(usize, 2), inbox.dropped());
}

fn expectCleared() !void {
    try testing.expect(!inbox.pending());
    try testing.expectEqual(@as(usize, 0), inbox.unread());
    try testing.expectEqual(@as(usize, 0), inbox.dropped());
}

fn expectedResult(a: std.mem.Allocator) ![]const u8 {
    try seed(a);
    const text = try inbox.takeAll(a);
    // Validate the oracle too: comparing two equally clipped reads is not a
    // full-body regression. Include every retained body, not only its tail.
    for (2..inbox.inbox_cap + 2) |i| {
        const body = try std.fmt.allocPrint(a, "BEGIN-{d}\n{s}END-{d}", .{ i, payload, i });
        try testing.expect(std.mem.indexOf(u8, text, body) != null);
        const from = try std.fmt.allocPrint(a, "session-with-a-name-longer-than-the-old-forty-eight-byte-limit-{d}", .{i});
        try testing.expect(std.mem.indexOf(u8, text, from) != null);
    }
    try testing.expect(std.mem.indexOf(u8, text, "BEGIN-0\n") == null);
    try testing.expect(std.mem.indexOf(u8, text, "BEGIN-1\n") == null);
    try expectCleared();
    return text;
}

fn inboxCall(a: std.mem.Allocator) !ToolCall {
    var args: std.json.ObjectMap = .empty;
    try args.put(a, "action", .{ .string = "inbox" });
    return .{ .id = "inbox-test", .name = "peer_message", .input = .{ .object = args } };
}

test "peer inbox allocation failure: every formatting failure retains bodies and overflow for retry" {
    defer inbox.resetForTest();
    var setup = std.heap.ArenaAllocator.init(testing.allocator);
    defer setup.deinit();
    const expected = try expectedResult(setup.allocator());

    // Fail each successive allocation/reallocation, including ones after
    // earlier lines have already been formatted. Arenas mirror production
    // ownership and reclaim any partial formatting on both paths.
    var fail_index: usize = 0;
    while (fail_index < 1024) : (fail_index += 1) {
        try seed(setup.allocator());
        var storage = std.heap.ArenaAllocator.init(testing.allocator);
        defer storage.deinit();
        var failing = testing.FailingAllocator.init(storage.allocator(), .{ .fail_index = fail_index });
        const text = inbox.takeAll(failing.allocator()) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try expectPending();
            const retry = try inbox.takeAll(setup.allocator());
            try testing.expectEqualStrings(expected, retry);
            try expectCleared();
            continue;
        };
        try testing.expect(!failing.has_induced_failure);
        try testing.expect(fail_index > 0);
        try testing.expectEqualStrings(expected, text);
        try expectCleared();
        return;
    }
    return error.AllocationSweepDidNotFinish;
}

test "peer inbox allocation failure: actual action=inbox dispatch reports error without consuming mail" {
    defer inbox.resetForTest();
    var setup = std.heap.ArenaAllocator.init(testing.allocator);
    defer setup.deinit();
    const expected = try expectedResult(setup.allocator());
    const call = try inboxCall(setup.allocator());

    var fail_index: usize = 0;
    while (fail_index < 1024) : (fail_index += 1) {
        try seed(setup.allocator());
        var storage = std.heap.ArenaAllocator.init(testing.allocator);
        defer storage.deinit();
        var failing = testing.FailingAllocator.init(storage.allocator(), .{ .fail_index = fail_index });
        // The inbox branch only needs the allocator; other Agent fields must
        // not be touched (no presence lookup or filesystem side effects).
        var agent: Agent = undefined;
        agent.arena = failing.allocator();
        const result = try channel.handleMessage(&agent, call);
        if (failing.has_induced_failure) {
            try testing.expect(result.is_error);
            try testing.expect(result.text.len > 0);
            try expectPending();
            agent.arena = setup.allocator();
            const retry = try channel.handleMessage(&agent, call);
            try testing.expect(!retry.is_error);
            try testing.expectEqualStrings(expected, retry.text);
            try expectCleared();
            continue;
        }
        try testing.expect(fail_index > 0);
        try testing.expect(!result.is_error);
        try testing.expectEqualStrings(expected, result.text);
        try expectCleared();
        return;
    }
    return error.AllocationSweepDidNotFinish;
}

test "peer inbox allocation failure: empty helper and inbox dispatch require no allocation" {
    inbox.resetForTest();
    defer inbox.resetForTest();
    var setup = std.heap.ArenaAllocator.init(testing.allocator);
    defer setup.deinit();
    const call = try inboxCall(setup.allocator());
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectEqualStrings("inbox empty", try inbox.takeAll(failing.allocator()));
    var agent: Agent = undefined;
    agent.arena = failing.allocator();
    const result = try channel.handleMessage(&agent, call);
    try testing.expect(!result.is_error);
    try testing.expectEqualStrings("inbox empty", result.text);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try expectCleared();
}
