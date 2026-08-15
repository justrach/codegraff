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

/// grok's polarity test: BT.709 luminance over sRGB-linearized channels,
/// light at >= 0.5. Only the 1-bit answer is kept — the palette stays fixed.
pub fn classifyLight(r: u8, g: u8, b: u8) bool {
    const lum = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
    return lum >= 0.5;
}

fn linear(c: u8) f64 {
    const s = @as(f64, @floatFromInt(c)) / 255.0;
    return if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
}

test "classifyLight: grok-night bg is dark, grok-day bg is light" {
    try std.testing.expect(!classifyLight(0x14, 0x14, 0x14));
    try std.testing.expect(!classifyLight(0x24, 0x28, 0x3b)); // tokyo storm
    try std.testing.expect(classifyLight(0xf6, 0xf6, 0xf6));
    try std.testing.expect(classifyLight(0xee, 0xee, 0xee));
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

/// Terminal column width of one codepoint: 2 for East Asian Wide/Fullwidth and
/// for emoji whose DEFAULT presentation is emoji, 0 for combining marks and
/// zero-width joiners, 1 otherwise. Every box border and pad in the TUI keys on
/// this — counting 🚀 as one column pushed the composer's right wall two cells
/// past its corners.
///
/// The symbol blocks are enumerated, never taken wholesale. U+2600..U+27BF and
/// U+2B00..U+2BFF are mostly East-Asian-Ambiguous glyphs that terminals draw in
/// ONE cell, and the TUI paints five of them itself (⚙ ✓ ✗ ❙ ❯). Claiming two
/// columns for those under-padded every chrome row by one and — because
/// run.zig skips the pad AND the erase once a row measures full — stranded the
/// previous frame's last cell. Only Emoji_Presentation=Yes is wide here; the
/// text-presentation symbols reach two columns via a VS16 selector (see cpAt).
pub fn charWidth(cp: u21) u2 {
    return switch (cp) {
        0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F => 0, // combining
        0x200B...0x200D, 0xFE0E...0xFE0F, 0x2060 => 0, // zero-width + variation selectors
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6 => 2, // East Asian Wide
        0x1F300...0x1FAFF, 0x20000...0x3FFFD => 2, // emoji planes + supplementary ideographs
        // Emoji_Presentation=Yes inside the BMP symbol blocks.
        0x231A...0x231B, 0x23E9...0x23EC, 0x23F0, 0x23F3, 0x25FD...0x25FE => 2,
        0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1 => 2,
        0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4 => 2,
        0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD => 2,
        0x2705, 0x270A...0x270B, 0x2728, 0x274C, 0x274E => 2,
        0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF => 2,
        0x2B1B...0x2B1C, 0x2B50, 0x2B55 => 2,
        else => 1,
    };
}

/// Width and byte length of the codepoint at `i`, honouring a trailing VS16:
/// `✓\u{FE0F}` asks for emoji presentation and does take two cells, while a
/// bare `✓` takes one. The selector itself stays zero-width, so the pair still
/// measures two in total.
fn cpAt(s: []const u8, i: usize) struct { w: u2, step: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .w = 1, .step = 1 };
    const step = @min(@as(usize, len), s.len - i);
    const cp = std.unicode.utf8Decode(s[i .. i + step]) catch return .{ .w = 1, .step = step };
    const w = charWidth(cp);
    if (w == 1 and emojiPresentationNext(s, i + step)) return .{ .w = 2, .step = step };
    return .{ .w = w, .step = step };
}

fn emojiPresentationNext(s: []const u8, at: usize) bool {
    if (at + 3 > s.len) return false;
    return std.mem.eql(u8, s[at .. at + 3], "\u{FE0F}");
}

/// Columns in `s`, skipping SGR; CJK/emoji count 2, combining marks 0.
pub fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEsc(s, i);
            continue;
        }
        const c = cpAt(s, i);
        i += c.step;
        n += c.w;
    }
    return n;
}

pub fn takeCols(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEsc(s, i);
            continue;
        }
        const c = cpAt(s, i);
        if (n + c.w > max) break; // a wide glyph that would straddle the edge stays out
        i += c.step;
        n += c.w;
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

/// Active-SGR tracker for the wrappers: remember styling since the last reset
/// so an inserted line break can re-open it — the diff painter repaints rows
/// independently, so a continuation row with no SGR of its own renders in
/// whatever style the previous paint left behind.
///
/// State is kept PER CATEGORY, last writer wins. Concatenating the raw
/// sequences instead grew without bound, so it needed a byte cap — and the cap
/// CLEARED the tracker rather than trimming it. The background is set first on
/// a code fence, so it was always the first casualty: a syntax-highlighted line
/// carries a colour per token, and by the wrap point the band was long gone and
/// the continuation row painted on the plain canvas.
pub const Sgr = struct {
    fg: Slot = .{},
    bg: Slot = .{},
    weight: Slot = .{},
    italic: Slot = .{},
    underline: Slot = .{},

    /// Longest parameter list a slot holds: "48;2;255;255;255".
    const Slot = struct {
        buf: [20]u8 = undefined,
        len: u8 = 0,

        fn set(s: *Slot, p: []const u8) void {
            if (p.len == 0 or p.len > s.buf.len) return;
            @memcpy(s.buf[0..p.len], p);
            s.len = @intCast(p.len);
        }
        fn drop(s: *Slot) void {
            s.len = 0;
        }
        fn params(s: *const Slot) []const u8 {
            return s.buf[0..s.len];
        }
    };

    /// Five slots at "\x1b[" + 16 params + "m" apiece, rounded up.
    pub const max_render = 5 * 20;

    pub fn clear(self: *Sgr) void {
        self.* = .{};
    }

    /// Re-emit the active state into `buf`. Background first so a continuation
    /// row establishes its canvas before anything paints on it.
    pub fn render(self: *const Sgr, buf: *[max_render]u8) []const u8 {
        var n: usize = 0;
        const order = [_]*const Slot{ &self.bg, &self.fg, &self.weight, &self.italic, &self.underline };
        for (order) |slot| {
            const p = slot.params();
            if (p.len == 0) continue;
            buf[n] = 0x1b;
            buf[n + 1] = '[';
            n += 2;
            @memcpy(buf[n .. n + p.len], p);
            n += p.len;
            buf[n] = 'm';
            n += 1;
        }
        return buf[0..n];
    }

    /// Fold one escape sequence into the state. Non-SGR escapes (OSC links,
    /// kitty graphics, ESC[K) are ignored: they carry no style.
    pub fn note(self: *Sgr, seq: []const u8) void {
        if (seq.len < 3 or seq[1] != '[' or seq[seq.len - 1] != 'm') return;
        const body = seq[2 .. seq.len - 1];
        if (body.len == 0) { // "\x1b[m" is "\x1b[0m"
            self.clear();
            return;
        }
        var parts: [16][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, body, ';');
        while (it.next()) |p| {
            if (n == parts.len) return; // pathological: leave the state alone
            parts[n] = p;
            n += 1;
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const code = std.fmt.parseInt(u16, parts[i], 10) catch continue;
            switch (code) {
                0 => self.clear(),
                1, 2 => self.weight.set(parts[i]),
                3 => self.italic.set(parts[i]),
                4 => self.underline.set(parts[i]),
                22 => self.weight.drop(),
                23 => self.italic.drop(),
                24 => self.underline.drop(),
                39 => self.fg.drop(),
                49 => self.bg.drop(),
                30...37, 90...97 => self.fg.set(parts[i]),
                40...47, 100...107 => self.bg.set(parts[i]),
                38, 48 => {
                    // 38/48 own the parameters that follow: ";5;n" or ";2;r;g;b".
                    const want: usize = if (i + 1 < n and std.mem.eql(u8, parts[i + 1], "5")) 2 else 4;
                    if (i + want >= n) return;
                    const start = @intFromPtr(parts[i].ptr) - @intFromPtr(body.ptr);
                    const last = parts[i + want];
                    const end = @intFromPtr(last.ptr) - @intFromPtr(body.ptr) + last.len;
                    const slot = if (code == 38) &self.fg else &self.bg;
                    slot.set(body[start..end]);
                    i += want;
                },
                else => {},
            }
        }
    }
};

/// Wrap `s` so no row is wider than `width` columns. SGR is preserved AND
/// re-emitted on continuation rows; wide glyphs never straddle the edge.
pub fn wrapToWidth(a: std.mem.Allocator, s: []const u8, width: usize) ![]const u8 {
    if (width == 0) return a.dupe(u8, s);
    var out = std.array_list.Managed(u8).init(a);
    var active: Sgr = .{};
    var sgr_buf: [Sgr.max_render]u8 = undefined;
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            try out.append('\n');
            try out.appendSlice(active.render(&sgr_buf));
            col = 0;
            i += 1;
            continue;
        }
        if (s[i] == 0x1b) {
            const start = i;
            i = skipEsc(s, i);
            try out.appendSlice(s[start..i]);
            active.note(s[start..i]);
            continue;
        }
        const c = cpAt(s, i);
        if (col + c.w > width and col > 0) {
            try out.append('\n');
            try out.appendSlice(active.render(&sgr_buf));
            col = 0;
        }
        try out.appendSlice(s[i .. i + c.step]);
        col += c.w;
        i += c.step;
    }
    return out.toOwnedSlice();
}

/// Like wrapToWidth, but breaks at the last space on the line when it can.
pub fn wrapPreferWords(a: std.mem.Allocator, s: []const u8, width: usize) ![]const u8 {
    if (width == 0) return a.dupe(u8, s);
    var out = std.array_list.Managed(u8).init(a);
    var active: Sgr = .{};
    var sgr_buf: [Sgr.max_render]u8 = undefined;
    var col: usize = 0;
    var last_sp: ?usize = null;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            try out.append('\n');
            try out.appendSlice(active.render(&sgr_buf));
            col = 0;
            last_sp = null;
            i += 1;
            continue;
        }
        if (s[i] == 0x1b) {
            const start = i;
            i = skipEsc(s, i); // full skip: hand-rolled CSI-only parsing broke a \n INTO an OSC hyperlink
            try out.appendSlice(s[start..i]);
            active.note(s[start..i]);
            continue;
        }
        const c = cpAt(s, i);
        // `col > 0` matches wrapToWidth: a glyph wider than the whole width has
        // nowhere to go, and breaking before it only opened with a blank row.
        if (col + c.w > width and col > 0) {
            if (last_sp) |sp| {
                out.items[sp] = '\n';
                try out.insertSlice(sp + 1, active.render(&sgr_buf));
                col = visibleLen(out.items[sp + 1 ..]);
                last_sp = null;
            } else {
                try out.append('\n');
                try out.appendSlice(active.render(&sgr_buf));
                col = 0;
            }
        }
        if (s[i] == ' ') last_sp = out.items.len;
        try out.appendSlice(s[i .. i + c.step]);
        col += c.w;
        i += c.step;
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

test "charWidth: the TUI's own glyphs measure one cell" {
    // ⚙ ✓ ✗ ❙ ❯ are painted by scrollback/render themselves and are ambiguous
    // width: terminals give them one cell. A blanket 2600..27BF range called
    // them two, which under-padded every chrome row and — once a row measured
    // full — cost it both the pad and the erase-to-EOL in run.zig.
    for ([_]u21{ '⚙', '✓', '✗', '❙', '❯', '⊘', '●', '◆', '·', '›', '…', '│', '╭', '─', '▏', '↳', '→' }) |cp| {
        try std.testing.expectEqual(@as(u2, 1), charWidth(cp));
    }
    // Real emoji and CJK stay two.
    for ([_]u21{ '🚀', '✅', '❌', '⭐', '⌚', '你', '한' }) |cp| {
        try std.testing.expectEqual(@as(u2, 2), charWidth(cp));
    }
    try std.testing.expectEqual(@as(usize, 20), visibleLen("  \u{2713} bash finished ok"));
}

test "charWidth: a VS16 selector promotes a text-presentation symbol" {
    try std.testing.expectEqual(@as(usize, 1), visibleLen("\u{2713}"));
    try std.testing.expectEqual(@as(usize, 2), visibleLen("\u{2713}\u{FE0F}"));
    try std.testing.expectEqual(@as(usize, 1), visibleLen("\u{2713}\u{FE0E}")); // VS15 stays text
    try std.testing.expectEqualStrings("", takeCols("\u{2713}\u{FE0F}", 1)); // never half a cell
}

test "Sgr keeps the background through a colour-heavy line" {
    // One bg then six token colours: concatenating these passed 96 bytes, and
    // the cap CLEARED the tracker, so the continuation row of a wrapped code
    // fence lost its band. Per-slot tracking cannot lose the oldest slot.
    const s = "\x1b[48;2;28;28;28m" ++
        "\x1b[38;2;101;101;101m\x1b[38;2;102;102;102m\x1b[38;2;103;103;103m" ++
        "\x1b[38;2;104;104;104m\x1b[38;2;105;105;105m\x1b[38;2;106;106;106m" ++
        "ABCDEFGHIJ";
    const got = try wrapToWidth(std.testing.allocator, s, 4);
    defer std.testing.allocator.free(got);
    var it = std.mem.splitScalar(u8, got, '\n');
    var n: usize = 0;
    while (it.next()) |ln| : (n += 1) {
        if (n == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, ln, "\x1b[48;2;28;28;28m"));
        try std.testing.expect(std.mem.indexOf(u8, ln, "\x1b[38;2;106;106;106m") != null);
    }
    try std.testing.expect(n > 1);
}

test "Sgr: each reset code drops only its own slot" {
    var st: Sgr = .{};
    var buf: [Sgr.max_render]u8 = undefined;
    st.note("\x1b[48;2;1;2;3m");
    st.note("\x1b[38;5;9m");
    st.note("\x1b[1m");
    try std.testing.expectEqualStrings("\x1b[48;2;1;2;3m\x1b[38;5;9m\x1b[1m", st.render(&buf));
    st.note(reset); // 39;22;23;24 — fg and weight go, the background stays
    try std.testing.expectEqualStrings("\x1b[48;2;1;2;3m", st.render(&buf));
    st.note("\x1b[31m");
    try std.testing.expectEqualStrings("\x1b[48;2;1;2;3m\x1b[31m", st.render(&buf));
    st.note("\x1b[0m");
    try std.testing.expectEqualStrings("", st.render(&buf));
    st.note("\x1b[K"); // not SGR: ignored
    try std.testing.expectEqualStrings("", st.render(&buf));
}

test "wrapPreferWords does not open with a blank row for an oversized glyph" {
    const got = try wrapPreferWords(std.testing.allocator, "\u{1F680}ab", 1);
    defer std.testing.allocator.free(got);
    try std.testing.expect(got[0] != '\n');
}

test "wide glyphs: 2 columns, never straddling a wrap or a takeCols edge" {
    try std.testing.expectEqual(@as(usize, 2), visibleLen("\u{1F680}"));
    try std.testing.expectEqual(@as(usize, 4), visibleLen("\u{4F60}\u{597D}"));
    try std.testing.expectEqual(@as(usize, 1), visibleLen("e\u{0301}"));
    try std.testing.expectEqualStrings("a", takeCols("a\u{1F680}", 2)); // rocket won't fit in 1 col
}

test "wrap re-emits active SGR on continuation rows" {
    const got = try wrapToWidth(std.testing.allocator, "\x1b[32mabcdefgh\x1b[0m", 4);
    defer std.testing.allocator.free(got);
    var it = std.mem.splitScalar(u8, got, '\n');
    _ = it.next();
    const row2 = it.next().?;
    try std.testing.expect(std.mem.startsWith(u8, row2, "\x1b[32m"));
}

test "wrapPreferWords keeps OSC strings intact" {
    const link = "\x1b]8;;http://example.com/long/url\x07go\x1b]8;;\x07 tail words here";
    const got = try wrapPreferWords(std.testing.allocator, link, 10);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "http://example.com/long/url") != null); // URL unbroken
}
