//! grok-build's default pager inset (xai-org/grok-build `LayoutConfig`).
//!
//! Measured from `crates/codegen/xai-grok-pager-render/src/appearance/config.rs`
//! and the pager.toml docs (`[scrollback.layout]`):
//!
//!     outer_vpad        = 1   // top/bottom of the scrollback viewport
//!     outer_hpad_left   = 2   // left gutter (minimum 1)
//!     outer_hpad_right  = 2   // right gutter (minimum 1)
//!     block_pad_left    = 2   // inside a block, after the accent rail
//!     block_pad_right   = 2
//!
//! Compact mode (their `eff_*`): horizontal pad drops to `MIN_HPAD` (1) and
//! vertical pad drops to 0. `/compact-mode` is the same switch here.
//!
//! Presentation only — colours stay in `theme.zig` / `ansi.zig`. No OSC 50.

const std = @import("std");

const app = @import("app.zig");
const Model = app.Model;

/// grok-build `LayoutConfig::outer_hpad_left`.
pub const outer_hpad_left: usize = 2;
/// grok-build `LayoutConfig::outer_hpad_right`.
pub const outer_hpad_right: usize = 2;
/// grok-build `LayoutConfig::outer_vpad`.
pub const outer_vpad: usize = 1;
/// grok-build `LayoutConfig::MIN_HPAD` — compact mode, and the clamp floor.
pub const min_hpad: usize = 1;

pub const Pads = struct {
    left: usize,
    right: usize,
    vpad: usize,
    /// Columns the chrome and transcript wrap to (`term - left - right`).
    inner: usize,
};

pub fn hpadLeft(compact: bool) usize {
    return if (compact) min_hpad else outer_hpad_left;
}

pub fn hpadRight(compact: bool) usize {
    return if (compact) min_hpad else outer_hpad_right;
}

pub fn vpad(compact: bool) usize {
    return if (compact) 0 else outer_vpad;
}

/// Effective pads for a terminal `width`. Narrow screens drop to `min_hpad`
/// rather than crush the composer below the panel minimum.
pub fn forTerm(width: usize, compact: bool) Pads {
    var left = hpadLeft(compact);
    var right = hpadRight(compact);
    const floor: usize = 24;
    if (width < left + right + floor) {
        left = @min(left, min_hpad);
        right = @min(right, min_hpad);
    }
    if (width < left + right + 16) {
        left = 0;
        right = 0;
    }
    const inner = width -| (left + right);
    return .{
        .left = left,
        .right = right,
        .vpad = vpad(compact),
        .inner = if (inner == 0) width else inner,
    };
}

pub fn of(m: *const Model) Pads {
    return forTerm(if (m.last_term_width == 0) 80 else m.last_term_width, m.compact_mode);
}

/// Wrap / layout width — what `layout_cache.ensure` and `indexAtVisual` share.
pub fn wrapWidth(m: *const Model) usize {
    return of(m).inner;
}

/// Screen column → content column (drops the left gutter).
pub fn screenToInner(m: *const Model, x: usize) usize {
    return x -| of(m).left;
}

/// Prefix every row of `text` with `left` spaces. Trailing newline shape is
/// preserved so `render.zig`'s `countLines` stays honest.
pub fn appendPadded(out: *std.array_list.Managed(u8), text: []const u8, left: usize) !void {
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |ln| {
        if (!first) try out.append('\n');
        first = false;
        if (ln.len == 0 and it.rest().len == 0) break;
        try out.appendNTimes(' ', left);
        try out.appendSlice(ln);
    }
    if (text[text.len - 1] == '\n') try out.append('\n');
}

test "grok-build default inset is 2 / 2 / 1" {
    const p = forTerm(80, false);
    try std.testing.expectEqual(@as(usize, 2), p.left);
    try std.testing.expectEqual(@as(usize, 2), p.right);
    try std.testing.expectEqual(@as(usize, 1), p.vpad);
    try std.testing.expectEqual(@as(usize, 76), p.inner);
    try std.testing.expectEqual(outer_hpad_left, p.left);
    try std.testing.expectEqual(outer_vpad, p.vpad);
}

test "compact mode uses MIN_HPAD and drops outer_vpad" {
    const p = forTerm(80, true);
    try std.testing.expectEqual(min_hpad, p.left);
    try std.testing.expectEqual(min_hpad, p.right);
    try std.testing.expectEqual(@as(usize, 0), p.vpad);
    try std.testing.expectEqual(@as(usize, 78), p.inner);
}

test "appendPadded prefixes every row and keeps a trailing newline" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try appendPadded(&out, "ab\ncd\n", 2);
    try std.testing.expectEqualStrings("  ab\n  cd\n", out.items);
}

fn firstGlyphCol(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c != ' ') return n;
        n += 1;
    }
    return n;
}

fn rowWith(vis: []const u8, needle: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, vis, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, needle) != null) return ln;
    }
    return null;
}

test "Term screen insets transcript, composer, and footer like grok-build" {
    const sim = @import("sim.zig");
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.push(.assistant, "INSETPROBE unique breathing room");
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    const probe = rowWith(vis, "INSETPROBE") orelse return error.NoTranscript;
    // Outer gutter plus the unselected row mark: never flush to column 0.
    try std.testing.expect(firstGlyphCol(probe) >= outer_hpad_left);
    try std.testing.expect(probe.len >= 2 and probe[0] == ' ' and probe[1] == ' ');

    const box = rowWith(vis, "╭") orelse return error.NoComposer;
    try std.testing.expectEqual(outer_hpad_left, firstGlyphCol(box));
    try std.testing.expect(box[0] == ' ');

    const hints = rowWith(vis, "Enter:send") orelse return error.NoFooter;
    try std.testing.expect(firstGlyphCol(hints) >= outer_hpad_left);

    var rows = std.mem.splitScalar(u8, vis, '\n');
    var last: []const u8 = "";
    var n: usize = 0;
    while (rows.next()) |ln| {
        if (ln.len > 0 or rows.rest().len > 0) {
            last = ln;
            n += 1;
        }
    }
    // The last painted row is the outer_vpad blank under the hints — not the
    // composer wall, and not a flush hint line.
    try std.testing.expect(std.mem.indexOf(u8, last, "╭") == null);
    try std.testing.expect(std.mem.indexOf(u8, last, "╰") == null);
    try std.testing.expect(firstGlyphCol(last) == last.len);

    const lay = try term.layout();
    defer std.testing.allocator.free(lay);
    try std.testing.expect(std.mem.indexOf(u8, lay, "prompt-origin") != null);
    try std.testing.expect(term.model.prompt_origin + 1 < 24);
}

test "Term annotated rows carry the left gutter; compact drops vpad" {
    const sim = @import("sim.zig");
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.push(.user, "gutter-check prompt");
    const ann = try term.annotated();
    defer std.testing.allocator.free(ann);
    const line = rowWith(ann, "gutter-check") orelse return error.NoAnnotated;
    // " 12|  › #1  gutter-check" — the dump prefix is 4 cols, then the gutter.
    const bar = std.mem.indexOfScalar(u8, line, '|') orelse return error.NoBar;
    try std.testing.expectEqual(@as(u8, ' '), line[bar + 1]);
    try std.testing.expectEqual(@as(u8, ' '), line[bar + 2]);

    term.model.compact_mode = true;
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    const box = rowWith(vis, "╭") orelse return error.NoComposer;
    try std.testing.expectEqual(min_hpad, firstGlyphCol(box));
    var it = std.mem.splitScalar(u8, vis, '\n');
    var last: []const u8 = "";
    while (it.next()) |ln| {
        if (ln.len > 0 or it.rest().len > 0) last = ln;
    }
    // Compact drops the blank last row; the hint line is the footer.
    try std.testing.expect(std.mem.indexOf(u8, last, "Enter:send") != null);
}
