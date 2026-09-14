//! Seeded state-machine regression for ADR 0111. The oracle is a plain FIFO
//! of immutable corpus entries, not a second ring or a read from the inbox.
const std = @import("std");
const testing = std.testing;
const inbox = @import("peer_inbox.zig");
const Message = @import("presence_chan.zig").Message;
const util = @import("util.zig");

const Entry = struct { from: []const u8, text: []const u8, dm: bool, device: bool };
const senders = [_][]const u8{ "", " \t\r\n", "zero\x00sender", "sender-" ++ util.repeatBytes("長🙂", 20) };
const bodies = [_][]const u8{ "", "\x00", " \t\r\n  ", "BEGIN\n" ++ util.repeatBytes("complete🙂 payload\n", 50) ++ "END \t" };
const flags = [_][]const u8{ "", " · DM", " · device", " · device DM" };

const Model = struct {
    queue: std.ArrayList(Entry) = .empty,
    lost: usize = 0,

    fn clear(self: *Model) void {
        self.queue.clearRetainingCapacity();
        self.lost = 0;
    }

    fn append(self: *Model, entry: Entry) !void {
        // Deliberately use a shifting list and the specified capacity, not the
        // production head/length arithmetic or its capacity constant.
        if (self.queue.items.len == 8) {
            _ = self.queue.orderedRemove(0);
            self.lost += 1;
        }
        try self.queue.append(testing.allocator, entry);
    }

    fn check(self: *const Model, a: std.mem.Allocator) !void {
        try testing.expectEqual(self.queue.items.len, inbox.unread());
        try testing.expectEqual(self.lost, inbox.dropped());
        try testing.expectEqual(self.queue.items.len != 0 or self.lost != 0, inbox.pending());
        const saved = try snapshot(a);
        try testing.expectEqual(self.queue.items.len, saved.array.items.len);
        for (self.queue.items, saved.array.items) |entry, value| {
            const obj = value.object;
            try testing.expectEqualStrings(entry.from, obj.get("from").?.string);
            try testing.expectEqualStrings(entry.text, obj.get("text").?.string);
            try testing.expectEqual(entry.dm, obj.get("dm").?.bool);
            try testing.expectEqual(entry.device, obj.get("device").?.bool);
        }
    }

    fn read(self: *Model, a: std.mem.Allocator) !void {
        var expected: std.Io.Writer.Allocating = .init(a);
        defer expected.deinit();
        if (self.queue.items.len == 0 and self.lost == 0) {
            try expected.writer.writeAll("inbox empty");
        } else {
            if (self.lost != 0) try expected.writer.print("[peer inbox: {d} dropped message(s) could not be retained; the room log keeps the originals]\n", .{self.lost});
            for (self.queue.items) |entry| {
                const flag: usize = @as(usize, @intFromBool(entry.dm)) + 2 * @as(usize, @intFromBool(entry.device));
                try expected.writer.print("[peer message from {s}{s}]: {s}\n", .{ entry.from, flags[flag], entry.text });
            }
            try expected.writer.writeAll("(inbox cleared — reply with peer_message; omit session for the room, or name one peer to DM)");
        }
        try testing.expectEqualStrings(expected.writer.buffered(), try inbox.takeAll(a));
        self.clear();
        try self.check(a);
    }
};

fn snapshot(a: std.mem.Allocator) !std.json.Value {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try inbox.writeJson(&json);
    return std.json.parseFromSliceLeaky(std.json.Value, a, out.writer.buffered(), .{ .allocate = .alloc_always });
}

fn next(state: *u64) usize {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return @intCast(state.* >> 32);
}

fn parkBatch(model: *Model, state: *u64, count: usize) !void {
    for (0..count) |_| {
        // Every batch mixes local and device traffic; independently chosen
        // target bits exercise all four flag combinations, including empties.
        const local = Entry{ .from = senders[next(state) % 4], .text = bodies[next(state) % 4], .dm = next(state) % 2 != 0, .device = false };
        const device = Entry{ .from = senders[next(state) % 4], .text = bodies[next(state) % 4], .dm = next(state) % 2 != 0, .device = true };
        const lm = Message{ .from_session = local.from, .text = local.text, .to = if (local.dm) "recipient" else "" };
        const dm = Message{ .from_session = device.from, .text = device.text, .to = if (device.dm) "recipient" else "" };
        try testing.expectEqual(@as(usize, 2), inbox.parkHeard(&.{lm}, &.{dm}));
        try model.append(local);
        try model.append(device);
    }
}

test "peer inbox sequence: seeded FIFO oracle across overflow persistence failed reads and retry" {
    inbox.setStorageAllocatorForTest(testing.allocator);
    defer inbox.setStorageAllocatorForTest(std.heap.page_allocator);
    for ([_]u64{ 1, 865, 893, 0xdeadbeefcafef00d }) |seed| {
        inbox.clear();
        var model: Model = .{};
        defer model.queue.deinit(testing.allocator);
        var state = seed;
        for (0..240) |step| {
            // All temporary snapshots/results are reclaimed every transition;
            // the oracle and inbox retain only eight bounded corpus entries.
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            // A scripted prefix guarantees each transition, then seeded mixes
            // explore differing queue occupancy and histories of loss.
            const op = if (step < 10) step else next(&state) % 10;
            switch (op) {
                0, 1, 2, 3 => try parkBatch(&model, &state, 1 + next(&state) % 13),
                4 => {
                    const saved = try snapshot(a);
                    const loss_json = try std.json.Stringify.valueAlloc(a, model.lost, .{});
                    const loss = try std.json.parseFromSliceLeaky(std.json.Value, a, loss_json, .{});
                    inbox.clear();
                    inbox.restoreJson(saved);
                    inbox.restoreDropped(loss);
                },
                5 => {
                    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
                    if (model.queue.items.len != 0 or model.lost != 0) {
                        try testing.expectError(error.OutOfMemory, inbox.takeAll(failing.allocator()));
                        try testing.expect(failing.has_induced_failure);
                        try model.check(a);
                    } else {
                        try testing.expectEqualStrings("inbox empty", try inbox.takeAll(failing.allocator()));
                        try testing.expect(!failing.has_induced_failure);
                    }
                    try model.read(a);
                },
                6 => try model.read(a),
                7 => {
                    inbox.clear();
                    model.clear();
                },
                8 => {
                    const loss = next(&state) % 17;
                    inbox.restoreDropped(.{ .integer = @intCast(loss) });
                    model.lost += loss;
                },
                9 => try testing.expectEqual(@as(usize, 0), inbox.parkHeard(&.{}, &.{})),
                else => unreachable,
            }
            try model.check(a);
        }
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try model.read(arena.allocator());
    }
}
