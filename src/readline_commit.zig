//! Submission boundary for the raw line editor.
//!
//! Editing uses explicit CRLF moves so cursor placement is deterministic. On
//! Enter those visual wraps must be erased and the logical input written again
//! with terminal autowrap, or the editor's old width becomes hard scrollback.

const std = @import("std");
const Io = std.Io;
const PasteStore = @import("readline_paste.zig").Store;
const util = @import("util.zig");

pub fn commit(out: *Io.Writer, items: []const u8, marks: []const []const u8, pastes: ?*const PasteStore, rows: usize, cursor_row: usize, prompt_col: usize, use_color: bool) void {
    const prompt_len = if (prompt_col > 0) prompt_col - 1 else 0;
    const bottom = if (rows > 0) rows - 1 else 0;

    // Remove every manually wrapped editor row, preserving the prompt prefix
    // on row zero. Relative moves remain correct if drawing previously scrolled.
    out.writeAll("\x1b[0m") catch {};
    if (bottom > cursor_row) out.print("\x1b[{d}B", .{bottom - cursor_row}) catch {};
    var row = bottom;
    while (row > 0) : (row -= 1) out.writeAll("\r\x1b[K\x1b[A") catch {};
    out.writeAll("\r") catch {};
    if (prompt_len > 0) out.print("\x1b[{d}C", .{prompt_len}) catch {};
    out.writeAll("\x1b[K") catch {};

    // Do not insert breaks for visual wrapping: the terminal's autowrap flag
    // records those rows as soft and can reflow them after a resize. Authored
    // newlines remain explicit hard breaks, and credentials stay masked.
    const secret_start = util.sensitiveInputStart(items);
    var mark_end: usize = 0;
    var mark_open = false;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const masked = if (secret_start) |start| i >= start else false;
        if (!mark_open) {
            var best_end = i;
            for (marks) |mark| {
                if (mark.len == 0 or i + mark.len > items.len) continue;
                if (std.mem.eql(u8, items[i .. i + mark.len], mark)) best_end = @max(best_end, i + mark.len);
            }
            if (pastes) |store| {
                if (store.highlightEndAt(items, i)) |end| best_end = @max(best_end, end);
            }
            if (best_end > i) {
                out.writeAll(if (use_color) "\x1b[7;38;2;5;150;105m" else "\x1b[7m") catch {};
                mark_end = best_end;
                mark_open = true;
            }
        }
        if (items[i] == '\r' or items[i] == '\n') {
            if (items[i] == '\r' and i + 1 < items.len and items[i + 1] == '\n') i += 1;
            out.writeAll("\r\n") catch {};
        } else {
            out.writeByte(if (masked) '*' else items[i]) catch {};
        }
        if (mark_open and i + 1 == mark_end) {
            out.writeAll("\x1b[0m") catch {};
            mark_open = false;
        }
    }
    if (mark_open) out.writeAll("\x1b[0m") catch {};
    out.writeAll("\r\n\r\n") catch {};
    out.flush() catch {};
}
