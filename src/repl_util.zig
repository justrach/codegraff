//! Stateless string/format helpers shared by the `graff repl` Model: help
//! text, inline markdown span rendering, and small string utilities used by
//! the command dispatcher and the pane renderer. Split out of repl.zig
//! (#123, 600-line goal) — pure functions, no Model dependency.

const std = @import("std");
const zz = @import("zigzag");

pub const accent = zz.Color.fromRgb(0x05, 0x96, 0x69); // codegraff.com emerald accent (#059669)

pub const HELP_CHAT =
    \\Commands (mirrors the graff session):
    \\  /help /clear /new /quit          conversation
    \\  /rewind /compact /cost           history
    \\  /model [name] /models            model (switch / list)
    \\  /effort low|med|high|xhigh|max|ultra   reasoning depth
    \\  /fast /thinking /ultracode       thinking controls (toggles)
    \\  /goal <text>                     standing objective (tracked as a checklist)
    \\  /plan /strict /yolo /keepcontext /title   modes
    \\  /rename <name>  /animation enso|braille|dragon
    \\  /bash /save /resume /sessions /workspace /trace /trajectory
    \\  /agents /skills /hooks /mcp /loop /review /image /paste /key
    \\
    \\Type a message and press enter to send it to the model. Toggles accept
    \\[on|off] or flip when bare. Commands needing the agent loop explain so.
;

pub fn renderInline(out: *std.array_list.Managed(u8), a: std.mem.Allocator, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try out.appendSlice(try (zz.Style{}).fg(accent).render(a, line[i + 1 .. end]));
                i = end + 1;
                continue;
            }
        } else if (c == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                try out.appendSlice(try (zz.Style{}).bold(true).render(a, line[i + 2 .. end]));
                i = end + 2;
                continue;
            }
        }
        try out.append(c);
        i += 1;
    }
}
pub fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// Strip ANSI/control sequences (and CR) so the agent's live streamed output
/// can be shown as plain text — cursor moves/redraws can't corrupt the pane.
/// Result owned by `a`.
pub fn stripControl(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
                if (i < s.len) i += 1;
            } else if (i < s.len and s[i] == ']') {
                i += 1;
                while (i < s.len and s[i] != 0x07 and s[i] != 0x1b) i += 1;
                if (i < s.len) i += 1;
            } else if (i < s.len) {
                i += 1;
            }
        } else if (c == '\r') {
            i += 1;
        } else {
            out.append(c) catch {};
            i += 1;
        }
    }
    return out.items;
}

/// Compact live-activity preview: the last `n` non-empty lines of `plain`, each
/// width-truncated (UTF-8 safe) and dimmed, indented. Keeps the agent's tool
/// chatter from flooding the pane while still showing live progress.
pub fn tailPreview(a: std.mem.Allocator, plain: []const u8, width: usize, n: usize) ![]const u8 {
    var lines = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, plain, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t");
        if (t.len > 0) try lines.append(t);
    }
    const start = if (lines.items.len > n) lines.items.len - n else 0;
    const cap = if (width > 6) width - 4 else 12;
    var out = std.array_list.Managed(u8).init(a);
    for (lines.items[start..]) |ln| {
        var tw = @min(ln.len, cap);
        while (tw > 0 and tw < ln.len and (ln[tw] & 0xC0) == 0x80) tw -= 1; // don't cut mid-UTF-8
        try out.appendSlice("  ");
        try out.appendSlice(try (zz.Style{}).dim(true).render(a, ln[0..tw]));
        try out.append('\n');
    }
    return out.items;
}

pub fn parseToggle(arg: []const u8, current: bool) bool {
    if (std.mem.eql(u8, arg, "on")) return true;
    if (std.mem.eql(u8, arg, "off")) return false;
    return !current; // bare toggle
}

pub fn onOff(v: bool) []const u8 {
    return if (v) "on" else "off";
}
