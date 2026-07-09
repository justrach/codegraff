//! Streamed-markdown table rendering: buffered rows are column-aligned and
//! word-wrapped to the terminal width when a table block ends. Split out of
//! the Agent struct (#123, 600-line goal) — see agent_render.zig for the
//! rest of the incremental markdown renderer these functions plug into.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const terminal = @import("term.zig");
const termCols = terminal.termCols;

// inlineVisibleLen/renderInline live in agent_render.zig; reached through the
// Agent struct's member aliases so this file doesn't need to know exactly
// which sibling module physically owns them.
const inlineVisibleLen = Agent.inlineVisibleLen;
const renderInline = Agent.renderInline;

pub fn flushTable(self: *Agent, w: *Io.Writer) void {
    const gpa = self.gpa;
    defer {
        for (self.md_table.items) |r| gpa.free(r);
        self.md_table.clearRetainingCapacity();
    }
    // Split rows into trimmed cells (slices into the row strings),
    // dropping the empty edges of leading/trailing '|'.
    var cells: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (cells.items) |cr| gpa.free(cr);
        cells.deinit(gpa);
    }
    var header_rows: ?usize = null; // rows above the first separator
    var ncols: usize = 0;
    for (self.md_table.items) |row| {
        const body = std.mem.trim(u8, row, " ");
        if (isTableSeparator(body)) {
            if (header_rows == null and cells.items.len > 0) header_rows = cells.items.len;
            continue;
        }
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, body, '|');
        var first = true;
        while (it.next()) |cell| {
            defer first = false;
            if (first and cell.len == 0) continue;
            list.append(gpa, std.mem.trim(u8, cell, " ")) catch {};
        }
        while (list.items.len > 0 and list.items[list.items.len - 1].len == 0)
            _ = list.pop();
        ncols = @max(ncols, list.items.len);
        const owned = list.toOwnedSlice(gpa) catch blk: {
            list.deinit(gpa);
            break :blk &.{};
        };
        cells.append(gpa, owned) catch gpa.free(owned);
    }
    if (ncols == 0 or cells.items.len == 0) return;
    const widths = gpa.alloc(usize, ncols) catch return;
    defer gpa.free(widths);
    @memset(widths, 0);
    for (cells.items) |cr| for (cr, 0..) |c, i| {
        widths[i] = @max(widths[i], inlineVisibleLen(c));
    };
    // Cap the grid to the terminal: a column wider than the screen used
    // to hard-wrap at the terminal edge and shred the alignment. Shrink
    // the widest columns until the table fits, then word-wrap each cell
    // into its column — continuation lines keep the │ rails straight.
    fitWidths(widths, termCols() -| (3 * (ncols - 1)));
    const wraps = gpa.alloc(std.ArrayList([]const u8), ncols) catch return;
    defer gpa.free(wraps);
    for (cells.items, 0..) |cr, ri| {
        const head = header_rows != null and ri < header_rows.?;
        var nlines: usize = 1;
        for (0..ncols) |ci| {
            wraps[ci] = .empty;
            wrapCell(gpa, if (ci < cr.len) cr[ci] else "", widths[ci], &wraps[ci]);
            nlines = @max(nlines, wraps[ci].items.len);
        }
        defer for (wraps) |*l| l.deinit(gpa);
        for (0..nlines) |li| {
            for (0..ncols) |ci| {
                const c = if (li < wraps[ci].items.len) wraps[ci].items[li] else "";
                if (ci > 0) w.print("{s} │ {s}", .{ style.dim, style.reset }) catch {};
                if (head) w.writeAll(style.bold) catch {};
                renderInline(w, c);
                if (head) w.writeAll(style.reset) catch {};
                if (ci + 1 < ncols) {
                    var pad = widths[ci] -| inlineVisibleLen(c);
                    while (pad > 0) : (pad -= 1) w.writeByte(' ') catch {};
                }
            }
            w.writeByte('\n') catch {};
        }
        if (header_rows != null and ri + 1 == header_rows.?) {
            w.writeAll(style.dim) catch {};
            for (0..ncols) |ci| {
                if (ci > 0) w.writeAll("─┼─") catch {};
                for (0..widths[ci]) |_| w.writeAll("─") catch {};
            }
            w.writeAll(style.reset) catch {};
            w.writeByte('\n') catch {};
        }
    }
}

/// Shrink the widest columns one cell at a time until the grid fits in
/// `avail` visible columns, never below a readable floor. If the screen
/// can't even hold the floor for every column, leave the widths alone —
/// a torn render beats an unreadable one.
pub fn fitWidths(widths: []usize, avail: usize) void {
    const min_w: usize = 8;
    if (avail < widths.len * min_w) return;
    var total: usize = 0;
    for (widths) |x| total += x;
    while (total > avail) {
        var wi: usize = 0;
        for (widths, 0..) |x, k| {
            if (x > widths[wi]) wi = k;
        }
        if (widths[wi] <= min_w) break;
        widths[wi] -= 1;
        total -= 1;
    }
}

/// One wrappable unit of a table cell: a maximal run of non-space bytes,
/// where a **bold**/`code` span is atomic (spaces inside don't split it),
/// so wrapping never tears a styled span apart.
pub fn atomEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        if (s[i] == ' ') return i;
        if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, i + 2, "**")) |e| {
                i = e + 2;
                continue;
            }
        }
        if (s[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |e| {
                i = e + 1;
                continue;
            }
        }
        i += 1;
    }
    return s.len;
}

/// Greedy word-wrap of one table cell to a visible-width budget,
/// appending slices of `cell` to `out` (one per rendered line). Atoms
/// wider than the budget hard-split by codepoint. Always yields at least
/// one (possibly empty) line.
pub fn wrapCell(gpa: Allocator, cell: []const u8, width: usize, out: *std.ArrayList([]const u8)) void {
    const budget = @max(width, 1);
    var ls: usize = 0; // current line: first atom byte…
    var le: usize = 0; // …through end of its last atom
    var lv: usize = 0; // and its visible width
    var i: usize = 0;
    while (i < cell.len) {
        while (i < cell.len and cell[i] == ' ') i += 1;
        if (i >= cell.len) break;
        const ae = atomEnd(cell, i);
        const av = inlineVisibleLen(cell[i..ae]);
        if (lv > 0 and lv + 1 + av > budget) {
            out.append(gpa, cell[ls..le]) catch return;
            lv = 0;
        }
        if (lv == 0 and av > budget) { // oversized atom: hard-split
            var j = i;
            var v: usize = 0;
            while (j < ae and v < budget) {
                j += std.unicode.utf8ByteSequenceLength(cell[j]) catch 1;
                v += 1;
            }
            out.append(gpa, cell[i..j]) catch return;
            i = j;
            continue;
        }
        if (lv == 0) ls = i else lv += 1; // joining space
        lv += av;
        le = ae;
        i = ae;
    }
    if (lv > 0) out.append(gpa, cell[ls..le]) catch return;
    if (out.items.len == 0) out.append(gpa, "") catch {};
}

/// True if a `|`-delimited row contains only separator chars (-, :, space).
pub fn isTableSeparator(body: []const u8) bool {
    var any_dash = false;
    for (body) |c| switch (c) {
        '|', ' ', ':' => {},
        '-' => any_dash = true,
        else => return false,
    };
    return any_dash;
}

test "table cell wrapping: fitWidths caps the grid, wrapCell wraps on atoms" {
    // fitWidths shaves the widest column down to the budget, floor 8.
    var widths = [_]usize{ 12, 60, 20 };
    fitWidths(&widths, 50);
    try std.testing.expectEqual(@as(usize, 50), widths[0] + widths[1] + widths[2]);
    try std.testing.expectEqual(@as(usize, 12), widths[0]); // untouched
    try std.testing.expect(widths[1] >= 8 and widths[2] >= 8);
    // Below the readable floor the widths are left alone.
    var tight = [_]usize{ 20, 20 };
    fitWidths(&tight, 10);
    try std.testing.expectEqual(@as(usize, 20), tight[0]);

    // wrapCell: greedy word wrap, styled spans atomic, oversized atoms split.
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    wrapCell(std.testing.allocator, "alpha beta **two words** gamma", 11, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("alpha beta", out.items[0]);
    try std.testing.expectEqualStrings("**two words**", out.items[1]); // 9 visible
    try std.testing.expectEqualStrings("gamma", out.items[2]);
    out.clearRetainingCapacity();
    wrapCell(std.testing.allocator, "supercalifragilistic", 7, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("superca", out.items[0]);
    out.clearRetainingCapacity();
    wrapCell(std.testing.allocator, "", 10, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("", out.items[0]);
}

test "isTableSeparator: only |, -, :, space and at least one dash" {
    try std.testing.expect(isTableSeparator("|---|---|"));
    try std.testing.expect(isTableSeparator("| :--- | ---: |"));
    try std.testing.expect(isTableSeparator("---"));
    try std.testing.expect(!isTableSeparator("| a | b |")); // letters
    try std.testing.expect(!isTableSeparator("|   |   |")); // no dash
    try std.testing.expect(!isTableSeparator("")); // empty
}
