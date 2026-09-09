//! Safe OSC 8 links for the editable composer.
//!
//! The transcript has its own Markdown renderer. The composer must preserve the
//! draft byte-for-byte, including cursor position, while making supported web
//! addresses clickable across application-inserted row breaks.

const std = @import("std");
const glyphs = @import("glyphs.zig");
const theme = @import("theme.zig");

const osc_open_prefix = "\x1b]8;id=graff-composer-";
const osc_close = "\x1b]8;;\x07";

const Link = struct {
    end: usize,
    www: bool,
};

const Found = struct {
    start: usize,
    link: Link,
};

/// Render the raw draft with its cursor and allowlisted OSC 8 spans. The cursor
/// is never part of the destination; when it bisects a link, the same link is
/// closed around the glyph and reopened on the other side.
pub fn inputView(a: std.mem.Allocator, value: []const u8, cursor: usize) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    const cur = cursorBoundary(value, cursor);
    var cursor_drawn = false;
    var i: usize = 0;
    while (nextLink(value, i)) |found| {
        try appendPlain(&out, value[i..found.start], i, cur, &cursor_drawn);
        try appendLinked(&out, value, found.start, found.link, cur, &cursor_drawn);
        i = found.link.end;
    }
    try appendPlain(&out, value[i..], i, cur, &cursor_drawn);
    if (!cursor_drawn) try out.appendSlice(glyphs.cursor);
    return out.toOwnedSlice();
}

const Row = struct {
    bytes: []const u8,
    active_at_start: ?[]const u8,
};

/// Word-wrap a composer body and retain only its visible tail. Generated links
/// are balanced on every retained row, so padding, borders, and independently
/// painted frames cannot inherit hyperlink state. Bounding before serialization
/// also keeps a pasted N-byte URL O(N): its full target is repeated at most
/// `max_rows` times, never once for every discarded continuation row.
pub fn wrap(a: std.mem.Allocator, body: []const u8, width: usize, max_rows: usize) ![]const u8 {
    if (max_rows == 0) return a.dupe(u8, "");
    const wrapped = try theme.wrapPreferWords(a, body, width);
    defer a.free(wrapped);
    var rows = std.array_list.Managed(Row).init(a);
    defer rows.deinit();
    var active: ?[]const u8 = null;
    var active_at_start: ?[]const u8 = null;
    var row_start: usize = 0;
    var i: usize = 0;
    while (i < wrapped.len) {
        if (wrapped[i] == '\n') {
            try keepRow(&rows, max_rows, .{ .bytes = wrapped[row_start..i], .active_at_start = active_at_start });
            row_start = i + 1;
            active_at_start = active;
            i += 1;
            continue;
        }
        if (wrapped[i] == 0x1b) {
            const end = theme.skipEsc(wrapped, i);
            noteLink(wrapped[i..end], &active);
            i = end;
            continue;
        }
        i += 1;
    }
    try keepRow(&rows, max_rows, .{ .bytes = wrapped[row_start..], .active_at_start = active_at_start });

    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    for (rows.items, 0..) |row, row_no| {
        var row_active = row.active_at_start;
        if (row_active) |open| try out.appendSlice(open);
        i = 0;
        while (i < row.bytes.len) {
            if (row.bytes[i] == 0x1b) {
                const end = theme.skipEsc(row.bytes, i);
                const seq = row.bytes[i..end];
                try out.appendSlice(seq);
                noteLink(seq, &row_active);
                i = end;
                continue;
            }
            try out.append(row.bytes[i]);
            i += 1;
        }
        if (row_active != null) try out.appendSlice(osc_close);
        if (row_no + 1 < rows.items.len) try out.append('\n');
    }
    return out.toOwnedSlice();
}

fn keepRow(rows: *std.array_list.Managed(Row), max_rows: usize, row: Row) !void {
    if (rows.items.len == max_rows) _ = rows.orderedRemove(0);
    try rows.append(row);
}

fn noteLink(seq: []const u8, active: *?[]const u8) void {
    if (std.mem.startsWith(u8, seq, osc_open_prefix)) {
        active.* = seq;
    } else if (active.* != null and std.mem.eql(u8, seq, osc_close)) {
        active.* = null;
    }
}

fn cursorBoundary(value: []const u8, cursor: usize) usize {
    var cur = @min(cursor, value.len);
    while (cur > 0 and cur < value.len and value[cur] & 0xc0 == 0x80) cur -= 1;
    return cur;
}

fn appendPlain(out: *std.array_list.Managed(u8), text: []const u8, base: usize, cursor: usize, drawn: *bool) !void {
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

fn appendLinked(out: *std.array_list.Managed(u8), value: []const u8, start: usize, link: Link, cursor: usize, drawn: *bool) !void {
    const split = !drawn.* and cursor >= start and cursor < link.end;
    if (!split or cursor > start) {
        try appendOpen(out, value[start..link.end], start, link.www);
        try out.appendSlice(value[start..if (split) cursor else link.end]);
        try out.appendSlice(osc_close);
    }
    if (split) {
        try out.appendSlice(glyphs.cursor);
        drawn.* = true;
        if (cursor < link.end) {
            try appendOpen(out, value[start..link.end], start, link.www);
            try out.appendSlice(value[cursor..link.end]);
            try out.appendSlice(osc_close);
        }
    }
}

fn appendOpen(out: *std.array_list.Managed(u8), visible: []const u8, id: usize, www: bool) !void {
    var id_buf: [32]u8 = undefined;
    const number = try std.fmt.bufPrint(&id_buf, "{d};", .{id});
    try out.appendSlice(osc_open_prefix);
    try out.appendSlice(number);
    if (www) try out.appendSlice("https://");
    try out.appendSlice(visible);
    try out.append(0x07);
}

fn nextLink(s: []const u8, from: usize) ?Found {
    var i = from;
    while (i < s.len) {
        const candidate = leftBoundary(s, i) and (startsIgnoreCase(s[i..], "http://") or startsIgnoreCase(s[i..], "https://") or startsIgnoreCase(s[i..], "www."));
        if (candidate) {
            if (linkAt(s, i)) |link| return .{ .start = i, .link = link };
            i = tokenEnd(s, i);
            continue;
        }
        i += 1;
    }
    return null;
}

fn linkAt(s: []const u8, start: usize) ?Link {
    if (!leftBoundary(s, start)) return null;
    const http_len: usize = if (startsIgnoreCase(s[start..], "https://")) 8 else if (startsIgnoreCase(s[start..], "http://")) 7 else 0;
    const www = http_len == 0 and startsIgnoreCase(s[start..], "www.");
    if (http_len == 0 and !www) return null;
    var end = tokenEnd(s, start);
    end = trimOuterDelimiters(s, start, end);
    if (end <= start + if (www) @as(usize, 4) else http_len) return null;
    if (www) {
        if (!validWwwHost(s[start + 4 .. authorityEnd(s, start + 4, end)])) return null;
    } else if (!validAuthority(s[start + http_len .. authorityEnd(s, start + http_len, end)])) {
        return null;
    }
    return .{ .end = end, .www = www };
}

fn leftBoundary(s: []const u8, start: usize) bool {
    if (start == 0) return true;
    const c = s[start - 1];
    if (c == '_') {
        var run = start - 1;
        while (run > 0 and s[run - 1] == '_') run -= 1;
        return run == 0 or !std.ascii.isAlphanumeric(s[run - 1]);
    }
    if (c >= 0x80 or std.ascii.isAlphanumeric(c)) return false;
    return std.mem.indexOfScalar(u8, ".-/:@%", c) == null;
}

fn tokenEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x20 or c == 0x7f or std.ascii.isWhitespace(c)) break;
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const step = @min(@as(usize, len), s.len - i);
        const cp = std.unicode.utf8Decode(s[i .. i + step]) catch {
            i += step;
            continue;
        };
        if (unicodeSpace(cp)) break;
        i += step;
    }
    return i;
}

fn unicodeSpace(cp: u21) bool {
    return cp == 0x00a0 or cp == 0x1680 or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000 or (cp >= 0x2000 and cp <= 0x200a);
}

fn trimOuterDelimiters(s: []const u8, start: usize, initial_end: usize) usize {
    var structural_end = initial_end;
    while (structural_end > start and std.mem.indexOfScalar(u8, ".,", s[structural_end - 1]) != null) structural_end -= 1;

    var wrapper_end = trimMatchingWrapper(s, start, structural_end);
    if (wrapper_end != structural_end) {
        while (wrapper_end > start and std.mem.indexOfScalar(u8, ".,", s[wrapper_end - 1]) != null) wrapper_end -= 1;
        return wrapper_end;
    }

    var end = structural_end;
    for ([_]struct { open: u8, close: u8 }{
        .{ .open = '(', .close = ')' },
        .{ .open = '[', .close = ']' },
        .{ .open = '{', .close = '}' },
    }) |pair| {
        const opens = countByte(s[start..end], pair.open);
        var closes = countByte(s[start..end], pair.close);
        while (end > start and s[end - 1] == pair.close and closes > opens) {
            end -= 1;
            closes -= 1;
        }
    }
    if (end != structural_end) return end;

    if (start > 0 and end > start) {
        const before = s[start - 1];
        if ((before == '<' and s[end - 1] == '>') or
            (before == '\'' and s[end - 1] == '\'') or
            (before == '"' and s[end - 1] == '"')) return end - 1;
    }
    return structural_end;
}

fn trimMatchingWrapper(s: []const u8, start: usize, initial_end: usize) usize {
    if (start == 0 or initial_end <= start) return initial_end;
    const mark = s[start - 1];
    if (std.mem.indexOfScalar(u8, "*_~`", mark) == null) return initial_end;
    var opens: usize = 0;
    var i = start;
    while (i > 0 and s[i - 1] == mark) : (i -= 1) opens += 1;
    var closes: usize = 0;
    i = initial_end;
    while (i > start and s[i - 1] == mark and closes < opens) : (i -= 1) closes += 1;
    return initial_end - closes;
}

fn authorityEnd(s: []const u8, start: usize, end: usize) usize {
    var i = start;
    while (i < end and std.mem.indexOfScalar(u8, "/?#", s[i]) == null) : (i += 1) {}
    return i;
}

fn validAuthority(authority: []const u8) bool {
    if (authority.len == 0) return false;
    for (authority) |c| if (c < 0x21 or c == 0x7f or std.mem.indexOfScalar(u8, "<>\"'", c) != null) return false;
    const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    return validHostPort(host_port, false);
}

fn validWwwHost(host_port: []const u8) bool {
    return validHostPort(host_port, true);
}

fn validHostPort(host_port: []const u8, require_dot: bool) bool {
    if (host_port.len == 0) return false;
    if (host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return false;
        if (close == 1 or !validIpv6(host_port[1..close])) return false;
        return close + 1 == host_port.len or (host_port[close + 1] == ':' and validPort(host_port[close + 2 ..]));
    }
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |at| host_port[0..at] else host_port;
    if (std.mem.indexOfScalar(u8, host, ':') != null or !validHost(host, require_dot)) return false;
    return if (colon) |at| validPort(host_port[at + 1 ..]) else true;
}

fn validHost(host: []const u8, require_dot: bool) bool {
    if (host.len == 0 or host.len > 253) return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        count += 1;
    }
    return !require_dot or count > 1;
}

fn validIpv6(host: []const u8) bool {
    _ = std.Io.net.IpAddress.parseIp6(host, 0) catch return false;
    return true;
}

fn validPort(port: []const u8) bool {
    if (port.len == 0) return false;
    for (port) |c| if (!std.ascii.isDigit(c)) return false;
    _ = std.fmt.parseInt(u16, port, 10) catch return false;
    return true;
}

fn startsIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn countByte(s: []const u8, needle: u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == needle) n += 1;
    }
    return n;
}

test "composer links allowlist web targets and preserve visible text" {
    const dump = @import("dump.zig");
    const cases = [_]struct { source: []const u8, target: ?[]const u8 }{
        .{ .source = "http://example.test/path", .target = "http://example.test/path" },
        .{ .source = "HTTPS://example.test/path", .target = "HTTPS://example.test/path" },
        .{ .source = "www.example.test/path", .target = "https://www.example.test/path" },
        .{ .source = "https://example.test/path.", .target = "https://example.test/path" },
        .{ .source = "**http://localhost:3003.**", .target = "http://localhost:3003" },
        .{ .source = "_https://example.test/path_", .target = "https://example.test/path" },
        .{ .source = "snake_case https://example.test/a_", .target = "https://example.test/a_" },
        .{ .source = "https://example.test/path(a)", .target = "https://example.test/path(a)" },
        .{ .source = "https://en.wikipedia.org/wiki/Yahoo!", .target = "https://en.wikipedia.org/wiki/Yahoo!" },
        .{ .source = "javascript:https://example.test", .target = null },
        .{ .source = "user@www.example.test", .target = null },
        .{ .source = "file:///tmp/a", .target = null },
        .{ .source = "https://:80/path", .target = null },
        .{ .source = "https://a.-b.example/path", .target = null },
        .{ .source = "https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example/path", .target = null },
        .{ .source = "https://[:::]/path", .target = null },
        .{ .source = "www.example.test:bad/path", .target = null },
        .{ .source = "www.", .target = null },
    };
    for (cases) |case| {
        const got = try inputView(std.testing.allocator, case.source, case.source.len);
        defer std.testing.allocator.free(got);
        const visible = try dump.visible(std.testing.allocator, got);
        defer std.testing.allocator.free(visible);
        try std.testing.expectEqual(case.source.len + glyphs.cursor.len, visible.len);
        try std.testing.expect(std.mem.startsWith(u8, visible, case.source));
        try std.testing.expect(std.mem.endsWith(u8, visible, glyphs.cursor));
        if (case.target) |target| {
            const needle = try std.fmt.allocPrint(std.testing.allocator, ";{s}\x07", .{target});
            defer std.testing.allocator.free(needle);
            try std.testing.expect(std.mem.indexOf(u8, got, needle) != null);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, osc_open_prefix));
        } else {
            try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, got, osc_open_prefix));
        }
    }
}

test "composer link cursor keeps the complete target and stays outside it" {
    const value = "https://example.test/a/long/path";
    const cursor = std.mem.indexOf(u8, value, "example").? + 3;
    const got = try inputView(std.testing.allocator, value, cursor);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, osc_open_prefix));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, value));
    try std.testing.expect(std.mem.indexOf(u8, got, osc_close ++ glyphs.cursor ++ osc_open_prefix) != null);
}

test "composer cursor snaps away from a UTF-8 continuation byte" {
    const dump = @import("dump.zig");
    const value = "https://example.test/é";
    const got = try inputView(std.testing.allocator, value, value.len - 1);
    defer std.testing.allocator.free(got);
    const visible = try dump.visible(std.testing.allocator, got);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("https://example.test/" ++ glyphs.cursor ++ "é", visible);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, osc_open_prefix));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, osc_close));
}

test "wrapped composer links are balanced on every retained physical row" {
    const value = "https://example.test/one/two/three/four/five/six/seven";
    const linked = try inputView(std.testing.allocator, value, value.len);
    defer std.testing.allocator.free(linked);
    const got = try wrap(std.testing.allocator, linked, 12, 8);
    defer std.testing.allocator.free(got);
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |row| {
        if (std.mem.indexOf(u8, row, osc_open_prefix) == null) continue;
        rows += 1;
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, row, osc_open_prefix));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, row, osc_close));
        try std.testing.expect(theme.visibleLen(row) <= 12);
    }
    try std.testing.expect(rows > 2);
}

test "long composer links stay linear before the eight-row window" {
    var value_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer value_buf.deinit();
    try value_buf.appendSlice("https://example.test/");
    try value_buf.appendNTimes('a', 10_000);
    const value = value_buf.items;
    const linked = try inputView(std.testing.allocator, value, value.len);
    defer std.testing.allocator.free(linked);
    const got = try wrap(std.testing.allocator, linked, 38, 8);
    defer std.testing.allocator.free(got);
    try std.testing.expect(got.len < value.len * 10);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, got, osc_open_prefix));
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, got, osc_close));
}

test "malformed repeated link candidates are scanned once" {
    var value_buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer value_buf.deinit();
    for (0..2_000) |_| try value_buf.appendSlice("(www.");
    const value = value_buf.items;
    const got = try inputView(std.testing.allocator, value, value.len);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, got, osc_open_prefix));
    try std.testing.expectEqual(value.len + glyphs.cursor.len, got.len);
}
