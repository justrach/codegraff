const std = @import("std");
const testing = std.testing;
const inbox = @import("peer_inbox.zig");
const Message = @import("presence_chan.zig").Message;
const util = @import("util.zig");

fn msg(from: []const u8, text: []const u8) Message {
    return .{ .from_session = from, .text = text };
}

fn expectEmpty() !void {
    try testing.expectEqual(@as(usize, 0), inbox.unread());
    try testing.expectEqual(@as(usize, 0), inbox.dropped());
    try testing.expect(!inbox.pending());
}

test "inbox content: complete long unicode sender and multiline whitespace body" {
    inbox.resetForTest();
    defer inbox.clear();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const from = "sender-" ++ util.repeatBytes("長い名前🙂", 12) ++ "-end";
    // The former 200-byte boundary falls inside a multibyte character.
    const body = util.repeatBytes(" ", 199) ++ "🙂\n\t  preserved indentation\r\n" ++
        util.repeatBytes("資料と絵文字🌿\n", 40) ++ "  final line\t \n\n";
    try testing.expectEqual(@as(usize, 1), inbox.parkHeard(&.{msg(from, body)}, &.{}));
    try testing.expect(inbox.pending());
    const result = try inbox.takeAll(a);
    const expected = try std.fmt.allocPrint(a, "[peer message from {s}]: {s}\n", .{ from, body });
    try testing.expect(std.mem.indexOf(u8, result, expected) != null);
    try testing.expect(std.unicode.utf8ValidateSlice(result));
    try expectEmpty();
}

test "inbox content: parked local and device messages own their source bytes" {
    inbox.resetForTest();
    defer inbox.clear();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sender = "owned-sender-" ++ util.repeatBytes("x", 80);
    const body = "owned body\n\t" ++ util.repeatBytes("whole message 🙂 ", 30) ++ " trailing  ";
    {
        const from = try testing.allocator.dupe(u8, sender);
        defer testing.allocator.free(from);
        const text = try testing.allocator.dupe(u8, body);
        defer testing.allocator.free(text);
        var device = msg(from, text);
        device.to = "recipient";
        try testing.expectEqual(@as(usize, 2), inbox.parkHeard(&.{msg(from, text)}, &.{device}));
        @memset(from, '!');
        @memset(text, '?');
    }
    const result = try inbox.takeAll(a);
    const local = try std.fmt.allocPrint(a, "[peer message from {s}]: {s}\n", .{ sender, body });
    const device = try std.fmt.allocPrint(a, "[peer message from {s} · device DM]: {s}\n", .{ sender, body });
    try testing.expect(std.mem.indexOf(u8, result, local) != null);
    try testing.expect(std.mem.indexOf(u8, result, device) != null);
    try expectEmpty();
}

test "inbox content: repeated wraparound retains FIFO tail and reports every eviction" {
    inbox.resetForTest();
    defer inbox.clear();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const total = inbox.inbox_cap * 3 + 3;
    const lost = total - inbox.inbox_cap;
    for (0..total) |i| {
        const text = try std.fmt.allocPrint(a, "<message-{d}>", .{i});
        try testing.expectEqual(@as(usize, 1), inbox.parkHeard(&.{msg("writer", text)}, &.{}));
        try testing.expectEqual(@min(i + 1, inbox.inbox_cap), inbox.unread());
        try testing.expectEqual((i + 1) -| inbox.inbox_cap, inbox.dropped());
    }
    try testing.expect(inbox.pending());
    const result = try inbox.takeAll(a);
    for (0..lost) |i| {
        const text = try std.fmt.allocPrint(a, "<message-{d}>", .{i});
        try testing.expect(std.mem.indexOf(u8, result, text) == null);
    }
    var offset: usize = 0;
    for (lost..total) |i| {
        const text = try std.fmt.allocPrint(a, "[peer message from writer]: <message-{d}>\n", .{i});
        const position = std.mem.indexOfPos(u8, result, offset, text) orelse return error.TestExpectedEqual;
        offset = position + text.len;
    }
    // Match the count next to the loss label, not an unrelated message number.
    const count_first = try std.fmt.allocPrint(a, "{d} dropped", .{lost});
    const label_first = try std.fmt.allocPrint(a, "dropped {d}", .{lost});
    try testing.expect(std.mem.indexOf(u8, result, count_first) != null or
        std.mem.indexOf(u8, result, label_first) != null);
    try expectEmpty();
    try testing.expectEqualStrings("inbox empty", try inbox.takeAll(a));
    try expectEmpty();
}

test "inbox content: explicit clear resets overflow and subsequent read starts fresh" {
    inbox.resetForTest();
    defer inbox.clear();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..inbox.inbox_cap + 2) |_| {
        _ = inbox.parkHeard(&.{msg("old", "old body")}, &.{});
    }
    try testing.expectEqual(@as(usize, 2), inbox.dropped());
    inbox.clear();
    try expectEmpty();
    try testing.expectEqualStrings("inbox empty", try inbox.takeAll(a));
    inbox.clear();
    try expectEmpty();
    _ = inbox.parkHeard(&.{msg("fresh", "fresh body")}, &.{});
    try testing.expectEqual(@as(usize, 0), inbox.dropped());
    const result = try inbox.takeAll(a);
    try testing.expect(std.mem.indexOf(u8, result, "[peer message from fresh]: fresh body\n") != null);
    try testing.expect(std.mem.indexOf(u8, result, "old body") == null);
    try expectEmpty();
    try testing.expectEqualStrings("inbox empty", try inbox.takeAll(a));
}

test "inbox content: wake bounds preserve UTF-8 and loss-only reads remain actionable" {
    inbox.resetForTest();
    defer inbox.clear();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const from = "x" ++ util.repeatBytes("🙂", 90) ++ "\nsecond line";
    _ = inbox.parkHeard(&.{msg(from, "body not in wake")}, &.{});
    const wake = inbox.formatWake(a);
    try testing.expect(wake.len <= @import("peer_context.zig").inject_byte_cap);
    try testing.expect(std.unicode.utf8ValidateSlice(wake));
    try testing.expect(std.mem.startsWith(u8, wake, "[peer]"));
    try testing.expect(std.mem.indexOfScalar(u8, wake, '\n') == null);
    try testing.expect(std.mem.indexOf(u8, wake, "body not in wake") == null);
    try testing.expect(std.mem.endsWith(u8, wake, "action=inbox when relevant"));
    inbox.clear();
    inbox.restoreDropped(.{ .integer = 4 });
    try testing.expect(inbox.pending());
    const loss_wake = inbox.formatWake(a);
    try testing.expect(std.mem.indexOf(u8, loss_wake, "0 unread; 4 dropped") != null);
    const result = try inbox.takeAll(a);
    try testing.expect(std.mem.indexOf(u8, result, "4 dropped message(s)") != null);
    try expectEmpty();
}

test "inbox content: malformed saved loss is ignored and addition saturates" {
    inbox.resetForTest();
    defer inbox.clear();
    inbox.restoreDropped(.{ .integer = 3 });
    for ([_]std.json.Value{ .null, .{ .integer = -1 }, .{ .float = 2.5 }, .{ .string = "9" }, .{ .bool = true } }) |v| {
        inbox.restoreDropped(v);
        try testing.expectEqual(@as(usize, 3), inbox.dropped());
    }
    for (0..3) |_| inbox.restoreDropped(.{ .integer = std.math.maxInt(i64) });
    try testing.expectEqual(std.math.maxInt(usize), inbox.dropped());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved = try std.json.Stringify.valueAlloc(a, inbox.dropped(), .{});
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, saved, .{});
    inbox.clear();
    inbox.restoreDropped(parsed);
    try testing.expectEqual(std.math.maxInt(usize), inbox.dropped());
}
