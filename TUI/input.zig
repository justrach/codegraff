//! Composer buffer. Soft-wrap lives in chrome; undo is Ctrl/Cmd+Z.

const std = @import("std");
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
                self.pushUndo();
                self.buf.insert(self.cursor, c) catch return;
                self.cursor += 1;
            },
            .codepoint => |cp| {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &b) catch return;
                self.insertSlice(b[0..n]);
            },
            .backspace => {
                if (self.cursor == 0) return;
                self.pushUndo();
                _ = self.buf.orderedRemove(self.cursor - 1);
                self.cursor -= 1;
            },
            .left => self.cursor -|= 1,
            .right => {
                if (self.cursor < self.buf.items.len) self.cursor += 1;
            },
            .home => self.cursor = 0,
            .end => self.cursor = self.buf.items.len,
            .word_left => self.cursor = prevWord(self.buf.items, self.cursor),
            .word_right => self.cursor = nextWord(self.buf.items, self.cursor),
            .delete_word => self.killTo(prevWord(self.buf.items, self.cursor)),
            .delete_to_start => self.killTo(0),
            .delete_to_end => self.killRange(self.cursor, self.buf.items.len),
            .delete => self.killRange(self.cursor, if (self.cursor < self.buf.items.len) self.cursor + 1 else self.cursor),
            .ctrl => |c| switch (c) {
                'a' => self.cursor = 0,
                'e' => self.cursor = self.buf.items.len,
                'k' => self.killRange(self.cursor, self.buf.items.len),
                'u' => self.killTo(0),
                'w' => self.killTo(prevWord(self.buf.items, self.cursor)),
                'd' => self.killRange(self.cursor, if (self.cursor < self.buf.items.len) self.cursor + 1 else self.cursor),
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
            try out.appendSlice("▋");
            return out.items;
        }
        try out.appendSlice(self.buf.items[0..self.cursor]);
        try out.appendSlice("▋");
        try out.appendSlice(self.buf.items[self.cursor..]);
        return out.items;
    }
};

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

test "kitty codepoint inserts UTF-8" {
    var in = Input.init(std.testing.allocator);
    defer in.deinit();
    in.handle(.{ .codepoint = 0xe9 });
    try std.testing.expectEqualStrings("é", in.getValue());
}
