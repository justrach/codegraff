//! Backgrounds DERIVED from a palette's own canvas, as tokens.
//!
//! This is theme.zig's material — it lives next door only because that file
//! sits at the 600-line ceiling. Nothing here is a hand-picked colour: every
//! value is computed from `theme.of(id).bg`, so a new palette gets its hover
//! tint for free and no two palettes can drift out of step.
//!
//! POLARITY. A dark canvas is LIFTED toward white and a light canvas is SUNK
//! toward black, decided by the same BT.709 rule theme.classifyLight uses for
//! the OSC-11 reply. One step, both polarities, no second table.
//!
//! WEIGHT. The step is deliberately small. The drag-selection band is full
//! inverse video (`\x1b[7m`) and CLAIMS a region; a hover tint only ANNOUNCES
//! that the row under the pointer is a target, so it has to read as quieter
//! than the band from across the room. `hover_step` is asserted below to be a
//! small fraction of a channel, and the tint is asserted never to be inverse.

const std = @import("std");

const theme = @import("theme.zig");

/// Channel step between the canvas and a hovered row, out of 255. Large enough
/// to see on an OLED black (oscura's bg is 3,3,4), small enough that a sweep
/// across the transcript never reads as a selection.
pub const hover_step: u8 = 16;

/// The hover background for a palette. Comptime-folded per theme, so this is a
/// switch over string literals at runtime — no allocation, no formatting.
pub fn hoverBg(id: theme.Id) []const u8 {
    return switch (id) {
        inline else => |tag| comptime step(theme.of(tag).bg, hover_step),
    };
}

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// The channels of a `\x1b[48;2;R;G;Bm` background, or null for any other
/// shape. Every palette's bg is written that way; a future one that is not
/// falls back to its own canvas rather than to a wrong colour.
pub fn parseBg(sgr: []const u8) ?Rgb {
    const head = "\x1b[48;2;";
    if (!std.mem.startsWith(u8, sgr, head)) return null;
    if (!std.mem.endsWith(u8, sgr, "m")) return null;
    var it = std.mem.splitScalar(u8, sgr[head.len .. sgr.len - 1], ';');
    var ch: [3]u8 = undefined;
    for (&ch) |*c| {
        const p = it.next() orelse return null;
        c.* = std.fmt.parseInt(u8, p, 10) catch return null;
    }
    if (it.next() != null) return null;
    return .{ .r = ch[0], .g = ch[1], .b = ch[2] };
}

/// `bg` moved one step away from its own polarity, as an SGR literal. Comptime
/// only: the result is a literal folded into the binary, never a formatted
/// buffer a frame has to own.
pub fn step(comptime bg: []const u8, comptime by: u8) []const u8 {
    const parsed = comptime parseBg(bg);
    if (parsed == null) return bg;
    const c = comptime parsed.?;
    const lift = comptime !theme.classifyLight(c.r, c.g, c.b);
    const r: u8 = comptime if (lift) c.r +| by else c.r -| by;
    const g: u8 = comptime if (lift) c.g +| by else c.g -| by;
    const b: u8 = comptime if (lift) c.b +| by else c.b -| by;
    return std.fmt.comptimePrint("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "every palette's hover tint is derived from its own canvas and differs from it" {
    for (theme.all) |id| {
        const bg = theme.of(id).bg;
        const hov = hoverBg(id);
        try testing.expect(!std.mem.eql(u8, bg, hov));
        const base = parseBg(bg).?;
        const tint = parseBg(hov).?;
        // One step, in the direction the canvas's own polarity asks for.
        const lift = !theme.classifyLight(base.r, base.g, base.b);
        if (lift) {
            try testing.expect(tint.r >= base.r and tint.g >= base.g and tint.b >= base.b);
        } else {
            try testing.expect(tint.r <= base.r and tint.g <= base.g and tint.b <= base.b);
        }
        // ...and never more than one step, on any channel, in either polarity.
        const dr = if (tint.r > base.r) tint.r - base.r else base.r - tint.r;
        const dg = if (tint.g > base.g) tint.g - base.g else base.g - tint.g;
        const db = if (tint.b > base.b) tint.b - base.b else base.b - tint.b;
        try testing.expect(dr <= hover_step and dg <= hover_step and db <= hover_step);
    }
}

test "the hover tint is quieter than the selection band, and never inverse" {
    // The band is `\x1b[7m` — it inverts the whole cell. A tint that reached
    // for inverse video, or for a step big enough to read as one, would make
    // hover and selection say the same thing.
    for (theme.all) |id| {
        const hov = hoverBg(id);
        try testing.expect(std.mem.indexOf(u8, hov, "\x1b[7m") == null);
        try testing.expect(std.mem.startsWith(u8, hov, "\x1b[48;2;"));
    }
    // A tenth of a channel or less: visible, never a claim.
    try testing.expect(hover_step > 0 and hover_step <= 25);
}

test "a background that is not truecolor keeps its own bytes" {
    try testing.expectEqualStrings("\x1b[44m", step("\x1b[44m", 16));
    try testing.expectEqual(@as(?Rgb, null), parseBg("\x1b[48;2;1;2m"));
    try testing.expectEqual(@as(?Rgb, null), parseBg("\x1b[48;2;1;2;3;4m"));
    try testing.expectEqual(@as(?Rgb, null), parseBg("\x1b[48;5;12m"));
}

test "the step saturates instead of wrapping at either end of a channel" {
    // A pure-black canvas cannot sink and a pure-white one cannot lift; both
    // used to be where a wrapping subtract turned the tint into its opposite.
    try testing.expectEqualStrings("\x1b[48;2;16;16;16m", comptime step("\x1b[48;2;0;0;0m", 16));
    try testing.expectEqualStrings("\x1b[48;2;239;239;239m", comptime step("\x1b[48;2;255;255;255m", 16));
}
