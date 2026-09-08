//! Origin-gated composer spans for the TUI (#792).
//!
//! Paste/drop file paths are atomic; a typed lookalike is ordinary text.

const std = @import("std");

fn ensureSpaceManaged(buf: *std.array_list.Managed(u8), cur: *usize) void {
    if (cur.* == 0) return;
    if (buf.items[cur.* - 1] == ' ' or buf.items[cur.* - 1] == '\n' or buf.items[cur.* - 1] == '\t')
        return;
    buf.insert(cur.*, ' ') catch return;
    cur.* += 1;
}

fn looksLikePath(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len < 2) return false;
    if (std.mem.indexOfAny(u8, t, " \n\t") != null) return false;
    if (t[0] == '/' or t[0] == '~') return true;
    if (t.len >= 2 and t[0] == '.' and t[1] == '/') return true;
    if (t.len >= 3 and t[1] == ':' and (t[2] == '\\' or t[2] == '/')) return true;
    return false;
}

pub const Kind = enum { paste, file };

pub const Entry = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,
    paste_from: ?usize = null,

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }

    pub fn beginPaste(self: *Store, cursor: usize) void {
        self.paste_from = cursor;
    }

    pub fn edited(self: *Store, from: usize, to: usize, inserted_len: usize) void {
        const removed = to - from;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = &self.entries.items[i];
            if (to <= e.start) {
                if (inserted_len >= removed) {
                    const d = inserted_len - removed;
                    e.start += d;
                    e.end += d;
                } else {
                    const d = removed - inserted_len;
                    e.start -= d;
                    e.end -= d;
                }
                i += 1;
            } else if (from >= e.end) {
                i += 1;
            } else {
                _ = self.entries.orderedRemove(i);
            }
        }
    }

    pub fn finishPaste(self: *Store, gpa: std.mem.Allocator, buf: *std.array_list.Managed(u8), cursor: *usize) void {
        const from = self.paste_from orelse return;
        self.paste_from = null;
        const to = cursor.*;
        if (to <= from or to > buf.items.len) return;
        const slice = buf.items[from..to];
        const kind: Kind = if (looksLikePath(slice)) .file else .paste;
        self.entries.append(gpa, .{ .start = from, .end = to, .kind = kind }) catch {};
        ensureSpaceManaged(buf, cursor);
    }

    pub fn insertFile(self: *Store, gpa: std.mem.Allocator, buf: *std.array_list.Managed(u8), cursor: *usize, path: []const u8) void {
        if (path.len == 0) return;
        const at = cursor.*;
        buf.insertSlice(at, path) catch return;
        cursor.* += path.len;
        self.edited(at, at, path.len);
        self.entries.append(gpa, .{ .start = at, .end = at + path.len, .kind = .file }) catch {};
        ensureSpaceManaged(buf, cursor);
    }

    pub fn left(self: *const Store, cursor: usize) usize {
        for (self.entries.items) |e| {
            if (cursor > e.start and cursor <= e.end) return e.start;
        }
        return cursor -| 1;
    }

    pub fn right(self: *const Store, cursor: usize, len: usize) usize {
        for (self.entries.items) |e| {
            if (cursor >= e.start and cursor < e.end) return e.end;
        }
        return @min(cursor + 1, len);
    }

    pub fn prevWord(self: *const Store, cursor: usize, fallback: usize) usize {
        for (self.entries.items) |e| {
            if (cursor > e.start and cursor <= e.end) return e.start;
        }
        return fallback;
    }

    pub fn nextWord(self: *const Store, cursor: usize, fallback: usize) usize {
        for (self.entries.items) |e| {
            if (cursor >= e.start and cursor < e.end) return e.end;
        }
        return fallback;
    }
};

test "#792: consecutive file inserts stay separated and atomic" {
    const gpa = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(gpa);
    defer buf.deinit();
    var cur: usize = 0;
    var store: Store = .{};
    defer store.deinit(gpa);
    store.insertFile(gpa, &buf, &cur, "/tmp/a");
    store.insertFile(gpa, &buf, &cur, "/tmp/b");
    try std.testing.expectEqualStrings("/tmp/a /tmp/b ", buf.items);
    try std.testing.expectEqual(@as(usize, 0), store.left(6));
    try std.testing.expectEqual(@as(usize, 6), store.right(0, buf.items.len));
}

/// After `finishPaste`, `got` is `payload` plus one trailing space unless
/// `payload` already ended in whitespace (or was empty).
pub fn expectComposer(got: []const u8, payload: []const u8) !void {
    if (payload.len == 0) {
        try std.testing.expectEqualStrings(payload, got);
        return;
    }
    const last = payload[payload.len - 1];
    if (last == ' ' or last == '\n' or last == '\t' or last == '\r') {
        try std.testing.expectEqualStrings(payload, got);
        return;
    }
    if (got.len == payload.len + 1 and got[payload.len] == ' ' and
        std.mem.eql(u8, got[0..payload.len], payload))
        return;
    try std.testing.expectEqualStrings(payload, got);
}

test "#792: a paste that already ends in space is not doubled" {
    const gpa = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(gpa);
    defer buf.deinit();
    try buf.appendSlice("hello ");
    var cur: usize = buf.items.len;
    var store: Store = .{};
    defer store.deinit(gpa);
    store.beginPaste(0);
    store.finishPaste(gpa, &buf, &cur);
    try std.testing.expectEqualStrings("hello ", buf.items);
}
