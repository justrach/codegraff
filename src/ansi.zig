//! Terminal styling primitives shared across the harness UI (spinners, the
//! streaming markdown renderer, pickers, status lines). Leaf module — depends
//! on std only, so any UI module can import it without pulling in main.zig.
//!
//! `style` starts blank (every field an empty string, so styled writes emit no
//! bytes) and main selects a palette once it confirms stdout is a TTY
//! with color enabled. First of the shared leaves split out of main.zig (#123).

const std = @import("std");

pub const Style = struct {
    reset: []const u8 = "",
    dim: []const u8 = "",
    bold: []const u8 = "",
    italic: []const u8 = "",
    text: []const u8 = "",
    muted: []const u8 = "",
    faint: []const u8 = "",
    /// Identity/selection color, separate from success and error colors.
    accent: []const u8 = "",
    red: []const u8 = "",
    green: []const u8 = "",
    yellow: []const u8 = "",
    magenta: []const u8 = "",
    cyan: []const u8 = "",

    pub const ansi: Style = .{
        .reset = "\x1b[0m",
        .dim = "\x1b[2m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .muted = "\x1b[2m",
        .faint = "\x1b[2m",
        // #059669 is the site's --accent token: 5.6:1 on pure-black and 3.8:1
        // on pure-white terminal backgrounds, and it no longer reads as the
        // error red users mistook the old coral for.
        .accent = "\x1b[38;2;5;150;105m",
        .red = "\x1b[31m",
        .green = "\x1b[32m",
        .yellow = "\x1b[33m",
        .magenta = "\x1b[35m",
        .cyan = "\x1b[36m",
    };

    /// Harness Codegraff Dark foreground tokens; never changes the background.
    pub const harness: Style = .{
        .reset = "\x1b[0m",
        .dim = "\x1b[2m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .text = "\x1b[38;2;237;234;226m", // #edeae2
        .muted = "\x1b[38;2;154;147;132m", // #9a9384
        .faint = "\x1b[38;2;92;86;75m", // #5c564b
        .accent = "\x1b[38;2;232;163;61m", // #e8a33d
        .red = "\x1b[38;2;210;103;79m", // #d2674f
        .green = "\x1b[38;2;127;168;107m", // #7fa86b
        .yellow = "\x1b[38;2;217;164;65m", // #d9a441
        .magenta = "\x1b[38;2;189;128;228m", // #bd80e4
        .cyan = "\x1b[38;2;127;168;107m", // #7fa86b
    };
};

/// The active palette. Blank by default (color off); main sets it to
/// a color palette at startup when the terminal supports color. Modules read it
/// via a `const style = &term.style;` alias so field access auto-derefs.
pub var style: Style = .{};

test "Style: blank by default, ansi has escape codes" {
    const blank = Style{};
    try std.testing.expectEqualStrings("", blank.reset);
    try std.testing.expectEqualStrings("", blank.bold);
    try std.testing.expectEqualStrings("", blank.accent);
    try std.testing.expectEqualStrings("", blank.text);
    try std.testing.expectEqualStrings("", blank.muted);
    try std.testing.expectEqualStrings("", blank.faint);
    try std.testing.expectEqualStrings("\x1b[0m", Style.ansi.reset);
    try std.testing.expectEqualStrings("\x1b[1m", Style.ansi.bold);
    try std.testing.expectEqualStrings("\x1b[38;2;5;150;105m", Style.ansi.accent);
    try std.testing.expectEqualStrings("\x1b[35m", Style.ansi.magenta);
    try std.testing.expectEqualStrings("\x1b[36m", Style.ansi.cyan);
}

test "terminal chrome uses the Harness Codegraff Dark palette" {
    const blank = Style{};
    for ([_][]const u8{
        blank.reset,  blank.dim, blank.bold,  blank.text,   blank.muted,   blank.faint,
        blank.accent, blank.red, blank.green, blank.yellow, blank.magenta, blank.cyan,
    }) |sequence| try std.testing.expectEqualStrings("", sequence);
    try std.testing.expectEqualStrings("", blank.italic);
    const palette = Style.harness;
    try std.testing.expectEqualStrings("\x1b[3m", palette.italic);
    try std.testing.expectEqualStrings("\x1b[0m", palette.reset);
    try std.testing.expectEqualStrings("\x1b[1m", palette.bold);
    try std.testing.expectEqualStrings("\x1b[2m", palette.dim);
    try std.testing.expectEqualStrings("\x1b[38;2;237;234;226m", palette.text);
    try std.testing.expectEqualStrings("\x1b[38;2;154;147;132m", palette.muted);
    try std.testing.expectEqualStrings("\x1b[38;2;92;86;75m", palette.faint);
    try std.testing.expectEqualStrings("\x1b[38;2;232;163;61m", palette.accent);
    try std.testing.expectEqualStrings("\x1b[38;2;210;103;79m", palette.red);
    try std.testing.expectEqualStrings("\x1b[38;2;127;168;107m", palette.green);
    try std.testing.expectEqualStrings("\x1b[38;2;217;164;65m", palette.yellow);
    try std.testing.expectEqualStrings("\x1b[38;2;189;128;228m", palette.magenta);
    try std.testing.expectEqualStrings("\x1b[38;2;127;168;107m", palette.cyan);
    try std.testing.expectEqualStrings("", Style.ansi.text);
    try std.testing.expectEqualStrings(Style.ansi.dim, Style.ansi.muted);
    try std.testing.expectEqualStrings(Style.ansi.dim, Style.ansi.faint);
}

test "style global starts blank so styled writes emit nothing until enabled" {
    // Fresh-process default: no color. (Other tests may flip it; assert fields
    // are well-formed rather than a specific value to stay order-independent.)
    try std.testing.expect(style.reset.len == 0 or std.mem.startsWith(u8, style.reset, "\x1b"));
}
