//! Inline Markdown shared by the live REPL and buffered lines.
const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const ansi = @import("ansi.zig");
const style = &ansi.style;
const markdown_url = @import("markdown_url.zig");

pub const State = enum { normal, star, underscore, bold_empty, under_empty, bold, under_bold, bold_star, under_end, code, italic, under_italic, escape };

pub fn byte(self: *Agent, w: *Io.Writer, b: u8) void {
    switch (self.md_span) {
        .normal => switch (b) {
            '*', '_' => {
                const word = self.md_word.items;
                if (markdown_url.containsHttp(word) or (b == '_' and word.len > 0 and (std.ascii.isAlphanumeric(word[word.len - 1]) or word[word.len - 1] == '_')))
                    self.mdWrapByte(w, b)
                else
                    self.md_span = if (b == '*') .star else .underscore;
            },
            '\\' => self.md_span = .escape,
            '`' => {
                self.mdStyle(w, style.yellow);
                self.md_span = .code;
            },
            else => self.mdWrapByte(w, b),
        },
        .star, .underscore => {
            const under = self.md_span == .underscore;
            const marker: u8 = if (under) '_' else '*';
            if (b == marker) {
                self.mdStyle(w, style.bold);
                self.md_span = if (under) .under_empty else .bold_empty;
            } else if (b == ' ' or b == '\t') {
                self.mdWrapByte(w, marker);
                self.md_span = .normal;
                self.mdSpanByte(w, b);
            } else {
                self.mdStyle(w, style.italic);
                self.md_span = if (under) .under_italic else .italic;
                self.mdSpanByte(w, b);
            }
        },
        .italic, .under_italic => {
            const marker: u8 = if (self.md_span == .under_italic) '_' else '*';
            if (b == marker) {
                self.mdStyle(w, style.reset);
                self.md_span = .normal;
            } else self.mdWrapByte(w, b);
        },
        .escape => {
            if (std.mem.indexOfScalar(u8, "*_`\\[]()#~", b) == null) self.mdWrapByte(w, '\\');
            self.mdWrapByte(w, b);
            self.md_span = .normal;
        },
        .bold_empty, .under_empty => {
            const under = self.md_span == .under_empty;
            if (b == @as(u8, if (under) '_' else '*')) {
                self.md_span = if (under) .under_end else .bold_star;
            } else {
                self.md_span = if (under) .under_bold else .bold;
                self.mdSpanByte(w, b);
            }
        },
        .bold, .under_bold => {
            const under = self.md_span == .under_bold;
            if (b == @as(u8, if (under) '_' else '*'))
                self.md_span = if (under) .under_end else .bold_star
            else
                self.mdWrapByte(w, b);
        },
        .bold_star, .under_end => {
            const under = self.md_span == .under_end;
            const marker: u8 = if (under) '_' else '*';
            if (b == marker) {
                self.mdStyle(w, style.reset);
                self.md_span = .normal;
            } else {
                self.mdWrapByte(w, marker);
                self.md_span = if (under) .under_bold else .bold;
                self.mdSpanByte(w, b);
            }
        },
        .code => if (b == '`') {
            self.mdStyle(w, style.reset);
            self.md_span = .normal;
        } else self.mdWrapByte(w, b),
    }
}

pub fn finish(self: *Agent, w: *Io.Writer) void {
    if (self.md_span == .star or self.md_span == .underscore) {
        self.mdWrapByte(w, if (self.md_span == .underscore) '_' else '*');
        self.md_span = .normal;
    }
    self.mdFlushWord(w);
    switch (self.md_span) {
        .normal => {},
        .escape => w.writeByte('\\') catch {},
        .star, .underscore => unreachable,
        .bold_empty, .under_empty => {
            w.writeAll(style.reset) catch {};
            w.writeAll(if (self.md_span == .under_empty) "__" else "**") catch {};
        },
        .bold, .under_bold, .code, .italic, .under_italic => w.writeAll(style.reset) catch {},
        .bold_star, .under_end => {
            w.writeByte(if (self.md_span == .under_end) '_' else '*') catch {};
            w.writeAll(style.reset) catch {};
        },
    }
    self.md_span = .normal;
}

pub fn render(w: *Io.Writer, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '*' or s[i] == '_' or s[i] == '~' or s[i] == '`' or s[i] == 'h') {
            var token_end = i;
            while (token_end < s.len and s[token_end] != ' ') token_end += 1;
            if (markdown_url.unwrapToken(s[i..token_end])) |match| {
                w.writeAll(match.url) catch {};
                w.writeAll(match.suffix) catch {};
                i = token_end;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "http://") or std.mem.startsWith(u8, s[i..], "https://")) {
                w.writeAll(s[i..token_end]) catch {};
                i = token_end;
                continue;
            }
        }
        if (s[i] == '\\' and i + 1 < s.len and std.mem.indexOfScalar(u8, "*_`\\[]()#~", s[i + 1]) != null) {
            w.writeByte(s[i + 1]) catch {};
            i += 2;
            continue;
        }
        if (markdown_url.emphasisAt(s, i)) |span| {
            w.print("{s}{s}{s}", .{ if (span.strong) style.bold else style.italic, s[span.start..span.end], style.reset }) catch {};
            i = span.after;
            continue;
        }
        if (s[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                w.print("{s}{s}{s}", .{ style.yellow, s[i + 1 .. end], style.reset }) catch {};
                i = end + 1;
                continue;
            }
        }
        w.writeByte(s[i]) catch {};
        i += 1;
    }
}

fn testStream(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    var agent: Agent = .{ .gpa = a, .arena = a, .io = std.testing.io, .client = undefined, .provider = undefined, .messages = .init(a), .sub = true, .label = "Markdown test", .out = &out.writer, .md_width = 200 };
    defer @import("agent_render.zig").deinitMarkdown(&agent);
    for (text) |b| agent.streamMarkdown(&.{b});
    agent.flushStreamTail();
    return out.written();
}

test "terminal markdown streams emphasis across individual byte deltas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const old = ansi.style;
    defer ansi.style = old;
    ansi.style = .harness;
    const text = try testStream(arena.allocator(), "*Coding agents / harnesses*: **ready** _next_ __strong__ `code_name` foo_bar\\*\n");
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[3mCoding agents / harnesses\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[1mready\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[3mnext\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[1mstrong\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "code_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "foo_bar*") != null);
}

test "terminal markdown preserves URL marker data and code contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const old = ansi.style;
    defer ansi.style = old;
    ansi.style = .{};
    const text = try testStream(arena.allocator(), "https://example.test/glob/** https://example.test/path/__ `*literal*`\\\n");
    try std.testing.expectEqualStrings("https://example.test/glob/** https://example.test/path/__ *literal*\\\n", text);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
}

test "terminal markdown buffered emphasis and visible widths agree" {
    const old = ansi.style;
    defer ansi.style = old;
    ansi.style = .{};
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const source = "*one* **two** _three_ __four__ foo_bar \\*five\\* `six`";
    const expected = "one two three four foo_bar *five* six";
    render(&out.writer, source);
    try std.testing.expectEqualStrings(expected, out.written());
    try std.testing.expectEqual(expected.len, markdown_url.inlineVisibleLen(source));
}
