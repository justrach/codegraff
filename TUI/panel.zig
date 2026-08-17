//! The bordered panel every overlay body sits inside.
//!
//! grok-build draws an overlay as a PANEL: a box whose TOP edge carries the
//! name of the thing and whose BOTTOM edge carries the keys, so chrome and
//! content never compete for a row. graff's overlays used to be bare text
//! floating on the pager — the same rows, but with no edge telling the eye
//! where the list stopped and the transcript resumed, and with the title
//! spending a whole content row to say one word.
//!
//! The panel reuses the composer's own walls (╭ ─ ╮ │ ╰ ╯) at the same inset,
//! so an open picker and the box under it read as one frame rather than two
//! unrelated widgets.
//!
//! LAW: every row is EXACTLY `width` columns, corner to corner. The painter
//! addresses screen row N as the Nth line of the composed frame (render.zig);
//! a row that measured wider would be chopped by the terminal — or, on a
//! terminal that ignores ?7l, wrapped — and every row below it would slide out
//! from under the row-to-line map that clicks, the sticky header and the
//! selection band all ride on.
//!
//! The two edge slots are not interchangeable. Anything the user must still be
//! able to read when the body OVERFLOWS the viewport goes in the top edge: a
//! panel taller than the screen has its bottom edge cut off, so a scroll hint
//! parked down there would be visible only when it was not needed.

const std = @import("std");

const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;

/// Below this the box is more chrome than content — two walls, two corner
/// dashes and a title would leave nothing for the rows — so the body is
/// returned unframed instead of being squeezed.
pub const min_width: usize = 16;

pub const Spec = struct {
    /// Named in the TOP edge.
    title: []const u8 = "",
    /// Right-hand slot of the TOP edge: a tally, a window position, a scroll
    /// hint. Top, never bottom — see the module note.
    note: []const u8 = "",
    /// Left-hand slot of the BOTTOM edge: what the keys do.
    footer: []const u8 = "",
    /// Body rows, newline-separated, already carrying their own SGR.
    body: []const u8 = "",
};

/// The two TOP-edge slots a picker fills in: what it is, and how much of it
/// the reader is looking at.
pub const Head = struct { title: []const u8, note: []const u8 };

/// The one row a WINDOWED list owes the reader: how much of it is off-screen.
/// Present for as long as the list overflows its window and never for a moment
/// less — a marker that came and went as the highlight moved would make every
/// row above it jump a line on an arrow key.
pub fn windowRow(a: std.mem.Allocator, th: Theme, off: usize, vis: usize, n: usize) ![]const u8 {
    const below = n -| (off + vis);
    const text = if (off > 0 and below > 0)
        try std.fmt.allocPrint(a, "  \u{2026} {d} above · {d} below", .{ off, below })
    else if (off > 0)
        try std.fmt.allocPrint(a, "  \u{2026} {d} above", .{off})
    else
        try std.fmt.allocPrint(a, "  \u{2026} {d} below", .{below});
    return theme_mod.paint(a, th.muted, text);
}

/// `spec` as a box exactly `width` columns wide, newline-terminated.
pub fn wrap(a: std.mem.Allocator, th: Theme, width: usize, spec: Spec) ![]const u8 {
    if (width < min_width) return a.dupe(u8, spec.body);
    var out = std.array_list.Managed(u8).init(a);
    // Bold accent title, muted note. grok-build's modal draws the same pair on
    // its top border: the dashes take the border colour and the title itself
    // stays bold, so the name reads as a label ON the frame rather than a row
    // of content that happens to be first.
    const title_sgr = try std.fmt.allocPrint(a, "{s}{s}", .{ theme_mod.bold, th.accent });
    try out.appendSlice(try edge(a, th, width, "╭", "╮", spec.title, title_sgr, spec.note, th.muted));
    try out.append('\n');
    // A body may paint MANY rows with one SGR prefix — the help block is one
    // string in one colour — and the painter repaints rows independently, so a
    // continuation row that carries no SGR of its own renders in whatever the
    // previous paint left behind. Same rule, and the same tracker, as the
    // wrappers in theme.zig: remember the pen and re-open it on every row.
    var active: theme_mod.Sgr = .{};
    var sgr_buf: [theme_mod.Sgr.max_render]u8 = undefined;
    var it = std.mem.splitScalar(u8, spec.body, '\n');
    while (it.next()) |ln| {
        // A body built with an append('\n') after every row ends in an empty
        // segment. Framing it would open a blank row above the footer that no
        // caller asked for.
        if (ln.len == 0 and it.rest().len == 0) break;
        try out.appendSlice(try row(a, th, width, ln, active.render(&sgr_buf)));
        try out.append('\n');
        noteAll(&active, ln);
    }
    try out.appendSlice(try edge(a, th, width, "╰", "╯", spec.footer, th.muted, "", th.muted));
    try out.append('\n');
    // Owned, not `items`: an ArrayList's buffer is longer than what it holds,
    // and a caller freeing the returned slice must be handed an allocation
    // whose length is the one the allocator recorded.
    return out.toOwnedSlice();
}

/// One body row: a wall, the text clipped and padded to the inner width, a
/// wall. The pad is measured with visibleLen, so a wide glyph moves the right
/// wall by the two cells it actually draws and never by the bytes it occupies.
fn row(a: std.mem.Allocator, th: Theme, width: usize, text: []const u8, carry: []const u8) ![]const u8 {
    const inner = width - 2;
    const shown = theme_mod.takeCols(text, inner);
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(th.border);
    try out.appendSlice("│");
    try out.appendSlice(theme_mod.reset);
    try out.appendSlice(carry);
    try out.appendSlice(shown);
    try out.appendSlice(theme_mod.reset);
    const cols = theme_mod.visibleLen(shown);
    if (cols < inner) try out.appendNTimes(' ', inner - cols);
    try out.appendSlice(th.border);
    try out.appendSlice("│");
    try out.appendSlice(theme_mod.reset);
    return out.items;
}

/// One horizontal edge, corner to corner, with the label and note inlaid.
///
/// Both slots degrade rather than overflow, in the order that keeps the panel
/// legible: the note goes first (it is a tally), then the label is clipped, and
/// a width with room for neither draws a plain rule. Nothing here may return a
/// row that is not exactly `width` columns.
fn edge(
    a: std.mem.Allocator,
    th: Theme,
    width: usize,
    left: []const u8,
    right: []const u8,
    label_in: []const u8,
    label_sgr: []const u8,
    note_in: []const u8,
    note_sgr: []const u8,
) ![]const u8 {
    const inner = width - 2;
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(th.border);
    try out.appendSlice(left);
    if (inner < 2) {
        try dashes(&out, inner);
        try out.appendSlice(right);
        try out.appendSlice(theme_mod.reset);
        return out.items;
    }
    // One dash hugs each corner, so a label never touches the corner glyph.
    const budget = inner - 2;
    var label = label_in;
    var note = note_in;
    var label_cols = slotCols(label);
    var note_cols = slotCols(note);
    if (label_cols + note_cols > budget) {
        note = "";
        note_cols = 0;
    }
    if (label_cols > budget) {
        label = fitLabel(label, budget);
        label_cols = slotCols(label);
    }
    const fill = budget - label_cols - note_cols;
    try dashes(&out, 1);
    if (label_cols > 0) try slot(&out, th, label, label_sgr);
    try dashes(&out, fill);
    if (note_cols > 0) try slot(&out, th, note, note_sgr);
    try dashes(&out, 1);
    try out.appendSlice(right);
    try out.appendSlice(theme_mod.reset);
    return out.items;
}

/// A label too wide for its edge, made to fit.
///
/// Hints are a "·"-joined list, ordered least-urgent first: "type to search ·
/// ↑↓ move · Enter pick · Esc". Clipping such a line from the RIGHT is exactly
/// backwards — a 40-column terminal kept "type to search · ↑↓ move · Enter pi"
/// and threw away the one key that closes the panel. Whole segments come off
/// the FRONT instead, so the last thing to survive is the last thing named.
fn fitLabel(label_in: []const u8, budget: usize) []const u8 {
    var label = label_in;
    while (slotCols(label) > budget) {
        const cut = std.mem.indexOf(u8, label, " · ") orelse break;
        label = label[cut + " · ".len ..];
    }
    // A single segment that still will not fit is clipped, as a title is.
    return if (slotCols(label) > budget) theme_mod.takeCols(label, budget -| 2) else label;
}

/// Columns a slot spends: the text plus the space either side of it. An empty
/// slot spends nothing at all — not even its spaces.
fn slotCols(s: []const u8) usize {
    return if (s.len == 0) 0 else theme_mod.visibleLen(s) + 2;
}

fn slot(out: *std.array_list.Managed(u8), th: Theme, text: []const u8, sgr: []const u8) !void {
    try out.append(' ');
    try out.appendSlice(sgr);
    try out.appendSlice(text);
    try out.appendSlice(theme_mod.reset);
    try out.appendSlice(th.border);
    try out.append(' ');
}

/// Fold every escape in `s` into the tracker — the whole line, not the clipped
/// part: a colour set past the right wall still governs the row after it.
fn noteAll(active: *theme_mod.Sgr, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != 0x1b) continue;
        const end = theme_mod.skipEsc(s, i);
        active.note(s[i..end]);
        i = end - 1;
    }
}

fn dashes(out: *std.array_list.Managed(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try out.appendSlice("─");
}

const testing = std.testing;

test "every row of a panel is exactly `width` columns" {
    // The painter contract, at the one place a box can break it. Titles and
    // notes long enough to need every degrade step are in the table on purpose.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    const specs = [_]Spec{
        .{ .title = "Model", .note = "3/75", .footer = "↑↓ move · Enter pick · Esc", .body = "› one\n  two\n" },
        .{ .title = "", .note = "", .footer = "", .body = "bare\n" },
        .{ .title = "a title far too long to fit any narrow terminal edge at all", .note = "999/999", .footer = "and a footer hint that is itself much too long to sit in the bottom rule", .body = "x\n" },
        .{ .title = "Model › 日本語のフィルタ▋", .note = "0/75", .footer = "Esc", .body = "  🚀 wide glyph row that runs long enough to be clipped by the wall\n" },
        .{ .title = "T", .note = "N", .footer = "F", .body = "" },
    };
    for (specs) |spec| {
        for ([_]usize{ 16, 17, 20, 24, 40, 41, 60, 80, 120, 200 }) |w| {
            const box = try wrap(a, th, w, spec);
            var it = std.mem.splitScalar(u8, box, '\n');
            var n: usize = 0;
            while (it.next()) |ln| {
                if (ln.len == 0 and it.rest().len == 0) break;
                try testing.expectEqual(w, theme_mod.visibleLen(ln));
                n += 1;
            }
            try testing.expect(n >= 2); // two edges, always
        }
    }
}

test "the title rides in the top edge and the footer in the bottom one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const box = try wrap(arena.allocator(), theme_mod.of(.night), 60, .{
        .title = "Commands",
        .note = "4/12",
        .footer = "Enter run · Esc",
        .body = "› /new\n  /home\n",
    });
    var it = std.mem.splitScalar(u8, box, '\n');
    const top = it.next().?;
    try testing.expect(std.mem.indexOf(u8, top, "╭") != null);
    try testing.expect(std.mem.indexOf(u8, top, "Commands") != null);
    try testing.expect(std.mem.indexOf(u8, top, "4/12") != null);
    // The note sits to the RIGHT of the title, never before it.
    try testing.expect(std.mem.indexOf(u8, top, "Commands").? < std.mem.indexOf(u8, top, "4/12").?);
    const r1 = it.next().?;
    try testing.expect(std.mem.indexOf(u8, r1, "│") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "/new") != null);
    _ = it.next().?;
    const bottom = it.next().?;
    try testing.expect(std.mem.indexOf(u8, bottom, "╰") != null);
    try testing.expect(std.mem.indexOf(u8, bottom, "Enter run · Esc") != null);
    try testing.expect(std.mem.indexOf(u8, bottom, "╯") != null);
    // Three body rows would mean the body's trailing newline opened a blank one.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, box, "\n"));
}

test "a narrow edge drops the note before it clips the title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    // 24 columns: the title, its two spaces, the two corner dashes and the two
    // corners come to exactly 22, so the tally has nowhere to go — and the
    // title, which names the panel, survives whole.
    const box = try wrap(a, th, 24, .{ .title = "Reasoning effort", .note = "6/6", .body = "x\n" });
    const top = box[0..std.mem.indexOfScalar(u8, box, '\n').?];
    try testing.expect(std.mem.indexOf(u8, top, "Reasoning effort") != null);
    try testing.expect(std.mem.indexOf(u8, top, "6/6") == null);
    try testing.expectEqual(@as(usize, 24), theme_mod.visibleLen(top));
}

test "a hint too wide for the edge loses its first segment, never its last" {
    // "Esc" is what gets you out. Right-clipping dropped it and kept "type to
    // sea"; segment-dropping keeps the keys and loses the prose.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = theme_mod.of(.night);
    const long = "type to search · ↑↓ move · Enter pick · Esc";
    for ([_]usize{ 24, 32, 40, 48 }) |w| {
        const box = try wrap(a, th, w, .{ .title = "Model", .footer = long, .body = "x\n" });
        var it = std.mem.splitScalar(u8, box, '\n');
        var last: []const u8 = "";
        while (it.next()) |ln| {
            if (ln.len > 0) last = ln;
        }
        try testing.expect(std.mem.indexOf(u8, last, "Esc") != null);
        try testing.expectEqual(w, theme_mod.visibleLen(last));
    }
    // Wide enough and the whole hint is there.
    const wide = try wrap(a, th, 80, .{ .title = "Model", .footer = long, .body = "x\n" });
    try testing.expect(std.mem.indexOf(u8, wide, "type to search") != null);
}

test "below min_width the body comes back unframed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try wrap(arena.allocator(), theme_mod.of(.night), 10, .{ .title = "X", .body = "row\n" });
    try testing.expectEqualStrings("row\n", got);
}

test "panel colours come from the theme, never from a literal" {
    // Every panel byte that is not content is a border token or a reset. A raw
    // SGR literal here would survive a theme switch and paint grok-night walls
    // on the day palette.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (theme_mod.all) |id| {
        const th = theme_mod.of(id);
        const box = try wrap(a, th, 40, .{ .title = "T", .note = "N", .footer = "F", .body = "r\n" });
        try testing.expect(std.mem.indexOf(u8, box, th.border) != null);
        try testing.expect(std.mem.indexOf(u8, box, th.accent) != null);
        try testing.expect(std.mem.indexOf(u8, box, th.muted) != null);
    }
}
