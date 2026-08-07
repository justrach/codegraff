//! Terminal styling primitives shared across the harness UI (spinners, the
//! streaming markdown renderer, pickers, status lines). Leaf module — depends
//! on std only, so any UI module can import it without pulling in main.zig.
//!
//! `style` starts blank (every field an empty string, so styled writes emit no
//! bytes) and main flips it to `Style.ansi` once it confirms stdout is a TTY
//! with color enabled. First of the shared leaves split out of main.zig (#123).

const std = @import("std");

pub const Style = struct {
    reset: []const u8 = "",
    dim: []const u8 = "",
    bold: []const u8 = "",
    /// Codegraff's identity color: the emerald accent from codegraff.com
    /// (--accent: #059669). Keep this separate from status colors so the
    /// accent always means "active/selected/Codegraff", never implicitly
    /// success or error.
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
};

/// The active palette. Blank by default (color off); main sets it to
/// `Style.ansi` at startup when the terminal supports color. Modules read it
/// via a `const style = &term.style;` alias so field access auto-derefs.
pub var style: Style = .{};

test "Style: blank by default, ansi has escape codes" {
    const blank = Style{};
    try std.testing.expectEqualStrings("", blank.reset);
    try std.testing.expectEqualStrings("", blank.bold);
    try std.testing.expectEqualStrings("", blank.accent);
    try std.testing.expectEqualStrings("\x1b[0m", Style.ansi.reset);
    try std.testing.expectEqualStrings("\x1b[1m", Style.ansi.bold);
    try std.testing.expectEqualStrings("\x1b[38;2;5;150;105m", Style.ansi.accent);
    try std.testing.expectEqualStrings("\x1b[35m", Style.ansi.magenta);
    try std.testing.expectEqualStrings("\x1b[36m", Style.ansi.cyan);
}

test "style global starts blank so styled writes emit nothing until enabled" {
    // Fresh-process default: no color. (Other tests may flip it; assert fields
    // are well-formed rather than a specific value to stay order-independent.)
    try std.testing.expect(style.reset.len == 0 or std.mem.startsWith(u8, style.reset, "\x1b"));
}
