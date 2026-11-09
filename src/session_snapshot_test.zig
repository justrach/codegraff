const std = @import("std");
const snapshot = @import("session_snapshot.zig");
const Value = std.json.Value;
const a = std.testing.allocator;

fn setMetadata(s: *snapshot.Snapshot) !void {
    const metadata = "{\"label\":\"fixture\",\"messages\":[],\"revision\":4}";
    const header_end = std.mem.indexOf(u8, metadata, "[]").?;
    s.setMetadata(try a.dupe(u8, metadata), header_end);
}

fn integers(comptime values: anytype) [values.len]Value {
    var result: [values.len]Value = undefined;
    inline for (values, 0..) |v, i| result[i] = .{ .integer = v };
    return result;
}

test "session snapshot repeated append serializes only the suffix" {
    snapshot.reset();
    defer snapshot.reset();
    const items = integers(.{ 10, 20, 30, 40 });
    var first = try snapshot.prepare(a, items[0..2]);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.stats().serializations);
    var second = try snapshot.prepare(a, items[0..3]);
    defer second.deinit();
    var third = try snapshot.prepare(a, &items);
    defer third.deinit();
    var unchanged = try snapshot.prepare(a, &items);
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(usize, 4), snapshot.stats().serializations);
    try std.testing.expectEqual(first.messages[0], third.messages[0]);
    try std.testing.expectEqual(first.messages[1], third.messages[1]);
    try std.testing.expectEqual(@as(usize, 2), first.commonPrefix(third));
    try std.testing.expectEqual(@as(usize, 4), third.commonPrefix(unchanged));
}

test "session snapshot in place earlier edit invalidates only that chunk" {
    snapshot.reset();
    defer snapshot.reset();
    var text = [_]u8{ 'o', 'l', 'd' };
    const items = [_]Value{
        .{ .string = &text },
        .{ .integer = 20 },
        .{ .integer = 30 },
    };
    var first = try snapshot.prepare(a, &items);
    defer first.deinit();
    text[0] = 'n';
    var second = try snapshot.prepare(a, &items);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 4), snapshot.stats().serializations);
    try std.testing.expect(first.messages[0] != second.messages[0]);
    try std.testing.expectEqual(first.messages[1], second.messages[1]);
    try std.testing.expectEqual(first.messages[2], second.messages[2]);
    try std.testing.expectEqualStrings("\"old\"", first.messages[0].data);
    try std.testing.expectEqualStrings("\"nld\"", second.messages[0].data);
    try std.testing.expectEqual(@as(usize, 0), first.commonPrefix(second));
}

test "session snapshot compaction reorder and deletion obey index and content" {
    snapshot.reset();
    defer snapshot.reset();
    const items = integers(.{ 1, 2, 3, 4 });
    var original = try snapshot.prepare(a, &items);
    defer original.deinit();
    const reordered = integers(.{ 3, 1, 4 });
    var moved = try snapshot.prepare(a, &reordered);
    defer moved.deinit();
    try std.testing.expectEqual(@as(usize, 7), snapshot.stats().serializations);
    try std.testing.expectEqualStrings("3", moved.messages[0].data);
    try std.testing.expectEqualStrings("1", moved.messages[1].data);
    try std.testing.expectEqualStrings("4", moved.messages[2].data);
    var shortened = try snapshot.prepare(a, reordered[0..2]);
    defer shortened.deinit();
    try std.testing.expectEqual(@as(usize, 7), snapshot.stats().serializations);
    try std.testing.expectEqual(@as(usize, 2), moved.commonPrefix(shortened));
    const compacted = integers(.{ 9, 1 });
    var compact = try snapshot.prepare(a, &compacted);
    defer compact.deinit();
    try std.testing.expectEqual(@as(usize, 8), snapshot.stats().serializations);
    try std.testing.expectEqual(shortened.messages[1], compact.messages[1]);
    // The discarded suffix is not retained in an unbounded historical cache.
    const restored = integers(.{ 9, 1, 4 });
    var appended = try snapshot.prepare(a, &restored);
    defer appended.deinit();
    try std.testing.expectEqual(@as(usize, 9), snapshot.stats().serializations);
    try std.testing.expectEqualStrings("4", appended.messages[2].data);
}

test "session snapshot parts parse as ordinary JSON with exact array and padded head" {
    snapshot.reset();
    defer snapshot.reset();
    const parsed = try std.json.parseFromSlice(
        Value,
        a,
        "[{\"role\":\"user\",\"content\":\"line\\n\\\"quoted\\\"\"},null,[1,true]]",
        .{},
    );
    defer parsed.deinit();
    var s = try snapshot.prepare(a, parsed.value.array.items);
    defer s.deinit();
    try setMetadata(&s);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const header_capacity = s.header_end + 9000;
    const parts = try s.parts(arena.allocator(), header_capacity);
    const bytes = try std.mem.concat(a, u8, parts);
    defer a.free(bytes);
    const array = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    defer a.free(array);
    try std.testing.expectEqual(array.len, s.message_bytes);
    try std.testing.expectEqualStrings(array, bytes[header_capacity .. header_capacity + s.message_bytes]);
    for (bytes[s.header_end..header_capacity]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    const document = try std.json.parseFromSlice(Value, a, bytes, .{});
    defer document.deinit();
    const canonical = try std.json.Stringify.valueAlloc(a, document.value, .{});
    defer a.free(canonical);
    const expected = try std.fmt.allocPrint(a, "{{\"label\":\"fixture\",\"messages\":{s},\"revision\":4}}", .{array});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, canonical);
    try std.testing.expectEqual(header_capacity + 1, s.tailOffset(0, header_capacity));
    try std.testing.expectEqual(header_capacity + 1 + s.messages[0].data.len, s.tailOffset(1, header_capacity));
    try std.testing.expectEqual(@as(u8, ','), bytes[s.tailOffset(1, header_capacity)]);
    try std.testing.expectEqual(@as(u8, ','), bytes[s.tailOffset(2, header_capacity)]);
    try std.testing.expectEqual(header_capacity + s.message_bytes - 1, s.tailOffset(s.messages.len, header_capacity));
    try std.testing.expectEqual(@as(u8, ']'), bytes[s.tailOffset(s.messages.len, header_capacity)]);
}

test "session snapshot empty arrays metadata replacement and invalid capacity" {
    snapshot.reset();
    defer snapshot.reset();
    var s = try snapshot.prepare(a, &.{});
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidMetadata, s.parts(arena.allocator(), 0));
    try setMetadata(&s);
    try setMetadata(&s);
    try std.testing.expectError(error.HeaderCapacityTooSmall, s.parts(arena.allocator(), s.header_end - 1));
    const parts = try s.parts(arena.allocator(), s.header_end);
    const bytes = try std.mem.concat(a, u8, parts);
    defer a.free(bytes);
    try std.testing.expectEqualStrings(s.metadata, bytes);
    try std.testing.expectEqual(@as(usize, 2), s.message_bytes);
    try std.testing.expectEqual(s.header_end + 1, s.tailOffset(0, s.header_end));
    try std.testing.expectEqual(@as(usize, 0), snapshot.stats().serializations);
}

test "session snapshot old snapshots survive replacement reset and content comparison" {
    snapshot.reset();
    defer snapshot.reset();
    const items = integers(.{ 1, 2, 3 });
    var old = try snapshot.prepare(a, &items);
    defer old.deinit();
    try setMetadata(&old);
    const replacement = integers(.{ 8, 9 });
    var next = try snapshot.prepare(a, &replacement);
    defer next.deinit();
    snapshot.reset();
    try std.testing.expectEqualStrings("1", old.messages[0].data);
    try std.testing.expectEqualStrings("3", old.messages[2].data);
    try std.testing.expectEqualStrings("9", next.messages[1].data);
    var rebuilt = try snapshot.prepare(a, &items);
    defer rebuilt.deinit();
    try std.testing.expect(old.messages[0] != rebuilt.messages[0]);
    try std.testing.expectEqual(@as(usize, 3), old.commonPrefix(rebuilt));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parts = try old.parts(arena.allocator(), old.header_end);
    const bytes = try std.mem.concat(a, u8, parts);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{\"label\":\"fixture\",\"messages\":[1,2,3],\"revision\":4}", bytes);
}

test "session snapshot concurrent roots prepare reset and retain independent content" {
    snapshot.reset();
    defer snapshot.reset();
    const State = struct {
        items: [2]Value,
        expected: []const u8,
        failed: bool = false,

        fn run(self: *@This()) void {
            for (0..16) |i| {
                var s = snapshot.prepare(a, &self.items) catch {
                    self.failed = true;
                    return;
                };
                defer s.deinit();
                if (i % 2 == 0) snapshot.reset();
                _ = snapshot.stats();
                if (!std.mem.eql(u8, self.expected, s.messages[0].data)) self.failed = true;
            }
        }
    };
    var first: State = .{ .items = integers(.{ 11, 12 }), .expected = "11" };
    var second: State = .{ .items = integers(.{ 21, 22 }), .expected = "21" };
    const worker = try std.Thread.spawn(.{}, State.run, .{&first});
    second.run();
    worker.join();
    try std.testing.expect(!first.failed);
    try std.testing.expect(!second.failed);
}

test "session snapshot shared chunks can be retired on a worker" {
    snapshot.reset();
    defer snapshot.reset();
    const items = integers(.{ 1, 2, 3 });
    var worker_snapshot = try snapshot.prepare(a, &items);
    var worker_owns = false;
    errdefer if (!worker_owns) worker_snapshot.deinit();
    var retained = try snapshot.prepare(a, &items);
    defer retained.deinit();
    const Worker = struct {
        fn run(s: snapshot.Snapshot) void {
            var owned = s;
            owned.deinit();
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{worker_snapshot});
    worker_owns = true;
    defer worker.join();
    snapshot.reset();
    try std.testing.expectEqualStrings("1", retained.messages[0].data);
    try std.testing.expectEqualStrings("3", retained.messages[2].data);
}
