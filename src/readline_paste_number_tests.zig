const std = @import("std");
const Store = @import("readline_paste.zig").Store;

test "deleting the last paste reuses its id without relabeling survivors" {
    var store: Store = .{};
    defer store.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var cursor: usize = 0;

    const first_label = "[Pasted text #1 +2 lines]";
    const second_label = "[Pasted text #2 +2 lines]";

    try store.insert(allocator, &buf, &cursor, "first\nbody", 2);
    try std.testing.expectEqualStrings(first_label, buf.items);
    const first_end = cursor;

    try store.insert(allocator, &buf, &cursor, "second\nbody", 2);
    try std.testing.expectEqualStrings(first_label ++ second_label, buf.items);

    // Delete the entire final placeholder, then notify the store.
    const old_end = buf.items.len;
    buf.shrinkRetainingCapacity(first_end);
    cursor = first_end;
    store.edited(allocator, first_end, old_end, 0);

    try std.testing.expectEqualStrings(first_label, buf.items);

    try store.insert(allocator, &buf, &cursor, "replacement\nbody", 2);
    try std.testing.expectEqualStrings(first_label ++ second_label, buf.items);

    try store.expand(allocator, &buf);
    try std.testing.expectEqualStrings(
        "first\nbodyreplacement\nbody",
        buf.items,
    );
}

test "deleting all pastes restarts at id one and fills gaps without relabeling survivors" {
    var store: Store = .{};
    defer store.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var cursor: usize = 0;

    const first_label = "[Pasted text #1 +2 lines]";
    const second_label = "[Pasted text #2 +2 lines]";

    try store.insert(allocator, &buf, &cursor, "first\nbody", 2);
    try store.insert(allocator, &buf, &cursor, "second\nbody", 2);
    try std.testing.expectEqualStrings(first_label ++ second_label, buf.items);

    const old_end = buf.items.len;
    buf.clearRetainingCapacity();
    cursor = 0;
    store.edited(allocator, 0, old_end, 0);
    try std.testing.expectEqualStrings("", buf.items);

    try store.insert(allocator, &buf, &cursor, "new first\nbody", 2);
    try std.testing.expectEqualStrings(first_label, buf.items);

    try store.insert(allocator, &buf, &cursor, "survivor\nbody", 2);
    try std.testing.expectEqualStrings(first_label ++ second_label, buf.items);

    // Remove #1 while #2 survives. The next paste must fill the gap,
    // rather than incrementing the maximum id or renumbering #2.
    std.mem.copyForwards(
        u8,
        buf.items[0 .. buf.items.len - first_label.len],
        buf.items[first_label.len..],
    );
    buf.shrinkRetainingCapacity(buf.items.len - first_label.len);
    cursor = buf.items.len;
    store.edited(allocator, 0, first_label.len, 0);

    try std.testing.expectEqualStrings(second_label, buf.items);

    try store.insert(allocator, &buf, &cursor, "gap replacement\nbody", 2);
    try std.testing.expectEqualStrings(second_label ++ first_label, buf.items);

    try store.expand(allocator, &buf);
    try std.testing.expectEqualStrings(
        "survivor\nbodygap replacement\nbody",
        buf.items,
    );
}

test "clearing the store restarts paste ids and discards previous bodies" {
    var store: Store = .{};
    defer store.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var cursor: usize = 0;

    const first_label = "[Pasted text #1 +2 lines]";
    const second_label = "[Pasted text #2 +2 lines]";

    try store.insert(allocator, &buf, &cursor, "old first\nbody", 2);
    try store.insert(allocator, &buf, &cursor, "old second\nbody", 2);
    try std.testing.expectEqualStrings(first_label ++ second_label, buf.items);

    // Reset the input buffer and its associated paste store together.
    buf.clearRetainingCapacity();
    cursor = 0;
    store.clear(allocator);

    try store.insert(allocator, &buf, &cursor, "fresh first\nbody", 2);
    try std.testing.expectEqualStrings(first_label, buf.items);

    try store.insert(allocator, &buf, &cursor, "fresh second\nbody", 2);
    try std.testing.expectEqualStrings(first_label ++ second_label, buf.items);

    try store.expand(allocator, &buf);
    try std.testing.expectEqualStrings(
        "fresh first\nbodyfresh second\nbody",
        buf.items,
    );
}

const allocator = std.testing.allocator;

fn label(out: []u8, id: usize) ![]const u8 {
    return std.fmt.bufPrint(out, "[Pasted text #{d} +2 lines]", .{id});
}

fn insertAndCheck(
    store: *Store,
    buf: *std.ArrayList(u8),
    cursor: *usize,
    body: []const u8,
    expected_id: usize,
) !void {
    const start = cursor.*;
    try store.insert(allocator, buf, cursor, body, 2);

    var scratch: [80]u8 = undefined;
    const expected = try label(&scratch, expected_id);
    try std.testing.expectEqual(start + expected.len, cursor.*);
    try std.testing.expectEqualStrings(expected, buf.items[start..cursor.*]);
    try std.testing.expectEqual(
        @as(?usize, cursor.*),
        store.highlightEndAt(buf.items, start),
    );
}

fn replace(
    store: *Store,
    buf: *std.ArrayList(u8),
    from: usize,
    to: usize,
    text: []const u8,
) !void {
    try buf.replaceRange(allocator, from, to - from, text);
    store.edited(allocator, from, to, text.len);
}

test "middle gap reuses 2 without colliding with surviving 3" {
    var store: Store = .{};
    defer store.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var cursor: usize = 0;

    try insertAndCheck(&store, &buf, &cursor, "one\nONE", 1);
    const second_start = cursor;
    try insertAndCheck(&store, &buf, &cursor, "removed\nTWO", 2);
    const second_end = cursor;
    try insertAndCheck(&store, &buf, &cursor, "three\nTHREE", 3);

    try replace(&store, &buf, second_start, second_end, "");
    cursor = buf.items.len;
    try insertAndCheck(&store, &buf, &cursor, "replacement\nTWO", 2);

    try std.testing.expectEqualStrings(
        "[Pasted text #1 +2 lines]" ++
            "[Pasted text #3 +2 lines]" ++
            "[Pasted text #2 +2 lines]",
        buf.items,
    );

    try store.expand(allocator, &buf);
    const expected = "one\nONEthree\nTHREEreplacement\nTWO";
    try std.testing.expectEqualStrings(expected, buf.items);

    // Expansion consumes ownership; a second call must change nothing.
    try store.expand(allocator, &buf);
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "typed deleted label remains literal when its id is reused" {
    var store: Store = .{};
    defer store.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var cursor: usize = 0;

    const lookalike = "[Pasted text #1 +2 lines]";

    try insertAndCheck(&store, &buf, &cursor, "deleted\nSECRET", 1);
    try replace(&store, &buf, 0, buf.items.len, "");

    // Simulate ordinary typing, not a Store insertion.
    try replace(&store, &buf, 0, 0, lookalike);
    try std.testing.expectEqual(
        @as(?usize, null),
        store.highlightEndAt(buf.items, 0),
    );

    cursor = buf.items.len;
    const live_start = cursor;
    try insertAndCheck(&store, &buf, &cursor, "live\nBODY", 1);

    // Identical bytes have different semantics: only the second is owned.
    try std.testing.expectEqualStrings(lookalike ++ lookalike, buf.items);
    try std.testing.expectEqual(
        @as(?usize, null),
        store.highlightEndAt(buf.items, 0),
    );
    try std.testing.expectEqual(
        @as(?usize, buf.items.len),
        store.highlightEndAt(buf.items, live_start),
    );

    try store.expand(allocator, &buf);
    try std.testing.expectEqualStrings(lookalike ++ "live\nBODY", buf.items);

    // A surviving literal must not become expandable on a later call.
    try store.expand(allocator, &buf);
    try std.testing.expectEqualStrings(lookalike ++ "live\nBODY", buf.items);
}

test "reusing 9 preserves surviving 10 and correctly shifts byte spans" {
    var store: Store = .{};
    defer store.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    var cursor: usize = 0;
    var nine_start: usize = 0;
    var nine_end: usize = 0;

    for (1..11) |id| {
        const body = try std.fmt.allocPrint(
            allocator,
            "body-{d}\nEND-{d};",
            .{ id, id },
        );
        defer allocator.free(body);

        if (id == 9) nine_start = cursor;
        try insertAndCheck(&store, &buf, &cursor, body, id);
        if (id == 9) nine_end = cursor;
        if (id < 9) try expected.appendSlice(allocator, body);
    }

    // Removing 9 shifts the wider #10 span left.
    try replace(&store, &buf, nine_start, nine_end, "");
    var scratch: [80]u8 = undefined;
    const ten_label = try label(&scratch, 10);
    try std.testing.expectEqualStrings(ten_label, buf.items[nine_start..]);
    try std.testing.expectEqual(
        @as(?usize, buf.items.len),
        store.highlightEndAt(buf.items, nine_start),
    );

    // Inserting reused #9 before #10 must shift #10 back right.
    cursor = nine_start;
    try insertAndCheck(&store, &buf, &cursor, "new-nine\nEND-nine;", 9);
    const ten_start = cursor;
    try std.testing.expectEqualStrings(ten_label, buf.items[ten_start..]);
    try std.testing.expectEqual(
        @as(?usize, buf.items.len),
        store.highlightEndAt(buf.items, ten_start),
    );

    // With 1 through 10 occupied again, the next id must be 11.
    cursor = buf.items.len;
    try insertAndCheck(&store, &buf, &cursor, "eleven\nEND-eleven;", 11);

    try expected.appendSlice(
        allocator,
        "new-nine\nEND-nine;" ++
            "body-10\nEND-10;" ++
            "eleven\nEND-eleven;",
    );
    try store.expand(allocator, &buf);
    try std.testing.expectEqualStrings(expected.items, buf.items);
}
