//! Theme slots as fixed SGR string literals (never padded rgb buffers).

const std = @import("std");

pub const Id = enum {
    night,
    day,
    tokyo,
    rose,
    oscura,

    pub fn label(self: Id) []const u8 {
        return switch (self) {
            .night => "Grok Night",
            .day => "Grok Day",
            .tokyo => "Tokyo Night",
            .rose => "Rosé Pine",
            .oscura => "Oscura Midnight",
        };
    }

    pub fn aliases(self: Id) []const []const u8 {
        return switch (self) {
            .night => &.{ "night", "dark", "groknight", "codegraff" },
            .day => &.{ "day", "light", "grokday" },
            .tokyo => &.{ "tokyo", "tokyonight", "tokyo-night" },
            .rose => &.{ "rose", "rosepine", "rose-pine" },
            .oscura => &.{ "oscura", "oscura-midnight" },
        };
    }
};

pub const Theme = struct {
    id: Id,
    accent: []const u8,
    text: []const u8,
    muted: []const u8,
    error_fg: []const u8,
    ok: []const u8,
    border: []const u8,
    /// Focused prompt border (Grok `prompt_border_active`).
    focus: []const u8,
    /// Truecolor background. Applied once per line so the pager is one field.
    bg: []const u8,
};

/// Reset fg/weight only — never 49 — so the theme background stays put.
pub const reset = "\x1b[39;22;23;24m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";

// Grok Night tokens — used by tests and as the default pager palette.
pub const grok_magenta = "\x1b[38;2;187;154;247m"; // #bb9af7
pub const grok_red = "\x1b[38;2;247;118;142m"; // #f7768e
pub const emerald = grok_magenta; // markdown tests pass this as the accent
pub const zinc200 = "\x1b[38;2;225;225;225m"; // Grok FG #e1e1e1
pub const zinc400 = "\x1b[38;2;108;108;108m"; // Grok COMMENT #6c6c6c
pub const zinc500 = "\x1b[38;2;80;80;88m";
pub const coral = grok_red;
pub const mint = "\x1b[38;2;158;206;106m"; // #9ece6a
pub const white = zinc200;
pub const bright = zinc400;

pub const all = [_]Id{ .night, .day, .tokyo, .rose, .oscura };

pub fn of(id: Id) Theme {
    return switch (id) {
        // xai-grok-pager-render groknight / grokday / tokyonight / rosepine / oscura.
        .night => .{ .id = .night, .accent = grok_magenta, .text = "\x1b[38;2;225;225;225m", .muted = "\x1b[38;2;108;108;108m", .error_fg = grok_red, .ok = "\x1b[38;2;158;206;106m", .border = "\x1b[38;2;50;50;55m", .focus = "\x1b[38;2;80;80;88m", .bg = "\x1b[48;2;20;20;20m" },
        .day => .{ .id = .day, .accent = "\x1b[38;2;5;150;105m", .text = "\x1b[38;2;32;37;34m", .muted = "\x1b[38;2;98;107;101m", .error_fg = "\x1b[38;2;190;52;71m", .ok = "\x1b[38;2;4;120;87m", .border = "\x1b[38;2;205;212;207m", .focus = "\x1b[38;2;5;150;105m", .bg = "\x1b[48;2;248;249;247m" },
        .tokyo => .{ .id = .tokyo, .accent = grok_magenta, .text = "\x1b[38;2;192;202;245m", .muted = "\x1b[38;2;86;95;137m", .error_fg = grok_red, .ok = "\x1b[38;2;158;206;106m", .border = "\x1b[38;2;50;62;100m", .focus = "\x1b[38;2;75;92;140m", .bg = "\x1b[48;2;36;40;59m" },
        .rose => .{ .id = .rose, .accent = "\x1b[38;2;196;167;231m", .text = "\x1b[38;2;224;222;244m", .muted = "\x1b[38;2;110;106;134m", .error_fg = "\x1b[38;2;235;111;146m", .ok = "\x1b[38;2;156;207;216m", .border = "\x1b[38;2;68;65;99m", .focus = "\x1b[38;2;86;82;110m", .bg = "\x1b[48;2;35;33;54m" },
        .oscura => .{ .id = .oscura, .accent = "\x1b[38;2;155;126;206m", .text = "\x1b[38;2;228;228;228m", .muted = "\x1b[38;2;129;134;143m", .error_fg = "\x1b[38;2;220;90;100m", .ok = "\x1b[38;2;80;180;140m", .border = "\x1b[38;2;36;32;52m", .focus = "\x1b[38;2;52;48;72m", .bg = "\x1b[48;2;3;3;4m" },
    };
}

pub fn paint(a: std.mem.Allocator, sgr: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ sgr, text, reset });
}

pub fn parse(name: []const u8) ?Id {
    if (name.len == 0 or name.len > 32) return null;
    var buf: [32]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, name);
    for (all) |id| {
        for (id.aliases()) |al| {
            if (std.mem.eql(u8, lower, al)) return id;
        }
    }
    return null;
}

pub fn next(id: Id) Id {
    return @enumFromInt((@intFromEnum(id) + 1) % all.len);
}

/// Index just past the escape sequence starting at `start` (s[start] == 0x1b).
/// Skips CSI, OSC/DCS/APC/PM/SOS (to BEL or ST), SS3, and ESC+char — a
/// truncation mid-sequence would emit broken escapes into the frame.
pub fn skipEsc(s: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= s.len) return i;
    switch (s[i]) {
        '[' => {
            i += 1;
            while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) : (i += 1) {}
            if (i < s.len) i += 1;
        },
        ']', 'P', '_', '^', 'X' => {
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (s[i] == 0x1b) {
                    i += if (i + 1 < s.len and s[i + 1] == '\\') 2 else 1;
                    break;
                }
            }
        },
        'O' => i = @min(i + 2, s.len),
        else => i += 1,
    }
    return i;
}

/// Columns in `s`, skipping SGR. Assumes 1-col codepoints (no CJK/emoji width).
pub fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEsc(s, i);
            continue;
        }
        const w = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(w, s.len - i);
        n += 1;
    }
    return n;
}

pub fn takeCols(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < max) {
        if (s[i] == 0x1b) {
            i = skipEsc(s, i);
            continue;
        }
        const w = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const step = @min(w, s.len - i);
        i += step;
        n += 1;
    }
    return s[0..i];
}

test "parse: grok aliases and unknown" {
    try std.testing.expectEqual(Id.night, parse("dark").?);
    try std.testing.expectEqual(Id.tokyo, parse("TokyoNight").?);
    try std.testing.expect(parse("not-a-theme") == null);
}

test "next wraps the palette" {
    try std.testing.expectEqual(Id.day, next(.night));
    try std.testing.expectEqual(Id.night, next(.oscura));
}

test "every theme ships a truecolor background" {
    for (all) |id| {
        try std.testing.expect(std.mem.startsWith(u8, of(id).bg, "\x1b[48;2;"));
        try std.testing.expect(std.mem.startsWith(u8, of(id).focus, "\x1b[38;2;"));
    }
    try std.testing.expect(std.mem.indexOf(u8, reset, "49") == null);
}

test "night is Grok Night (bg #141414, accent #bb9af7, error #f7768e)" {
    const th = of(.night);
    try std.testing.expectEqualStrings("\x1b[48;2;20;20;20m", th.bg);
    try std.testing.expectEqualStrings("\x1b[38;2;187;154;247m", th.accent);
    try std.testing.expectEqualStrings("\x1b[38;2;247;118;142m", th.error_fg);
    try std.testing.expectEqualStrings("\x1b[38;2;225;225;225m", th.text);
    try std.testing.expectEqualStrings("\x1b[38;2;50;50;55m", th.border);
    try std.testing.expectEqualStrings("\x1b[38;2;80;80;88m", th.focus);
}

test "day uses the Codegraff light palette; dark themes match their tokens" {
    try std.testing.expectEqualStrings("\x1b[48;2;248;249;247m", of(.day).bg);
    try std.testing.expectEqualStrings("\x1b[38;2;5;150;105m", of(.day).accent);
    try std.testing.expectEqualStrings("\x1b[38;2;32;37;34m", of(.day).text);
    try std.testing.expectEqualStrings("\x1b[38;2;98;107;101m", of(.day).muted);
    try std.testing.expectEqualStrings("\x1b[48;2;36;40;59m", of(.tokyo).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;35;33;54m", of(.rose).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;3;3;4m", of(.oscura).bg);
    try std.testing.expectEqualStrings("\x1b[38;2;155;126;206m", of(.oscura).accent);
}

/// Wrap `s` so no row is wider than `width` columns. SGR is preserved.
pub fn wrapToWidth(a: std.mem.Allocator, s: []const u8, width: usize) ![]const u8 {
    if (width == 0) return a.dupe(u8, s);
    var out = std.array_list.Managed(u8).init(a);
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            try out.append('\n');
            col = 0;
            i += 1;
            continue;
        }
        if (s[i] == 0x1b) {
            const start = i;
            i = skipEsc(s, i);
            try out.appendSlice(s[start..i]);
            continue;
        }
        const w = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const step = @min(w, s.len - i);
        if (col >= width) {
            try out.append('\n');
            col = 0;
        }
        try out.appendSlice(s[i .. i + step]);
        col += 1;
        i += step;
    }
    return out.toOwnedSlice();
}

/// Like wrapToWidth, but breaks at the last space on the line when it can.
pub fn wrapPreferWords(a: std.mem.Allocator, s: []const u8, width: usize) ![]const u8 {
    if (width == 0) return a.dupe(u8, s);
    var out = std.array_list.Managed(u8).init(a);
    var col: usize = 0;
    var last_sp: ?usize = null;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            try out.append('\n');
            col = 0;
            last_sp = null;
            i += 1;
            continue;
        }
        if (s[i] == 0x1b) {
            const start = i;
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) : (i += 1) {}
                if (i < s.len) i += 1;
            }
            try out.appendSlice(s[start..i]);
            continue;
        }
        const w = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const step = @min(w, s.len - i);
        if (col + 1 > width) {
            if (last_sp) |sp| {
                out.items[sp] = '\n';
                col = visibleLen(out.items[sp + 1 ..]);
                last_sp = null;
            } else {
                try out.append('\n');
                col = 0;
            }
        }
        if (s[i] == ' ') last_sp = out.items.len;
        try out.appendSlice(s[i .. i + step]);
        col += 1;
        i += step;
    }
    return out.toOwnedSlice();
}

test "visibleLen counts glyphs not UTF-8 bytes or SGR" {
    try std.testing.expectEqual(@as(usize, 3), visibleLen("\x1b[32mhi!\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 3), visibleLen("a ·"));
}

test "wrapPreferWords breaks on spaces not mid-word" {
    const got = try wrapPreferWords(std.testing.allocator, "little bit weird", 10);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "bit") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "b\nit") == null);
}

test "wrapToWidth splits a long line and keeps SGR" {
    const got = try wrapToWidth(std.testing.allocator, "\x1b[32mabcdefghij\x1b[0m", 4);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b[32m") != null);
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |ln| {
        try std.testing.expect(visibleLen(ln) <= 4);
    }
}

test "visibleLen and takeCols treat OSC/APC as invisible" {
    try std.testing.expectEqual(@as(usize, 4), visibleLen("\x1b]8;;http://x\x07link\x1b]8;;\x07"));
    try std.testing.expectEqual(@as(usize, 2), visibleLen("\x1b_Ga=d,d=A\x1b\\ok"));
    const cut = takeCols("\x1b]8;;u\x07ab", 1);
    try std.testing.expectEqualStrings("\x1b]8;;u\x07a", cut);
}
