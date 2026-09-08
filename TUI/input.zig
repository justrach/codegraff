//! Composer buffer. Soft-wrap lives in chrome; undo is Ctrl/Cmd+Z.

const std = @import("std");
const glyphs = @import("glyphs.zig");
const Key = @import("key.zig").Key;

const Snap = struct { text: []u8, cursor: usize };

pub const Input = struct {
    alloc: std.mem.Allocator,
    buf: std.array_list.Managed(u8),
    undo_stack: std.array_list.Managed(Snap),
    cursor: usize = 0,
    placeholder: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator) Input {
        return .{
            .alloc = alloc,
            .buf = std.array_list.Managed(u8).init(alloc),
            .undo_stack = std.array_list.Managed(Snap).init(alloc),
        };
    }

    pub fn deinit(self: *Input) void {
        for (self.undo_stack.items) |sn| self.alloc.free(sn.text);
        self.undo_stack.deinit();
        self.buf.deinit();
    }

    fn pushUndo(self: *Input) void {
        const text = self.alloc.dupe(u8, self.buf.items) catch return;
        self.undo_stack.append(.{ .text = text, .cursor = self.cursor }) catch {
            self.alloc.free(text);
            return;
        };
        if (self.undo_stack.items.len > 64) {
            const old = self.undo_stack.orderedRemove(0);
            self.alloc.free(old.text);
        }
    }

    /// Restore the previous snapshot. False when the stack is empty.
    pub fn undo(self: *Input) bool {
        const snap = self.undo_stack.pop() orelse return false;
        defer self.alloc.free(snap.text);
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(snap.text) catch {};
        self.cursor = @min(snap.cursor, self.buf.items.len);
        return true;
    }

    pub fn getValue(self: *const Input) []const u8 {
        return self.buf.items;
    }

    pub fn setValue(self: *Input, text: []const u8) !void {
        if (!std.mem.eql(u8, self.buf.items, text)) self.pushUndo();
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(text);
        self.cursor = self.buf.items.len;
    }

    pub fn insertSlice(self: *Input, text: []const u8) void {
        if (text.len == 0) return;
        self.cursor = scalarBoundary(self.buf.items, self.cursor);
        self.pushUndo();
        self.buf.insertSlice(self.cursor, text) catch return;
        self.cursor += text.len;
    }

    pub fn setPlaceholder(self: *Input, text: []const u8) void {
        self.placeholder = text;
    }

    pub fn handle(self: *Input, k: Key) void {
        switch (k) {
            .char => |c| {
                self.cursor = scalarBoundary(self.buf.items, self.cursor);
                // Raw terminal UTF-8 arrives one byte at a time. Continuation
                // bytes belong to the leading byte's edit, or undo could
                // restore a lone prefix and leave the draft malformed.
                if (c & 0xc0 != 0x80) self.pushUndo();
                self.buf.insert(self.cursor, c) catch return;
                self.cursor += 1;
            },
            .codepoint => |cp| {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &b) catch return;
                self.insertSlice(b[0..n]);
            },
            .backspace => {
                const end = scalarBoundary(self.buf.items, self.cursor);
                const start = prevScalar(self.buf.items, end);
                if (start == end) return;
                self.killRange(start, end);
                self.cursor = start;
            },
            .left => self.cursor = prevScalar(self.buf.items, self.cursor),
            .right => self.cursor = nextScalar(self.buf.items, self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = self.buf.items.len,
            .word_left => self.cursor = prevWord(self.buf.items, self.cursor),
            .word_right => self.cursor = nextWord(self.buf.items, self.cursor),
            .delete_word => self.killTo(prevWord(self.buf.items, self.cursor)),
            .delete_to_start => self.killTo(0),
            .delete_to_end => self.killRange(self.cursor, self.buf.items.len),
            .delete => {
                self.cursor = scalarBoundary(self.buf.items, self.cursor);
                self.killRange(self.cursor, nextScalar(self.buf.items, self.cursor));
            },
            .ctrl => |c| switch (c) {
                'a' => self.cursor = 0,
                'e' => self.cursor = self.buf.items.len,
                'k' => self.killRange(self.cursor, self.buf.items.len),
                'u' => self.killTo(0),
                'w' => self.killTo(prevWord(self.buf.items, self.cursor)),
                'd' => {
                    self.cursor = scalarBoundary(self.buf.items, self.cursor);
                    self.killRange(self.cursor, nextScalar(self.buf.items, self.cursor));
                },
                else => {},
            },
            else => {},
        }
    }

    fn killTo(self: *Input, at: usize) void {
        self.killRange(at, self.cursor);
        self.cursor = at;
    }

    fn killRange(self: *Input, from: usize, to: usize) void {
        if (from >= to or to > self.buf.items.len) return;
        self.pushUndo();
        var i = to;
        while (i > from) {
            i -= 1;
            _ = self.buf.orderedRemove(i);
        }
    }

    pub fn view(self: *const Input, a: std.mem.Allocator) ![]const u8 {
        var out = std.array_list.Managed(u8).init(a);
        if (self.buf.items.len == 0) {
            try out.appendSlice(self.placeholder);
            try out.appendSlice(glyphs.cursor);
            return out.items;
        }
        try out.appendSlice(self.buf.items[0..self.cursor]);
        try out.appendSlice(glyphs.cursor);
        try out.appendSlice(self.buf.items[self.cursor..]);
        return out.items;
    }
};

fn scalarBoundary(s: []const u8, cursor: usize) usize {
    var i = @min(cursor, s.len);
    while (i > 0 and i < s.len and s[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

fn prevScalar(s: []const u8, cursor: usize) usize {
    var i = scalarBoundary(s, cursor);
    if (i == 0) return 0;
    i -= 1;
    while (i > 0 and s[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

fn nextScalar(s: []const u8, cursor: usize) usize {
    var i = scalarBoundary(s, cursor);
    if (i >= s.len) return s.len;
    i += 1;
    while (i < s.len and s[i] & 0xc0 == 0x80) i += 1;
    return i;
}

fn prevWord(s: []const u8, cur: usize) usize {
    var i = cur;
    while (i > 0 and s[i - 1] == ' ') i -= 1;
    while (i > 0 and s[i - 1] != ' ') i -= 1;
    return i;
}

fn nextWord(s: []const u8, cur: usize) usize {
    var i = cur;
    while (i < s.len and s[i] != ' ') i += 1;
    while (i < s.len and s[i] == ' ') i += 1;
    return i;
}

test "insert and backspace" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    in.handle(.{ .char = 'h' });
    in.handle(.{ .char = 'i' });
    try std.testing.expectEqualStrings("hi", in.getValue());
    in.handle(.backspace);
    try std.testing.expectEqualStrings("h", in.getValue());
    in.insertSlice("éllo");
    try std.testing.expectEqualStrings("héllo", in.getValue());
}

test "cursor movement and deletion keep UTF-8 scalar boundaries" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    try in.setValue("aé日");
    in.handle(.left);
    try std.testing.expectEqual(@as(usize, 3), in.cursor);
    in.handle(.left);
    try std.testing.expectEqual(@as(usize, 1), in.cursor);
    in.handle(.{ .char = 'x' });
    try std.testing.expectEqualStrings("axé日", in.getValue());
    in.handle(.delete);
    try std.testing.expectEqualStrings("ax日", in.getValue());
    in.handle(.backspace);
    try std.testing.expectEqualStrings("a日", in.getValue());
}

test "cmd-delete and alt-backspace kill the line and the word" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    try in.setValue("one two three");
    in.cursor = in.buf.items.len;
    in.handle(.delete_word);
    try std.testing.expectEqualStrings("one two ", in.getValue());
    in.handle(.delete_to_start);
    try std.testing.expectEqualStrings("", in.getValue());
}

test "ctrl-z undoes the last edit" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    in.handle(.{ .char = 'h' });
    in.handle(.{ .char = 'i' });
    try std.testing.expect(in.undo());
    try std.testing.expectEqualStrings("h", in.getValue());
    try std.testing.expect(in.undo());
    try std.testing.expectEqualStrings("", in.getValue());
    try std.testing.expect(!in.undo());
}

test "raw UTF-8 bytes undo as one scalar edit" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    in.handle(.{ .char = 0xc3 });
    in.handle(.{ .char = 0xa9 });
    try std.testing.expectEqualStrings("é", in.getValue());
    try std.testing.expect(in.undo());
    try std.testing.expectEqualStrings("", in.getValue());
}

test "kitty codepoint inserts UTF-8" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    in.handle(.{ .codepoint = 0xe9 });
    try std.testing.expectEqualStrings("é", in.getValue());
}
