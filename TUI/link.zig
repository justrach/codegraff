//! Allowlisted composer hyperlinks (#788).
//!
//! `wrapPreferWords` inserts physical newlines. Without OSC 8, a terminal
//! treats each visual row as its own autodetect target, so a wrapped URL
//! modifier-clicks only the prefix. Emit one OSC 8 span for the unbroken
//! token so continuation rows keep the same target.

const std = @import("std");
const glyphs = @import("glyphs.zig");
const theme = @import("theme.zig");

const osc_open = "\x1b]8;;";
const osc_close = "\x1b]8;;\x07";

fn isUrlByte(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '-', '_', '.', '~', '/', '?', '#', '%', '&', '=', '+', ':', '@' => true,
        else => false,
    };
}

fn tokenAt(s: []const u8, i: usize) ?[]const u8 {
    if (i >= s.len) return null;
    if (std.mem.startsWith(u8, s[i..], "https://") or
        std.mem.startsWith(u8, s[i..], "http://") or
        std.mem.startsWith(u8, s[i..], "www."))
    {
        var end = i;
        while (end < s.len and isUrlByte(s[end])) end += 1;
        while (end > i and (s[end - 1] == '.' or s[end - 1] == ',' or s[end - 1] == ')' or s[end - 1] == ';')) end -= 1;
        return s[i..end];
    }
    return null;
}

fn writeHref(out: *std.array_list.Managed(u8), token: []const u8) !void {
    if (std.mem.startsWith(u8, token, "www.")) {
        try out.appendSlice("https://");
        try out.appendSlice(token);
        return;
    }
    try out.appendSlice(token);
}

/// Wrap allowlisted URL tokens in OSC 8. Chips (`[Image #N]`, `[Pasted text`)
/// and `@` mentions are left alone. `http://`, `https://`, and `www.` only.
pub fn linkify(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i, ']')) |end| {
                try out.appendSlice(text[i .. end + 1]);
                i = end + 1;
                continue;
            }
        }
        if (tokenAt(text, i)) |tok| {
            const at_boundary = i == 0 or !isUrlByte(text[i - 1]);
            if (at_boundary) {
                try out.appendSlice(osc_open);
                try writeHref(&out, tok);
                try out.append(0x07);
                try out.appendSlice(tok);
                try out.appendSlice(osc_close);
                i += tok.len;
                continue;
            }
        }
        try out.append(text[i]);
        i += 1;
    }
    return try out.toOwnedSlice();
}

/// `linkify` plus the composer caret at `cursor` in the raw buffer.
pub fn linkifyView(a: std.mem.Allocator, text: []const u8, cursor: usize) ![]u8 {
    const cur = @min(cursor, text.len);
    const linked = try linkify(a, text);
    defer a.free(linked);
    // Map raw cursor → linked by counting visible bytes (OSC skipped).
    var raw: usize = 0;
    var vis: usize = 0;
    while (vis < linked.len and raw < cur) {
        if (linked[vis] == 0x1b and vis + 1 < linked.len and linked[vis + 1] == ']') {
            while (vis < linked.len and linked[vis] != 0x07) vis += 1;
            if (vis < linked.len) vis += 1;
            continue;
        }
        vis += 1;
        raw += 1;
    }
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(linked[0..vis]);
    try out.appendSlice(glyphs.cursor);
    try out.appendSlice(linked[vis..]);
    return try out.toOwnedSlice();
}

test "#788: https and www tokens become one OSC 8 target" {
    const a = std.testing.allocator;
    const https = try linkify(a, "see https://example.com/a/very/long/path please");
    defer a.free(https);
    try std.testing.expect(std.mem.indexOf(u8, https, "\x1b]8;;https://example.com/a/very/long/path\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, https, osc_close) != null);

    const www = try linkify(a, "www.example.com/docs");
    defer a.free(www);
    try std.testing.expect(std.mem.indexOf(u8, www, "\x1b]8;;https://www.example.com/docs\x07www.example.com/docs") != null);
}

test "#788: wrapPreferWords keeps the same OSC target across a wrap" {
    const a = std.testing.allocator;
    const url = "https://example.com/this/is/a/long/path/for/wrap";
    const linked = try linkify(a, url);
    defer a.free(linked);
    const wrapped = try theme.wrapPreferWords(a, linked, 18);
    defer a.free(wrapped);
    try std.testing.expect(std.mem.indexOfScalar(u8, wrapped, '\n') != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\x1b]8;;https://example.com/this/is/a/long/path/for/wrap\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, osc_close) != null);
}

test "#788: chips and javascript: are not linkified" {
    const a = std.testing.allocator;
    const chip = try linkify(a, "[Image #1] javascript:alert(1)");
    defer a.free(chip);
    try std.testing.expect(std.mem.indexOf(u8, chip, osc_open) == null);
    try std.testing.expectEqualStrings("[Image #1] javascript:alert(1)", chip);
}
