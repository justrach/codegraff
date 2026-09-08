//! Paste/drop separators and origin-gated file-path atoms (#792).
//!
//! A completed paste, drop, or file-picker insert leaves one trailing space
//! so the next item cannot concatenate onto the previous path. Marks record
//! paste/drop origin only — a typed lookalike stays ordinary text.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Insert one space at `cur` unless the previous byte is already whitespace.
pub fn ensureSpace(gpa: Allocator, buf: *std.ArrayList(u8), cur: *usize) void {
    if (cur.* == 0) return;
    if (buf.items[cur.* - 1] == ' ' or buf.items[cur.* - 1] == '\n' or buf.items[cur.* - 1] == '\t')
        return;
    buf.insert(gpa, cur.*, ' ') catch return;
    cur.* += 1;
}

pub fn ensureSpaceManaged(buf: *std.array_list.Managed(u8), cur: *usize) void {
    if (cur.* == 0) return;
    if (buf.items[cur.* - 1] == ' ' or buf.items[cur.* - 1] == '\n' or buf.items[cur.* - 1] == '\t')
        return;
    buf.insert(cur.*, ' ') catch return;
    cur.* += 1;
}

/// A single token that looks like a filesystem path (absolute, home, or `./`).
pub fn looksLikePath(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len < 2) return false;
    if (std.mem.indexOfAny(u8, t, " \n\t") != null) return false;
    if (t[0] == '/' or t[0] == '~') return true;
    if (t.len >= 2 and t[0] == '.' and t[1] == '/') return true;
    if (t.len >= 3 and t[1] == ':' and (t[2] == '\\' or t[2] == '/')) return true;
    return false;
}

/// If `cursor` sits at the end of, or inside, an origin mark, the mark start.
pub fn markLeft(items: []const u8, marks: []const []const u8, cursor: usize) ?usize {
    for (marks) |m| {
        if (m.len == 0 or cursor < m.len) continue;
        const start = cursor - m.len;
        if (start + m.len <= items.len and std.mem.eql(u8, items[start .. start + m.len], m))
            return start;
        if (cursor > 0 and cursor <= items.len) {
            // Cursor inside the mark: scan back for a match ending at/after cursor.
            var i: usize = 0;
            while (i + m.len <= items.len) : (i += 1) {
                if (!std.mem.eql(u8, items[i .. i + m.len], m)) continue;
                if (cursor > i and cursor <= i + m.len) return i;
            }
        }
    }
    return null;
}

pub fn markRight(items: []const u8, marks: []const []const u8, cursor: usize) ?usize {
    for (marks) |m| {
        if (m.len == 0) continue;
        var i: usize = 0;
        while (i + m.len <= items.len) : (i += 1) {
            if (!std.mem.eql(u8, items[i .. i + m.len], m)) continue;
            if (cursor >= i and cursor < i + m.len) return i + m.len;
        }
    }
    return null;
}

test "#792: ensureSpace adds one space, never a duplicate" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "hello");
    var cur: usize = buf.items.len;
    ensureSpace(gpa, &buf, &cur);
    try std.testing.expectEqualStrings("hello ", buf.items);
    ensureSpace(gpa, &buf, &cur);
    try std.testing.expectEqualStrings("hello ", buf.items);
}

test "#792: markLeft/Right are origin marks, not typed lookalikes" {
    const items = "/tmp/a /tmp/a";
    const marks = [_][]const u8{"/tmp/a"};
    try std.testing.expectEqual(@as(usize, 0), markLeft(items, &marks, 6).?);
    try std.testing.expectEqual(@as(usize, 6), markRight(items, &marks, 0).?);
    try std.testing.expect(looksLikePath("/tmp/a"));
    try std.testing.expect(looksLikePath("~/x"));
    try std.testing.expect(!looksLikePath("hello"));
    try std.testing.expect(!looksLikePath("/tmp/a /tmp/b"));
}
