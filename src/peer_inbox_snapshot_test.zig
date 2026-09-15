//! Adversarial mailbox snapshots through the session serialization boundary.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const inbox = @import("peer_inbox.zig");
const session = @import("session_peer.zig");
const presence = @import("presence.zig");
const main = @import("main.zig");
const Fingerprint = @import("session_writer.zig").Fingerprint;
const util = @import("util.zig");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    unattended: bool,

    fn init() Fixture {
        const old = main.unattended;
        main.unattended = false;
        inbox.setStorageAllocatorForTest(testing.allocator);
        presence.resetRoomCursorForTest();
        return .{ .arena = .init(testing.allocator), .unattended = old };
    }

    fn deinit(self: *Fixture) void {
        inbox.setStorageAllocatorForTest(std.heap.page_allocator);
        presence.resetRoomCursorForTest();
        main.unattended = self.unattended;
        self.arena.deinit();
    }

    fn restore(self: *Fixture, value: Value) void {
        // Exercise mailbox dispatch without markCaughtUp's private channel
        // latch: cursor dispatch has separate session_peer coverage.
        var obj = value.object;
        _ = obj.swapRemove("chan_off");
        _ = obj.swapRemove("device_off");
        var root: Agent = undefined;
        root.arena = self.arena.allocator();
        root.io = testing.io;
        root.messages = std.json.Array.init(root.arena);
        session.restore(&root, obj);
    }

    fn parse(self: *Fixture, text: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, self.arena.allocator(), text, .{ .allocate = .alloc_always });
    }

    fn save(self: *Fixture) !Value {
        var aw: std.Io.Writer.Allocating = .init(self.arena.allocator());
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try session.writeFields(&s);
        try s.endObject();
        return self.parse(aw.writer.buffered());
    }
};

fn fingerprint() u64 {
    var f = Fingerprint.init();
    session.mixFingerprint(&f);
    return f.final();
}

test "peer inbox snapshot: malformed entries do not consume capacity or count as evictions" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    var source = try fixture.parse("{\"peer_inbox\":[],\"peer_inbox_dropped\":4}");
    const items = &source.object.getPtr("peer_inbox").?.array;
    const malformed = try fixture.parse("[null,7,false,[],{}, {\"from\":9,\"text\":\"bad\"},{\"from\":\"bad\",\"text\":null},{\"from\":\"missing text\"},{\"text\":\"missing sender\"}]");
    for (0..inbox.inbox_cap + 3) |i| {
        for (malformed.array.items) |bad| try items.append(bad);
        const raw = try std.fmt.allocPrint(fixture.arena.allocator(), "{{\"from\":\"peer\",\"text\":\"{d}\"}}", .{i});
        try items.append(try fixture.parse(raw));
    }
    fixture.restore(source);
    try testing.expectEqual(inbox.inbox_cap, inbox.unread());
    try testing.expectEqual(@as(usize, 7), inbox.dropped());
    const saved = try fixture.save();
    for (saved.object.get("peer_inbox").?.array.items, 3..) |item, i| {
        const expected = try std.fmt.allocPrint(fixture.arena.allocator(), "{d}", .{i});
        try testing.expectEqualStrings(expected, item.object.get("text").?.string);
    }
}

test "peer inbox snapshot: empty and escaped bytes survive and invalid flags default false" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const source = try fixture.parse(
        \\{"peer_inbox":[{"from":"","text":""},{"from":"a\u0000\n\t\u00e9\ud83d\ude80","text":"\u0000\u0001\b\f\n\r\t\"\\\u96ea\ud83d\ude80","dm":"true","device":1},{"from":"peer","text":"flags","dm":null,"device":{}},{"from":"peer","text":"true flags","dm":true,"device":true}]}
    );
    fixture.restore(source);
    for (0..3) |_| {
        const saved = try fixture.save();
        const items = saved.object.get("peer_inbox").?.array.items;
        try testing.expectEqual(@as(usize, 4), items.len);
        for (items, source.object.get("peer_inbox").?.array.items, 0..) |item, original, i| {
            try testing.expectEqualStrings(original.object.get("from").?.string, item.object.get("from").?.string);
            try testing.expectEqualStrings(original.object.get("text").?.string, item.object.get("text").?.string);
            try testing.expectEqual(i == 3, item.object.get("dm").?.bool);
            try testing.expectEqual(i == 3, item.object.get("device").?.bool);
        }
        try testing.expectEqualStrings("a\x00\n\té🚀", items[1].object.get("from").?.string);
        try testing.expectEqualStrings("\x00\x01\x08\x0c\n\r\t\"\\雪🚀", items[1].object.get("text").?.string);
        fixture.restore(saved);
    }
}

test "peer inbox snapshot: unsigned dropped count is stable through repeated saves and restores" {
    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    var fixture = Fixture.init();
    defer fixture.deinit();
    fixture.restore(try fixture.parse("{\"peer_inbox\":[],\"peer_inbox_dropped\":18446744073709551614}"));
    const expected: usize = std.math.maxInt(usize) - 1;
    const initial = fingerprint();
    for (0..5) |_| {
        try testing.expectEqual(expected, inbox.dropped());
        try testing.expectEqual(@as(usize, 0), inbox.unread());
        const saved = try fixture.save();
        try testing.expectEqualStrings("18446744073709551614", saved.object.get("peer_inbox_dropped").?.number_string);
        fixture.restore(saved);
        try testing.expectEqual(expected, inbox.dropped());
        try testing.expectEqual(initial, fingerprint());
    }
}

test "peer inbox snapshot: fingerprints cover suffixes flags and dropped-only changes" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const a = fixture.arena.allocator();
    const body = &util.repeatBytes("b", 220);
    const sender = &util.repeatBytes("s", 60);
    var hashes: [6]u64 = undefined;
    for (&hashes, 0..) |*hash, i| {
        const raw = try std.fmt.allocPrint(a, "{{\"peer_inbox\":[{{\"from\":\"{s}{s}\",\"text\":\"{s}{s}\",\"dm\":{s},\"device\":{s}}}],\"peer_inbox_dropped\":{d}}}", .{ sender, if (i == 1) "X" else "A", body, if (i == 2) "X" else "A", if (i == 3) "true" else "false", if (i == 4) "true" else "false", @as(usize, if (i == 5) 1 else 0) });
        fixture.restore(try fixture.parse(raw));
        hash.* = fingerprint();
        const saved = try fixture.save();
        inbox.clear();
        fixture.restore(saved);
        try testing.expectEqual(hash.*, fingerprint());
        for (hashes[0..i]) |previous| try testing.expect(previous != hash.*);
    }
}
