//! Semantic long-paste spans for the raw readline composer (#673).
//!
//! The visible `[Pasted text …]` label is presentation, not identity. Each live
//! span owns its hidden body and tracks its byte range as surrounding text is
//! edited. An edit touching the range detaches it, so retyping the same label
//! cannot resurrect a removed paste.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Entry = struct {
    start: usize,
    end: usize,
    label: []u8,
    body: []u8,
};

pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,
    next_id: usize = 1,

    pub fn deinit(self: *Store, gpa: Allocator) void {
        self.clear(gpa);
        self.entries.deinit(gpa);
    }

    pub fn clear(self: *Store, gpa: Allocator) void {
        for (self.entries.items) |entry| freeEntry(gpa, entry);
        self.entries.clearRetainingCapacity();
    }

    pub fn count(self: *const Store) usize {
        return self.entries.items.len;
    }

    /// Insert one collapsed long paste at the cursor. Existing spans move with
    /// the surrounding text; the new span is inserted in positional order.
    pub fn insert(
        self: *Store,
        gpa: Allocator,
        buf: *std.ArrayList(u8),
        cursor: *usize,
        body: []const u8,
        lines: usize,
    ) !void {
        const label = try std.fmt.allocPrint(gpa, "[Pasted text #{d} +{d} lines]", .{ self.next_id, lines });
        errdefer gpa.free(label);
        const owned_body = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_body);
        try self.entries.ensureUnusedCapacity(gpa, 1);
        try buf.insertSlice(gpa, cursor.*, label);
        self.edited(gpa, cursor.*, cursor.*, label.len);
        self.entries.appendAssumeCapacity(.{
            .start = cursor.*,
            .end = cursor.* + label.len,
            .label = label,
            .body = owned_body,
        });
        std.mem.sort(Entry, self.entries.items, {}, lessThan);
        self.next_id += 1;
        cursor.* += label.len;
    }

    /// Update semantic ranges after replacing `[from,to)` with `inserted_len`
    /// bytes. Touching any part of a span detaches it; edits at either boundary
    /// remain ordinary surrounding edits.
    pub fn edited(self: *Store, gpa: Allocator, from: usize, to: usize, inserted_len: usize) void {
        std.debug.assert(from <= to);
        const removed_len = to - from;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (to <= entry.start) {
                shift(entry, removed_len, inserted_len);
                i += 1;
            } else if (from >= entry.end) {
                i += 1;
            } else {
                freeEntry(gpa, self.entries.orderedRemove(i));
            }
        }
    }

    /// Replace every live semantic span with its body, then consume the entries.
    /// Lookalike text without an entry is copied verbatim, and a stale/corrupt
    /// range is never expanded.
    pub fn expand(self: *Store, gpa: Allocator, buf: *std.ArrayList(u8)) !void {
        if (self.entries.items.len == 0) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var source: usize = 0;
        var expanded = false;
        for (self.entries.items) |entry| {
            if (entry.start < source or entry.end > buf.items.len) continue;
            if (!std.mem.eql(u8, buf.items[entry.start..entry.end], entry.label)) continue;
            try out.appendSlice(gpa, buf.items[source..entry.start]);
            try out.appendSlice(gpa, entry.body);
            source = entry.end;
            expanded = true;
        }
        if (!expanded) return;
        try out.appendSlice(gpa, buf.items[source..]);
        try buf.ensureTotalCapacity(gpa, out.items.len);
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, out.items);
        self.clear(gpa);
    }

    /// End byte for the live span beginning at `at`, used by readline's chip
    /// renderer. Position plus label validation prevents a typed lookalike at a
    /// different location from receiving attachment styling.
    pub fn highlightEndAt(self: *const Store, items: []const u8, at: usize) ?usize {
        for (self.entries.items) |entry| {
            if (entry.start != at or entry.end > items.len) continue;
            if (std.mem.eql(u8, items[entry.start..entry.end], entry.label)) return entry.end;
        }
        return null;
    }

    pub fn left(self: *const Store, cursor: usize) usize {
        for (self.entries.items) |entry| {
            if (cursor > entry.start and cursor <= entry.end) return entry.start;
        }
        return cursor -| 1;
    }

    pub fn right(self: *const Store, cursor: usize, len: usize) usize {
        for (self.entries.items) |entry| {
            if (cursor >= entry.start and cursor < entry.end) return entry.end;
        }
        return @min(cursor + 1, len);
    }

    pub fn prevWord(self: *const Store, items: []const u8, cursor: usize) usize {
        for (self.entries.items) |entry| {
            if (cursor > entry.start and cursor <= entry.end) return entry.start;
        }
        const plain = plainPrevWord(items, cursor);
        for (self.entries.items) |entry| {
            if (plain > entry.start and plain < entry.end) return entry.start;
        }
        return plain;
    }

    pub fn nextWord(self: *const Store, items: []const u8, cursor: usize) usize {
        for (self.entries.items) |entry| {
            if (cursor >= entry.start and cursor < entry.end) return entry.end;
        }
        const plain = plainNextWord(items, cursor);
        for (self.entries.items) |entry| {
            if (plain > entry.start and plain < entry.end) return entry.end;
        }
        return plain;
    }
};

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return a.start < b.start;
}

fn freeEntry(gpa: Allocator, entry: Entry) void {
    gpa.free(entry.label);
    gpa.free(entry.body);
}

fn shift(entry: *Entry, removed_len: usize, inserted_len: usize) void {
    if (inserted_len >= removed_len) {
        const delta = inserted_len - removed_len;
        entry.start += delta;
        entry.end += delta;
    } else {
        const delta = removed_len - inserted_len;
        entry.start -= delta;
        entry.end -= delta;
    }
}

fn plainPrevWord(items: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0 and items[i - 1] == ' ') i -= 1;
    while (i > 0 and items[i - 1] != ' ') i -= 1;
    return i;
}

fn plainNextWord(items: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i < items.len and items[i] == ' ') i += 1;
    while (i < items.len and items[i] != ' ') i += 1;
    return i;
}

fn deleteRange(buf: *std.ArrayList(u8), from: usize, to: usize) void {
    std.mem.copyForwards(u8, buf.items[from..], buf.items[to..]);
    buf.shrinkRetainingCapacity(buf.items.len - (to - from));
}

const testing = std.testing;

test "paste span is highlighted and navigated as one unit" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "before  after");
    var cursor: usize = 7;
    try store.insert(testing.allocator, &buf, &cursor, "one\ntwo", 2);
    const start: usize = 7;
    const end = cursor;

    try testing.expectEqual(end, store.highlightEndAt(buf.items, start).?);
    try testing.expectEqual(start, store.left(end));
    try testing.expectEqual(end, store.right(start, buf.items.len));
    try testing.expectEqual(start, store.prevWord(buf.items, end));
    try testing.expectEqual(end, store.nextWord(buf.items, start));
}

test "deleting a span prevents a typed lookalike from resurrecting its body" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var cursor: usize = 0;
    try store.insert(testing.allocator, &buf, &cursor, "secret\nbody", 2);
    const label = try testing.allocator.dupe(u8, buf.items);
    defer testing.allocator.free(label);

    store.edited(testing.allocator, 0, cursor, 0);
    deleteRange(&buf, 0, cursor);
    try buf.appendSlice(testing.allocator, label);
    store.edited(testing.allocator, 0, 0, label.len);
    try store.expand(testing.allocator, &buf);

    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expectEqualStrings(label, buf.items);
    try testing.expect(store.highlightEndAt(buf.items, 0) == null);
}

test "two paste spans expand independently exactly once" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var cursor: usize = 0;
    try store.insert(testing.allocator, &buf, &cursor, "alpha\nbeta", 2);
    try buf.insertSlice(testing.allocator, cursor, " + ");
    store.edited(testing.allocator, cursor, cursor, 3);
    cursor += 3;
    try store.insert(testing.allocator, &buf, &cursor, "gamma\ndelta", 2);
    try store.expand(testing.allocator, &buf);

    try testing.expectEqualStrings("alpha\nbeta + gamma\ndelta", buf.items);
}

test "removing one paste keeps and shifts the other" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var cursor: usize = 0;
    try store.insert(testing.allocator, &buf, &cursor, "first\nbody", 2);
    const first_end = cursor;
    try buf.insertSlice(testing.allocator, cursor, " ");
    store.edited(testing.allocator, cursor, cursor, 1);
    cursor += 1;
    try store.insert(testing.allocator, &buf, &cursor, "second\nbody", 2);

    store.edited(testing.allocator, 0, first_end, 0);
    deleteRange(&buf, 0, first_end);
    try store.expand(testing.allocator, &buf);

    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expectEqualStrings(" second\nbody", buf.items);
}

test "surrounding insertions shift a span without detaching it" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var cursor: usize = 0;
    try store.insert(testing.allocator, &buf, &cursor, "kept\nbody", 2);
    try buf.insertSlice(testing.allocator, 0, "prefix ");
    store.edited(testing.allocator, 0, 0, 7);
    try buf.appendSlice(testing.allocator, " suffix");
    store.edited(testing.allocator, buf.items.len - 7, buf.items.len - 7, 7);
    try store.expand(testing.allocator, &buf);

    try testing.expectEqualStrings("prefix kept\nbody suffix", buf.items);
}

test "typed duplicate beside a live span stays literal and unhighlighted" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var cursor: usize = 0;
    try store.insert(testing.allocator, &buf, &cursor, "real\nbody", 2);
    const label = try testing.allocator.dupe(u8, buf.items);
    defer testing.allocator.free(label);
    try buf.append(testing.allocator, ' ');
    try buf.appendSlice(testing.allocator, label);
    store.edited(testing.allocator, cursor, cursor, label.len + 1);

    try testing.expect(store.highlightEndAt(buf.items, cursor + 1) == null);
    try store.expand(testing.allocator, &buf);
    try testing.expectEqualStrings("real\nbody [Pasted text #1 +2 lines]", buf.items);
}

test "paste ids are not reused after an attachment is removed" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var cursor: usize = 0;
    try store.insert(testing.allocator, &buf, &cursor, "first\nbody", 2);
    store.edited(testing.allocator, 0, cursor, 0);
    deleteRange(&buf, 0, cursor);
    cursor = 0;
    try store.insert(testing.allocator, &buf, &cursor, "second\nbody", 2);

    try testing.expectEqualStrings("[Pasted text #2 +2 lines]", buf.items);
}

test "expansion consumes identity even when the body begins with its label" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var cursor: usize = 0;
    const body = "[Pasted text #1 +2 lines]\nX";
    try store.insert(testing.allocator, &buf, &cursor, body, 2);

    try store.expand(testing.allocator, &buf);
    try store.expand(testing.allocator, &buf);

    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expectEqualStrings(body, buf.items);
}
