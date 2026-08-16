//! The chrome glyph registry — presentation only, no engine facts.
//!
//! Every non-text glyph the chrome paints is named here ONCE, with the terminal
//! width class it belongs to, and every animation is a frame SET rather than a
//! pair of literals at a call site. Scattered literals are how an animation
//! acquires a frame that measures two columns: the label beside it then steps
//! sideways on every tick, which is exactly what grok-build's one-column
//! discipline exists to prevent.
//!
//! Width classes. A terminal decides a glyph's cell count from a width table
//! built on Unicode's East_Asian_Width property, never from the font — a glyph
//! drawn from a fallback face still advances the cells its class says it does.
//!
//!   narrow    EAW N or Na. ONE column in every terminal, including one
//!             configured to draw East-Asian-Ambiguous glyphs double-width.
//!   ambiguous EAW A. One column by default — what theme.charWidth returns, and
//!             what every western terminal does — but TWO under the CJK
//!             ambiguous-wide setting (xterm -cjk_width, iTerm2's
//!             "ambiguous characters are double-width", Terminal.app's).
//!
//! LAW: an ANIMATED glyph is narrow-class, and every frame of one animation
//! renders the same number of columns. Both halves are asserted below.
//!
//! The static chrome keeps its ambiguous members on purpose. The composer's
//! own walls (╭ ─ ╮ │ ╰ ╯), the meter separators and the block cursor are all
//! EAW A, so a terminal that widens ● has already widened the box around it —
//! ambiguous-wide is unsupported wholesale, and swapping three marks would buy
//! no alignment while changing the transcript's look. What must never happen is
//! an animation that shifts its neighbours in a NORMAL terminal, and that is
//! what the registry pins.
//!
//! Audit (Unicode 15 EastAsianWidth, 2026-08). Animated and gutter glyphs:
//!
//!   U+2759 ❙  N  pending blink, frame 0        one column everywhere
//!   U+2758 ❘  N  pending blink, frame 1        one column everywhere
//!   U+203A ›  N  selection mark, composer caret
//!   U+276F ❯  N  sticky header prompt mark
//!   U+2298 ⊘  N  denied tool
//!   U+2717 ✗  N  failed tool
//!   U+21B3 ↳  N  queued/nested row
//!   U+25CF ●  A  assistant / error mark        static, box-class
//!   U+25C6 ◆  A  tool mark                     static, box-class
//!   U+00B7 ·  A  system mark, meter separator  static, box-class
//!   U+258B ▋  A  composer cursor               static, box-class
//!   U+25A0 ■  A  stopped/interrupted row       static, box-class
//!
//! The two blink frames were the suspect ones — they read like the ambiguous
//! Geometric Shapes neighbours — but Dingbats U+2758..U+2767 are Neutral, so
//! the pair is genuinely pad-stable and needed no substitution.

const std = @import("std");
const theme = @import("theme.zig");

pub const Class = enum { narrow, ambiguous };

pub const Glyph = struct {
    cp: u21,
    cols: u2,
    class: Class,
    /// What it means, so the registry doubles as the audit table.
    role: []const u8,
};

/// Every chrome codepoint the TUI paints. Anything animated must appear here
/// as `.narrow` — `animations` is checked against this list.
pub const registry = [_]Glyph{
    .{ .cp = 0x2759, .cols = 1, .class = .narrow, .role = "pending blink, frame 0" },
    .{ .cp = 0x2758, .cols = 1, .class = .narrow, .role = "pending blink, frame 1" },
    .{ .cp = 0x203A, .cols = 1, .class = .narrow, .role = "selection mark / composer caret" },
    .{ .cp = 0x276F, .cols = 1, .class = .narrow, .role = "sticky header prompt mark" },
    .{ .cp = 0x2298, .cols = 1, .class = .narrow, .role = "denied tool" },
    .{ .cp = 0x2717, .cols = 1, .class = .narrow, .role = "failed tool" },
    .{ .cp = 0x21B3, .cols = 1, .class = .narrow, .role = "queued / nested row" },
    .{ .cp = 0x25CF, .cols = 1, .class = .ambiguous, .role = "assistant / error mark" },
    .{ .cp = 0x25C6, .cols = 1, .class = .ambiguous, .role = "tool mark" },
    .{ .cp = 0x00B7, .cols = 1, .class = .ambiguous, .role = "system mark / meter separator" },
    .{ .cp = 0x258B, .cols = 1, .class = .ambiguous, .role = "composer cursor" },
    .{ .cp = 0x25A0, .cols = 1, .class = .ambiguous, .role = "stopped / interrupted row" },
};

// ── animated ────────────────────────────────────────────────────────────────

/// The pending row's blink. A fully static frame let run.zig's hash-diff
/// suppress every paint for a background op's whole duration, so the row has to
/// change — but only in ways that keep the label's column fixed.
pub const thinking = [_][]const u8{ "\u{2759}", "\u{2758}" };

/// The scrollback's selection mark. Both frames are a TWO-column field, so a
/// row's body starts at the same column selected or not.
pub const row_mark = [_][]const u8{ "\u{203A} ", "  " };

pub const Animation = struct { name: []const u8, frames: []const []const u8 };

pub const animations = [_]Animation{
    .{ .name = "pending-blink", .frames = &thinking },
    .{ .name = "row-mark", .frames = &row_mark },
};

/// Frame `i` of an animation, wrapping — call sites index by time, never by a
/// literal.
pub fn frame(anim: []const []const u8, i: usize) []const u8 {
    return anim[i % anim.len];
}

// ── static ──────────────────────────────────────────────────────────────────

pub const caret = "\u{203A}"; // composer prompt
pub const prompt_mark = "\u{276F}"; // sticky header
pub const assistant = "\u{25CF}";
pub const tool = "\u{25C6}";
pub const system = "\u{00B7}";
pub const denied = "\u{2298}";
pub const failed = "\u{2717}";
pub const cursor = "\u{258B}";

fn lookup(cp: u21) ?Glyph {
    for (registry) |g| {
        if (g.cp == cp) return g;
    }
    return null;
}

const testing = std.testing;

test "every registered glyph measures the columns it claims" {
    var buf: [4]u8 = undefined;
    for (registry) |g| {
        try testing.expectEqual(@as(u2, 1), g.cols); // chrome is single-cell, always
        try testing.expectEqual(g.cols, theme.charWidth(g.cp));
        const n = try std.unicode.utf8Encode(g.cp, &buf);
        try testing.expectEqual(@as(usize, g.cols), theme.visibleLen(buf[0..n]));
    }
}

test "every frame of every animation renders the same visibleLen" {
    // The whole point of the registry: a frame that measured differently would
    // move the label or timer beside it on every tick.
    for (animations) |anim| {
        try testing.expect(anim.frames.len >= 2); // an animation that cannot change is a still
        const want = theme.visibleLen(anim.frames[0]);
        try testing.expect(want > 0);
        for (anim.frames) |f| {
            try testing.expectEqual(want, theme.visibleLen(f));
            // ...and no two frames may be identical, or the paint loop stalls.
        }
        for (anim.frames, 0..) |f, i| {
            for (anim.frames[i + 1 ..]) |other| {
                try testing.expect(!std.mem.eql(u8, f, other));
            }
        }
    }
}

test "every animated glyph is narrow-class — one column in EVERY terminal" {
    for (animations) |anim| {
        for (anim.frames) |f| {
            var i: usize = 0;
            while (i < f.len) {
                const len = try std.unicode.utf8ByteSequenceLength(f[i]);
                const cp = try std.unicode.utf8Decode(f[i .. i + len]);
                i += len;
                if (cp == ' ') continue; // padding, always one column
                const g = lookup(cp) orelse {
                    std.debug.print("unregistered animated glyph U+{X:0>4}\n", .{cp});
                    return error.UnregisteredGlyph;
                };
                try testing.expectEqual(Class.narrow, g.class);
            }
        }
    }
}

test "the blink frames live in the registry and nowhere else" {
    // A second copy of the pair at a call site is how the frame set drifts:
    // one gets replaced, the other does not, and the animation starts stepping.
    for ([_][]const u8{
        @embedFile("scrollback.zig"),
        @embedFile("chrome.zig"),
        @embedFile("render.zig"),
        @embedFile("input.zig"),
    }) |src| {
        for (thinking) |f| try testing.expect(std.mem.indexOf(u8, src, f) == null);
    }
}

test "frame() indexes by time and wraps" {
    try testing.expectEqualStrings(thinking[0], frame(&thinking, 0));
    try testing.expectEqualStrings(thinking[1], frame(&thinking, 1));
    try testing.expectEqualStrings(thinking[0], frame(&thinking, 2));
}
