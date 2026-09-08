//! Composer buffer. Soft-wrap lives in chrome; undo is Ctrl/Cmd+Z.

const std = @import("std");
const glyphs = @import("glyphs.zig");
const Key = @import("key.zig").Key;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const State = struct {
    text: []u8,
    cursor: usize,
    spans: []Span,
};

const Snap = State;
pub const Range = struct { start: usize, end: usize };

pub const Input = struct {
    alloc: std.mem.Allocator,
    buf: std.array_list.Managed(u8),
    spans: std.array_list.Managed(Span),
    undo_stack: std.array_list.Managed(Snap),
    cursor: usize = 0,
    placeholder: []const u8 = "",
    paste_start: ?usize = null,
    compound_edit: bool = false,
    compound_snapshot: bool = false,

    pub fn init(alloc: std.mem.Allocator) Input {
        return .{
            .alloc = alloc,
            .buf = std.array_list.Managed(u8).init(alloc),
            .spans = std.array_list.Managed(Span).init(alloc),
            .undo_stack = std.array_list.Managed(Snap).init(alloc),
        };
    }

    pub fn deinit(self: *Input) void {
        for (self.undo_stack.items) |sn| freeState(self.alloc, sn);
        self.undo_stack.deinit();
        self.spans.deinit();
        self.buf.deinit();
    }

    pub fn snapshot(self: *const Input) !State {
        const text = try self.alloc.dupe(u8, self.buf.items);
        errdefer self.alloc.free(text);
        return .{
            .text = text,
            .cursor = self.cursor,
            .spans = try self.alloc.dupe(Span, self.spans.items),
        };
    }

    pub fn freeSnapshot(self: *const Input, state: State) void {
        freeState(self.alloc, state);
    }

    pub fn setState(self: *Input, state: State) !void {
        self.pushUndo();
        try self.buf.ensureTotalCapacity(state.text.len);
        try self.spans.ensureTotalCapacity(state.spans.len);
        self.buf.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        try self.buf.appendSlice(state.text);
        try self.spans.appendSlice(state.spans);
        self.cursor = @min(state.cursor, self.buf.items.len);
        self.paste_start = null;
        self.compound_edit = false;
        self.compound_snapshot = false;
    }

    fn pushUndo(self: *Input) void {
        const snap = self.snapshot() catch return;
        self.undo_stack.append(snap) catch {
            freeState(self.alloc, snap);
            return;
        };
        if (self.undo_stack.items.len > 64) {
            freeState(self.alloc, self.undo_stack.orderedRemove(0));
        }
    }

    fn maybePushUndo(self: *Input) void {
        if (!self.compound_edit) {
            self.pushUndo();
        } else if (!self.compound_snapshot) {
            self.pushUndo();
            self.compound_snapshot = true;
        }
    }

    /// Restore the previous snapshot. False when the stack is empty.
    pub fn undo(self: *Input) bool {
        const snap = self.undo_stack.pop() orelse return false;
        defer freeState(self.alloc, snap);
        self.buf.ensureTotalCapacity(snap.text.len) catch return false;
        self.spans.ensureTotalCapacity(snap.spans.len) catch return false;
        self.buf.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.buf.appendSlice(snap.text) catch return false;
        self.spans.appendSlice(snap.spans) catch return false;
        self.cursor = @min(snap.cursor, self.buf.items.len);
        self.paste_start = null;
        self.compound_edit = false;
        self.compound_snapshot = false;
        return true;
    }

    pub fn getValue(self: *const Input) []const u8 {
        return self.buf.items;
    }

    pub fn semanticSpans(self: *const Input) []const Span {
        return self.spans.items;
    }

    pub fn spanEndAt(self: *const Input, at: usize) ?usize {
        for (self.spans.items) |span| {
            if (span.start == at and span.end <= self.buf.items.len) return span.end;
        }
        return null;
    }

    pub fn setValue(self: *Input, text: []const u8) !void {
        if (!std.mem.eql(u8, self.buf.items, text) or self.spans.items.len > 0) self.pushUndo();
        self.buf.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        try self.buf.appendSlice(text);
        self.cursor = self.buf.items.len;
        self.paste_start = null;
        self.compound_edit = false;
        self.compound_snapshot = false;
    }

    pub fn insertSlice(self: *Input, text: []const u8) void {
        if (text.len == 0) return;
        if (!self.replaceRange(self.cursor, self.cursor, text)) return;
        self.cursor += text.len;
    }

    pub fn beginPaste(self: *Input) void {
        if (self.paste_start != null) return;
        self.paste_start = self.cursor;
        self.compound_edit = true;
        self.compound_snapshot = false;
    }

    pub fn pasteRange(self: *const Input) ?Range {
        const start = self.paste_start orelse return null;
        if (self.cursor < start) return null;
        return .{ .start = start, .end = self.cursor };
    }

    pub fn endPaste(self: *Input) void {
        self.paste_start = null;
        self.compound_edit = false;
        self.compound_snapshot = false;
    }

    pub fn replacePaste(self: *Input, range: Range, text: []const u8, atomic: bool) bool {
        if (atomic) self.spans.ensureUnusedCapacity(1) catch return false;
        if (!self.replaceRange(range.start, range.end, text)) return false;
        self.cursor = range.start + text.len;
        if (atomic and text.len > 0) {
            self.spans.appendAssumeCapacity(.{ .start = range.start, .end = self.cursor });
            std.mem.sort(Span, self.spans.items, {}, spanLessThan);
        }
        return true;
    }

    /// The separator is ordinary text outside a semantic span: one Backspace
    /// removes it, and the next Backspace removes the whole pasted file.
    pub fn ensurePasteSeparator(self: *Input) void {
        if (self.cursor == 0) return;
        if (std.ascii.isWhitespace(self.buf.items[self.cursor - 1])) return;
        if (self.cursor < self.buf.items.len and std.ascii.isWhitespace(self.buf.items[self.cursor])) return;
        if (!self.replaceRange(self.cursor, self.cursor, " ")) return;
        self.cursor += 1;
    }

    pub fn setPlaceholder(self: *Input, text: []const u8) void {
        self.placeholder = text;
    }

    pub fn handle(self: *Input, k: Key) void {
        switch (k) {
            .char => |c| {
                var one = [_]u8{c};
                self.insertSlice(&one);
            },
            .codepoint => |cp| {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &b) catch return;
                self.insertSlice(b[0..n]);
            },
            .backspace => {
                if (self.cursor == 0) return;
                self.deleteAndLand(self.cursor - 1, self.cursor);
            },
            .left => self.cursor = self.left(self.cursor),
            .right => self.cursor = self.right(self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = self.buf.items.len,
            .word_left => self.cursor = self.prevWord(self.cursor),
            .word_right => self.cursor = self.nextWord(self.cursor),
            .delete_word => self.killTo(self.prevWord(self.cursor)),
            .delete_to_start => self.killTo(0),
            .delete_to_end => self.deleteAndLand(self.cursor, self.buf.items.len),
            .delete => self.deleteAndLand(self.cursor, if (self.cursor < self.buf.items.len) self.cursor + 1 else self.cursor),
            .ctrl => |c| switch (c) {
                'a' => self.cursor = 0,
                'e' => self.cursor = self.buf.items.len,
                'k' => self.deleteAndLand(self.cursor, self.buf.items.len),
                'u' => self.killTo(0),
                'w' => self.killTo(self.prevWord(self.cursor)),
                'd' => self.deleteAndLand(self.cursor, if (self.cursor < self.buf.items.len) self.cursor + 1 else self.cursor),
                else => {},
            },
            else => {},
        }
    }

    fn left(self: *const Input, cursor: usize) usize {
        for (self.spans.items) |span| {
            if (cursor > span.start and cursor <= span.end) return span.start;
        }
        return cursor -| 1;
    }

    fn right(self: *const Input, cursor: usize) usize {
        for (self.spans.items) |span| {
            if (cursor >= span.start and cursor < span.end) return span.end;
        }
        return @min(cursor + 1, self.buf.items.len);
    }

    fn prevWord(self: *const Input, cursor: usize) usize {
        for (self.spans.items) |span| {
            if (cursor > span.start and cursor <= span.end) return span.start;
        }
        const plain = plainPrevWord(self.buf.items, cursor);
        for (self.spans.items) |span| {
            if (plain > span.start and plain < span.end) return span.start;
        }
        return plain;
    }

    fn nextWord(self: *const Input, cursor: usize) usize {
        for (self.spans.items) |span| {
            if (cursor >= span.start and cursor < span.end) return span.end;
        }
        const plain = plainNextWord(self.buf.items, cursor);
        for (self.spans.items) |span| {
            if (plain > span.start and plain < span.end) return span.end;
        }
        return plain;
    }

    fn killTo(self: *Input, at: usize) void {
        self.deleteAndLand(at, self.cursor);
    }

    fn deleteAndLand(self: *Input, from: usize, to: usize) void {
        if (from >= to or to > self.buf.items.len) return;
        const expanded = self.expandRange(from, to);
        if (!self.replaceRange(expanded.start, expanded.end, "")) return;
        self.cursor = expanded.start;
    }

    fn expandRange(self: *const Input, from: usize, to: usize) Range {
        var out = Range{ .start = from, .end = to };
        var changed = true;
        while (changed) {
            changed = false;
            for (self.spans.items) |span| {
                if (out.start >= span.end or out.end <= span.start) continue;
                const start = @min(out.start, span.start);
                const end = @max(out.end, span.end);
                if (start != out.start or end != out.end) changed = true;
                out = .{ .start = start, .end = end };
            }
        }
        return out;
    }

    fn replaceRange(self: *Input, from: usize, to: usize, text: []const u8) bool {
        if (from > to or to > self.buf.items.len) return false;
        self.buf.ensureUnusedCapacity(text.len) catch return false;
        self.maybePushUndo();
        self.updateSpans(from, to, text.len);
        var i = to;
        while (i > from) {
            i -= 1;
            _ = self.buf.orderedRemove(i);
        }
        self.buf.insertSlice(from, text) catch unreachable;
        return true;
    }

    fn updateSpans(self: *Input, from: usize, to: usize, inserted_len: usize) void {
        const removed_len = to - from;
        var i: usize = 0;
        while (i < self.spans.items.len) {
            const span = &self.spans.items[i];
            if (to <= span.start) {
                shiftSpan(span, removed_len, inserted_len);
                i += 1;
            } else if (from >= span.end) {
                i += 1;
            } else {
                _ = self.spans.orderedRemove(i);
            }
        }
    }

    pub fn view(self: *const Input, a: std.mem.Allocator) ![]const u8 {
        return self.viewStyled(a, "", "");
    }

    pub fn viewStyled(self: *const Input, a: std.mem.Allocator, accent: []const u8, base: []const u8) ![]const u8 {
        var out = std.array_list.Managed(u8).init(a);
        errdefer out.deinit();
        if (self.buf.items.len == 0) {
            try out.appendSlice(self.placeholder);
            try out.appendSlice(glyphs.cursor);
            return out.toOwnedSlice();
        }
        var source: usize = 0;
        var cursor_drawn = false;
        for (self.spans.items) |span| {
            if (span.start < source or span.end > self.buf.items.len) continue;
            try appendCursorSlice(&out, self.buf.items[source..span.start], source, self.cursor, &cursor_drawn);
            if (!cursor_drawn and self.cursor == span.start) {
                try out.appendSlice(glyphs.cursor);
                cursor_drawn = true;
            }
            try out.appendSlice(accent);
            try appendCursorSlice(&out, self.buf.items[span.start..span.end], span.start, self.cursor, &cursor_drawn);
            try out.appendSlice(base);
            source = span.end;
        }
        try appendCursorSlice(&out, self.buf.items[source..], source, self.cursor, &cursor_drawn);
        if (!cursor_drawn) try out.appendSlice(glyphs.cursor);
        return out.toOwnedSlice();
    }
};

fn appendCursorSlice(
    out: *std.array_list.Managed(u8),
    text: []const u8,
    base: usize,
    cursor: usize,
    drawn: *bool,
) !void {
    if (!drawn.* and cursor >= base and cursor < base + text.len) {
        const at = cursor - base;
        try out.appendSlice(text[0..at]);
        try out.appendSlice(glyphs.cursor);
        try out.appendSlice(text[at..]);
        drawn.* = true;
    } else {
        try out.appendSlice(text);
    }
}

fn freeState(alloc: std.mem.Allocator, state: State) void {
    alloc.free(state.text);
    alloc.free(state.spans);
}

fn spanLessThan(_: void, a: Span, b: Span) bool {
    return a.start < b.start;
}

fn shiftSpan(span: *Span, removed_len: usize, inserted_len: usize) void {
    if (inserted_len >= removed_len) {
        const delta = inserted_len - removed_len;
        span.start += delta;
        span.end += delta;
    } else {
        const delta = removed_len - inserted_len;
        span.start -= delta;
        span.end -= delta;
    }
}

fn plainPrevWord(s: []const u8, cur: usize) usize {
    var i = cur;
    while (i > 0 and s[i - 1] == ' ') i -= 1;
    while (i > 0 and s[i - 1] != ' ') i -= 1;
    return i;
}

fn plainNextWord(s: []const u8, cur: usize) usize {
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
