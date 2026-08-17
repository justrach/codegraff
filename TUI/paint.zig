//! The frame painter: the only code in the TUI that writes cells to a screen.
//!
//! One invariant, and every line below exists to hold it: **when paint()
//! returns, each of the `rows` screen rows shows the matching line of `frame`
//! and nothing else** — no cell of an older frame, no colour borrowed from a
//! row that happened to be painted earlier.
//!
//! Two mechanisms carry it.
//!
//!   * Every repainted row re-establishes its own style before its first cell
//!     (SGR reset, then the theme background). A diff paint rewrites an
//!     ARBITRARY SUBSET of rows, so a row that inherited fg/inverse from the
//!     row above it under a full paint would inherit whatever the last
//!     repainted row left behind under a diff paint: the same frame bytes,
//!     two different pictures.
//!   * Every repainted row is covered out to the last column. A row the frame
//!     proves SHORTER than the screen is written, padded with the theme
//!     background and erased to end of line. A row that MEASURES full is
//!     erased FIRST and written after — a trailing erase would sit on the last
//!     cell and eat it (that is what ate the composer's right border), and
//!     simply skipping the erase trusted visibleLen to agree with the terminal
//!     about every ambiguous-width glyph on the row. When it does not agree,
//!     the cells past the last glyph the terminal actually drew keep the
//!     PREVIOUS frame. Erase-first is right whether the measurement is or not.

const std = @import("std");
const Io = std.Io;

const scrollpaint = @import("scrollpaint.zig");
const theme_mod = @import("theme.zig");

/// Rewrite only rows that changed, so a drag-select on older transcript
/// survives a live token / thinking tick.
///
/// `prev` empty  -> clear the screen and lay down every row (first paint, and
///                  after anything that blanks the alt screen: SIGCONT, a
///                  resize, a theme flip).
/// `force` true  -> rewrite every row WITHOUT the clear: the self-heal repaint.
///                  The bytes are the frame we already believe is on screen, so
///                  under synchronized output (?2026) it is visually a no-op —
///                  but it is also the only thing that can repair a screen some
///                  other writer, or a terminal-side reflow, has disturbed.
/// `hint` set     -> the composer believes the viewport merely SLID. Row i is
///                  then the wrong thing to compare row i against, and every
///                  row of the band reads as changed; scrollpaint.zig checks
///                  the claim against both frames and, when it holds, has the
///                  terminal do the sliding. It never writes on a refusal, so
///                  falling through here is always safe. The self-heal MUST
///                  bypass it: its whole job is to rewrite rows that are
///                  already correct, which is precisely what a scroll skips.
pub fn paint(
    w: *Io.Writer,
    frame: []const u8,
    rows: usize,
    cols: usize,
    prev: []const u8,
    bg: []const u8,
    force: bool,
    hint: ?scrollpaint.Hint,
) !void {
    if (prev.len == 0) {
        try w.writeAll(bg);
        try w.writeAll("\x1b[2J\x1b[H");
        var row: usize = 0;
        var it = std.mem.splitScalar(u8, frame, '\n');
        while (row < rows) : (row += 1) {
            try paintRow(w, if (it.next()) |ln| ln else "", cols, bg);
            if (row + 1 < rows) try w.writeAll("\r\n");
        }
        // No trailing ED here. The release tip added one ("erase below, so a
        // scrolled alt screen self-heals"), but the `\x1b[2J` above already
        // clears the WHOLE display, scrolled rows included — while ED is
        // cursor-INCLUSIVE, and with autowrap off the cursor sits ON the last
        // column after a bottom row that measures full. It would erase the
        // glyph the erase-first branch just drew. Pinned below.
        try w.flush();
        return;
    }
    if (!force) {
        if (hint) |h| {
            if (try scrollpaint.tryPaint(w, frame, rows, cols, prev, bg, h)) return;
        }
    }
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        if (!force and !rowChanged(prev, frame, row)) continue;
        try w.print("\x1b[{d};1H", .{row + 1});
        try paintRow(w, nthLine(frame, row), cols, bg);
    }
    try w.flush();
}

/// One row, cursor already at its first column. See the file header: the
/// prologue makes the row's style self-contained, and the two shapes below are
/// the entire residue story.
pub fn paintRow(w: *Io.Writer, ln: []const u8, cols: usize, bg: []const u8) !void {
    try w.writeAll(row_prologue);
    try w.writeAll(bg);
    // Measure and write the same cells: a smuggled CR/BEL/BS is not a column
    // and must not reach the terminal (CR rewinds the row, BEL rings, BS
    // walks the cursor back). Tab stays — it is legal prose. ESC stays —
    // that is SGR. The frame builders already strip this; this is the last
    // door so a leak cannot desync the row↔line map.
    const vis = cellLen(ln);
    if (vis < cols) {
        try writeCells(w, ln);
        try pad(w, cols - vis);
        try w.writeAll(bg);
        try w.writeAll("\x1b[K");
        return;
    }
    // Provably-full or over-wide: erase the whole row up front, then draw.
    try w.writeAll("\x1b[K");
    // Autowrap is off (?7l), so an over-wide row piles onto the last cell
    // rather than wrapping — but a terminal that ignores ?7l would push every
    // row below down by one and desync the row↔line map for the whole screen.
    // Cut it to fit and the question never arises.
    try writeCells(w, if (vis > cols) takeCells(ln, cols) else ln);
}

/// SGR reset (all attributes, including inverse from a selection band). The
/// theme background is re-applied immediately after, so this never leaves the
/// canvas on the terminal's default.
pub const row_prologue = "\x1b[m";

fn pad(w: *Io.Writer, cells: usize) !void {
    var n = cells;
    while (n > 0) : (n -= 1) try w.writeByte(' ');
}

/// C0/DEL that must never be a cell. Tab is kept (legal prose); ESC is kept
/// (SGR) and handled by the callers before they reach this.
fn isRowControl(b: u8) bool {
    return (b < 0x20 and b != '\t') or b == 0x7f;
}

fn cellLen(ln: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < ln.len) {
        if (ln[i] == 0x1b) {
            i = theme_mod.skipEsc(ln, i);
            continue;
        }
        if (isRowControl(ln[i])) {
            i += 1;
            continue;
        }
        const c = theme_mod.cpAt(ln, i);
        i += c.step;
        n += c.w;
    }
    return n;
}

fn takeCells(ln: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < ln.len) {
        if (ln[i] == 0x1b) {
            i = theme_mod.skipEsc(ln, i);
            continue;
        }
        if (isRowControl(ln[i])) {
            i += 1;
            continue;
        }
        const c = theme_mod.cpAt(ln, i);
        if (n + c.w > max) break;
        i += c.step;
        n += c.w;
    }
    return ln[0..i];
}

fn writeCells(w: *Io.Writer, ln: []const u8) !void {
    var i: usize = 0;
    while (i < ln.len) {
        if (ln[i] == 0x1b) {
            const e = theme_mod.skipEsc(ln, i);
            try w.writeAll(ln[i..e]);
            i = e;
            continue;
        }
        if (isRowControl(ln[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < ln.len and ln[i] != 0x1b and !isRowControl(ln[i])) : (i += 1) {}
        try w.writeAll(ln[start..i]);
    }
}

pub fn nthLine(s: []const u8, row: usize) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    var i: usize = 0;
    while (it.next()) |ln| : (i += 1) {
        if (i == row) return ln;
    }
    return "";
}

pub fn rowChanged(prev: []const u8, frame: []const u8, row: usize) bool {
    return !std.mem.eql(u8, nthLine(prev, row), nthLine(frame, row));
}
