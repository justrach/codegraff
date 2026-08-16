//! Line-editor input helpers split out of main.zig (600-line goal): tab
//! completion (fillCompletions), line-wrap math (wrapAt/LineRender/
//! parseDsrCol), the ultracode ember-shine palette, the `@` file picker's
//! binary/dir filters + file collection (codedb-backed with a walk
//! fallback), drag-and-drop path cleanup, and the redraw + buffer-editing
//! helpers hoisted out of readLine's body (redraw/setLine/delRange/
//! prevWord/nextWord/addMark) so readline.zig stays under the line goal.
//! readline.zig is this file's only consumer of those; main.zig back-
//! aliases isImagePath (vision.zig also back-imports it) and binaryFileExt
//! (a read_file guard elsewhere in main.zig calls it directly), and
//! mod-qualifies the mutable g_shine_phase (ultracode wave animation frame,
//! written by readLine's idle-tick loop, read by ultracodeWaveHue here).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const terminal = @import("term.zig");
const termCols = terminal.termCols;

const jobs = @import("jobs.zig");
const runCapped = jobs.runCapped;

const pricing = @import("pricing.zig");
const util = @import("util.zig");

const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const tools_mod = @import("tools.zig");
const repl_commands = main_mod.repl_commands;
const bash_stdout_cap = tools_mod.bash_stdout_cap;

pub var g_shine_phase: usize = 0; // ultracode input-wave animation frame

/// One byte of terminal input for the editor's CONTINUATION reads — the DSR
/// reply, an escape/CSI tail, a bracketed-paste body. Job-control aware via
/// tty.promptByte (#396), and null means "stop reading this sequence" for both
/// EOF and the backgrounded case, which is what every one of those call sites
/// already did with a read error. The prompt's own idle read stays in
/// readLine: only it can tell the two apart and must exit on the background.
pub fn editByte(in: *Io.Reader) ?u8 {
    return switch (terminal.tty.promptByte(in)) {
        .byte => |b| b,
        .eof, .background => null,
    };
}

/// Tab-completion candidates for the current input. After `/model ` →
/// model names (deduped) + provider ids matching the partial; a bare `/word`
/// → slash commands. Returns the byte offset of the word being completed
/// (so the caller can splice in a candidate). Candidates are static slices.
pub fn fillCompletions(gpa: Allocator, line: []const u8, out: *std.ArrayList([]const u8)) usize {
    const mp = "/model ";
    if (std.mem.startsWith(u8, line, mp)) {
        const partial = line[mp.len..];
        for (pricing.models()) |m| {
            if (!std.mem.startsWith(u8, m.name, partial)) continue;
            var dup = false;
            for (out.items) |x| if (std.mem.eql(u8, x, m.name)) {
                dup = true;
            };
            if (!dup) out.append(gpa, m.name) catch {};
        }
        for (0..provider_mod.specCount()) |i| {
            const spec = provider_mod.specAt(i).?;
            if (std.mem.startsWith(u8, spec.id, partial)) out.append(gpa, spec.id) catch {};
        }
        return mp.len;
    }
    if (line.len > 0 and line[0] == '/' and std.mem.indexOfScalar(u8, line, ' ') == null) {
        for (repl_commands) |cmd| if (std.mem.startsWith(u8, cmd, line)) out.append(gpa, cmd) catch {};
        return 0;
    }
    return line.len;
}

/// Screen position of a byte in a wrapped input line: given the prompt width
/// `plen` (columns the prompt occupies on the first row), terminal width
/// `cols`, and byte index `pos` into the buffer, the cursor's 0-based row
/// (counted from the prompt row) and 0-based column. The buffer wraps every
/// `cols` columns, so a byte sitting just past a row edge is col 0 of the next
/// row. Pure (unit-tested below); redraw uses it to place the cursor.
fn wrapAt(plen: usize, cols: usize, pos: usize) struct { row: usize, col: usize } {
    const c = if (cols == 0) 1 else cols;
    const flat = plen + pos;
    return .{ .row = flat / c, .col = flat % c };
}

/// Persisted across `readLine`'s redraws: how many rows the wrapped input
/// occupied last time (a count ≥1) and which 0-based row the cursor sat on.
/// The redraw clears exactly these rows relative to where the cursor is now —
/// no absolute cursor save (DECSC), which a wrap-induced scroll would strand.
/// Input taller than the screen is unsupported (same caveat as bash/zsh).
pub const LineRender = struct { rows: usize = 1, crow: usize = 0 };

/// Column from a DSR cursor-position reply — `seq` is the CSI body with the
/// ESC stripped, e.g. "[12;34R". Null (caller falls back to column 1) on
/// anything malformed, including the meaningless column 0.
pub fn parseDsrCol(seq: []const u8) ?usize {
    if (seq.len < 5 or seq[0] != '[' or seq[seq.len - 1] != 'R') return null;
    const semi = std.mem.indexOfScalar(u8, seq, ';') orelse return null;
    const col = std.fmt.parseInt(usize, seq[semi + 1 .. seq.len - 1], 10) catch return null;
    return if (col == 0) null else col;
}

/// Ctrl-D, the byte `readLine` reads as EOF-on-an-empty-line.
pub const eof_key: u8 = 0x04;

/// Translate one byte of type-ahead — input that was already queued on the tty
/// when `readLine` switched it into raw mode, so the LINE DISCIPLINE, not the
/// editor, decided what those bytes look like (#364).
///
/// Linux's n_tty does not deliver a canonical-mode VEOF (Ctrl-D) verbatim: it
/// substitutes `__DISABLED_CHAR` (NUL) into the read buffer and uses it as an
/// end-of-line marker. Read back in canonical mode that surfaces as a 0-byte
/// read (EOF); read back in RAW mode — which is what happens when a Ctrl-D
/// lands in the sliver between a turn restoring the terminal and the next
/// prompt claiming it — it surfaces as a literal 0x00. readLine had no case
/// for that byte, so the keystroke was dropped and the REPL sat at the prompt
/// forever waiting for a quit that had already been typed. macOS/BSD hand the
/// 0x04 back unchanged, which is why the pty regression only ever hung on
/// Linux. Mapping the marker back to the key it stands for makes the race
/// harmless instead of fatal: whichever side of the mode switch the byte lands
/// on, Ctrl-D means Ctrl-D.
///
/// Scoped to type-ahead deliberately. A NUL typed at a live prompt (Ctrl-@ /
/// Ctrl-Space) is not an EOF request and keeps its current do-nothing
/// behavior; only bytes the canonical line discipline already processed are
/// reinterpreted.
pub fn typeAheadByte(b: u8) u8 {
    return if (b == 0) eof_key else b;
}

test "type-ahead NUL is the line discipline's Ctrl-D, everything else is itself" {
    try std.testing.expectEqual(eof_key, typeAheadByte(0));
    try std.testing.expectEqual(eof_key, typeAheadByte(eof_key));
    try std.testing.expectEqual(@as(u8, 'a'), typeAheadByte('a'));
    try std.testing.expectEqual(@as(u8, '\r'), typeAheadByte('\r'));
    try std.testing.expectEqual(@as(u8, 0x03), typeAheadByte(0x03)); // Ctrl-C still cancels the line
    try std.testing.expectEqual(@as(u8, 0x1b), typeAheadByte(0x1b));
}

/// Sumi-rust → vermilion → warm-gold stops for the ultracode ember wave.
const ultracode_rgb = [_]struct { r: u8, g: u8, b: u8 }{
    .{ .r = 168, .g = 99, .b = 67 },
    .{ .r = 179, .g = 92, .b = 73 },
    .{ .r = 196, .g = 81, .b = 61 },
    .{ .r = 179, .g = 92, .b = 73 },
    .{ .r = 155, .g = 106, .b = 53 },
    .{ .r = 165, .g = 101, .b = 59 },
};

/// Smoothly interpolated ember hue for the ultracode wave. `pos_q8` uses an
/// 8-bit stop index + 8-bit blend, so the color glides instead of snapping.
/// The palette stays at a steady luminance: motion comes from the slow hue
/// drift, not a flashing brightness pulse.
fn ultracodeWaveHue(w: *Io.Writer, pos_q8: u16, phase: usize) void {
    const pal = &ultracode_rgb;
    const len: u16 = pal.len;
    const p: u16 = pos_q8 +% @as(u16, @truncate(phase *% 16));
    const idx: u16 = (p >> 8) % len;
    const frac: u16 = p & 0xff;
    const a = pal[idx];
    const b = pal[(idx + 1) % len];
    // Interpolate in signed space (b-a may be negative) then clamp to 0..255.
    const r: i32 = @as(i32, a.r) + @divTrunc((@as(i32, b.r) - @as(i32, a.r)) * @as(i32, frac), 256);
    const g: i32 = @as(i32, a.g) + @divTrunc((@as(i32, b.g) - @as(i32, a.g)) * @as(i32, frac), 256);
    const bl: i32 = @as(i32, a.b) + @divTrunc((@as(i32, b.b) - @as(i32, a.b)) * @as(i32, frac), 256);
    const cr: u8 = @intCast(@max(0, @min(255, r)));
    const cg: u8 = @intCast(@max(0, @min(255, g)));
    const cb: u8 = @intCast(@max(0, @min(255, bl)));
    w.print("\x1b[38;2;{d};{d};{d}m", .{ cr, cg, cb }) catch {};
}

/// Directories the `@` file picker never descends into (every dot-dir is
/// also skipped): package/build output and caches — never @-mention targets.
const atpick_skip_dirs = [_][]const u8{ "node_modules", "zig-out", "zig-cache", "__pycache__", "venv", "target", "dist", "build" };
const atpick_max_files = 5000;

fn atpickSkipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (atpick_skip_dirs) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Extensions treated as binary: hidden from the `@` picker and refused by
/// read_file (which points the model at bash converters like pdftotext).
const binary_exts = [_][]const u8{ "pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "icns", "tiff", "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "exe", "dll", "so", "dylib", "a", "o", "wasm", "class", "jar", "pyc", "woff", "woff2", "ttf", "otf", "eot", "mp3", "mp4", "m4a", "mov", "avi", "mkv", "wav", "flac", "ogg", "sqlite", "db", "bin" };

pub fn binaryFileExt(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (binary_exts) |b| if (std.ascii.eqlIgnoreCase(ext, b)) return true;
    return false;
}

/// Image types stageImagePath understands (a dropped one becomes a vision
/// attachment instead of an inlined path).
pub fn isImagePath(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Pull the `@` picker's file list from codedb's index (`codedb glob '**/*'`):
/// gitignore-aware and instant once the repo is indexed, unlike the blind
/// walk below. Returns false when codedb is missing, errors, or knows no
/// files — the caller falls back to the walk. Entries are gpa-owned.
fn collectCodedbFiles(io: Io, gpa: Allocator, files: *std.ArrayList([]const u8)) bool {
    const run = runCapped(gpa, io, &.{ "codedb", "glob", "**/*" }, bash_stdout_cap, 4096, 0) catch return false;
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    const code: ?u8 = switch (run.term) {
        .exited => |c| c,
        else => null,
    };
    if (code == null or code.? != 0) return false;
    // A truncated capture may end mid-path: only parse up to the last newline.
    const safe_end = if (run.stdout_truncated)
        (std.mem.lastIndexOfScalar(u8, run.stdout, '\n') orelse 0)
    else
        run.stdout.len;
    var it = std.mem.splitScalar(u8, run.stdout[0..safe_end], '\n');
    while (it.next()) |ln| {
        if (files.items.len >= atpick_max_files) break;
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        if (binaryFileExt(line)) continue; // PDFs/images/archives: not @-mention targets
        const dup = gpa.dupe(u8, line) catch continue;
        files.append(gpa, dup) catch gpa.free(dup);
    }
    return files.items.len > 0;
}

/// Collect file paths (relative to cwd) for the `@` picker: codedb's index
/// when available, else an iterative breadth-first walk skipping
/// atpickSkipDir directories, capped at atpick_max_files. Entries are
/// gpa-owned; the caller frees them.
pub fn collectRepoFiles(io: Io, gpa: Allocator, files: *std.ArrayList([]const u8)) void {
    if (collectCodedbFiles(io, gpa, files)) return;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    dirs.append(gpa, gpa.dupe(u8, ".") catch return) catch return;
    var head: usize = 0;
    while (head < dirs.items.len) : (head += 1) {
        const dpath = dirs.items[head];
        const top = std.mem.eql(u8, dpath, ".");
        var dir = Io.Dir.cwd().openDir(io, dpath, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (files.items.len >= atpick_max_files) return;
            switch (entry.kind) {
                .directory => {
                    if (atpickSkipDir(entry.name)) continue;
                    const rel = if (top) gpa.dupe(u8, entry.name) catch continue else std.fmt.allocPrint(gpa, "{s}/{s}", .{ dpath, entry.name }) catch continue;
                    dirs.append(gpa, rel) catch gpa.free(rel);
                },
                .file, .sym_link => {
                    if (binaryFileExt(entry.name)) continue; // PDFs/images/archives: not @-mention targets
                    const rel = if (top) gpa.dupe(u8, entry.name) catch continue else std.fmt.allocPrint(gpa, "{s}/{s}", .{ dpath, entry.name }) catch continue;
                    files.append(gpa, rel) catch gpa.free(rel);
                },
                else => {},
            }
        }
    }
}

/// Recognize a bracketed paste that is a drag-and-dropped file path: one
/// line, possibly quoted or backslash-escaped (terminals escape spaces and
/// append a trailing space), naming an absolute path after ~ expansion.
/// Returns the cleaned path (gpa-owned), else null. The caller is
/// responsible for checking that the path actually exists.
pub fn cleanDroppedPath(gpa: Allocator, home: []const u8, pasted: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, pasted, " \t\r\n");
    if (s.len < 2 or std.mem.indexOfScalar(u8, s, '\n') != null) return null;
    if ((s[0] == '\'' and s[s.len - 1] == '\'') or (s[0] == '"' and s[s.len - 1] == '"'))
        s = s[1 .. s.len - 1];
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa);
    if (std.mem.startsWith(u8, s, "~/") and home.len > 0) {
        clean.appendSlice(gpa, home) catch return null;
        s = s[1..];
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = if (s[i] == '\\' and i + 1 < s.len) blk: {
            i += 1;
            break :blk s[i];
        } else s[i];
        clean.append(gpa, ch) catch return null;
    }
    if (clean.items.len == 0 or clean.items[0] != '/') return null;
    return clean.toOwnedSlice(gpa) catch null;
}

// Redraw the whole input below a fixed prompt prefix, wrapping it
// across rows. Spans listed in `marks` (paths from the @ picker or a
// file drop, plus "[Image]") render as an accent chip (reverse video +
// Codegraff emerald) so they keep reading as attached files, not typed words; a
// chip crossing a row break keeps its colour. `st` carries the row
// count + cursor row of the previous draw so this one can clear it
// with relative moves only — no DECSC anchor for a scroll to strand.
pub fn redraw(o: *Io.Writer, items: []const u8, c: usize, marks: []const []const u8, st: *LineRender, pcol: usize) void {
    const cols = termCols();
    const plen = if (pcol > 0) pcol - 1 else 0; // columns the prompt holds on row 0

    // Clear the previous block: drop to its bottom row, then clear
    // bottom-up. Row 0 is cleared only past the prompt so the prompt
    // survives. Every move is relative, so a prior scroll is harmless.
    if (st.rows - 1 > st.crow) o.print("\x1b[{d}B", .{st.rows - 1 - st.crow}) catch {};
    var k = st.rows - 1;
    while (k > 0) : (k -= 1) o.writeAll("\r\x1b[K\x1b[A") catch {};
    o.writeAll("\r") catch {};
    if (plen > 0) o.print("\x1b[{d}C", .{plen}) catch {};
    o.writeAll("\x1b[K") catch {};

    // Re-emit the buffer, wrapping by hand at the right edge (a literal
    // "\r\n" every `cols` columns) rather than trusting terminal
    // autowrap, whose last-column "pending wrap" state is ambiguous.
    var i: usize = 0;
    var row: usize = 0;
    var vcol: usize = plen;
    var mark_end: usize = 0;
    var mark_open = false;
    const secret_start = util.sensitiveInputStart(items);
    // `ultracode` shines the input itself: each letter of every
    // (case-insensitive) occurrence renders in a rotating ember hue.
    var shine_starts: [8]usize = undefined;
    var shine_ends: [8]usize = undefined;
    var nshine: usize = 0;
    if (main_mod.use_color) {
        var si: usize = 0;
        while (si + 9 <= items.len) : (si += 1) {
            if (std.ascii.eqlIgnoreCase(items[si .. si + 9], "ultracode")) {
                if (nshine < shine_starts.len) {
                    shine_starts[nshine] = si;
                    shine_ends[nshine] = si + 9;
                    nshine += 1;
                }
            }
        }
    }
    var shine_active = false;
    while (i < items.len) {
        const masked = if (secret_start) |start| i >= start else false;
        if (vcol >= cols) { // row full → wrap to the next
            o.writeAll("\r\n") catch {};
            row += 1;
            vcol = 0;
        }
        if (!mark_open) { // open a chip that starts here (longest wins)
            var best: usize = 0;
            for (marks) |m| {
                if (m.len == 0 or i + m.len > items.len) continue;
                if (std.mem.eql(u8, items[i .. i + m.len], m) and m.len > best) best = m.len;
            }
            if (best > 0) {
                if (shine_active) {
                    o.writeAll("\x1b[0m") catch {};
                    shine_active = false;
                }
                o.writeAll(if (main_mod.use_color) "\x1b[7;38;2;5;150;105m" else "\x1b[7m") catch {};
                mark_end = i + best;
                mark_open = true;
            }
        }
        // Ember shine for an `ultracode` span (skipped inside a chip).
        if (!mark_open and !masked) {
            var in_shine = false;
            for (shine_starts[0..nshine], shine_ends[0..nshine]) |sstart, send| {
                if (i >= sstart and i < send) {
                    // Smooth interpolated hue; pos_q8 spreads the word across
                    // one palette pass.
                    ultracodeWaveHue(o, @intCast((i - sstart) * 256), g_shine_phase);
                    in_shine = true;
                    break;
                }
            }
            if (in_shine) {
                shine_active = true;
            } else if (shine_active) {
                o.writeAll("\x1b[0m") catch {};
                shine_active = false;
            }
        }
        o.writeByte(if (masked) '*' else items[i]) catch {};
        vcol += 1;
        i += 1;
        if (mark_open and i == mark_end) {
            o.writeAll("\x1b[0m") catch {};
            mark_open = false;
            shine_active = false;
        }
    }
    if (mark_open or shine_active) o.writeAll("\x1b[0m") catch {};

    // Place the cursor. wrapAt gives its target row/col; when it sits
    // at the very end of a just-filled row that's a fresh row below the
    // text (the classic last-column case), realise it with a newline so
    // the next keystroke stays visible.
    const tgt = wrapAt(plen, cols, c);
    while (tgt.row > row) {
        o.writeAll("\r\n") catch {};
        row += 1;
    }
    if (row > tgt.row) o.print("\x1b[{d}A", .{row - tgt.row}) catch {};
    o.writeAll("\r") catch {};
    if (tgt.col > 0) o.print("\x1b[{d}C", .{tgt.col}) catch {};
    o.flush() catch {};

    st.rows = row + 1;
    st.crow = tgt.row;
}

pub fn setLine(g: Allocator, b: *std.ArrayList(u8), s: []const u8) void {
    b.clearRetainingCapacity();
    b.appendSlice(g, s) catch {};
}

pub fn delRange(b: *std.ArrayList(u8), a: usize, e: usize) void {
    std.mem.copyForwards(u8, b.items[a..], b.items[e..]);
    b.shrinkRetainingCapacity(b.items.len - (e - a));
}

pub fn prevWord(items: []const u8, c: usize) usize {
    var i = c;
    while (i > 0 and items[i - 1] == ' ') i -= 1;
    while (i > 0 and items[i - 1] != ' ') i -= 1;
    return i;
}

pub fn nextWord(items: []const u8, c: usize) usize {
    var i = c;
    while (i < items.len and items[i] == ' ') i += 1;
    while (i < items.len and items[i] != ' ') i += 1;
    return i;
}

pub fn addMark(g: Allocator, ms: *std.ArrayList([]const u8), s: []const u8) void {
    for (ms.items) |m| if (std.mem.eql(u8, m, s)) return;
    const dup = g.dupe(u8, s) catch return;
    ms.append(g, dup) catch g.free(dup);
}

test "cleanDroppedPath unescapes terminal drops" {
    const gpa = std.testing.allocator;
    const p = cleanDroppedPath(gpa, "", "/tmp/My\\ File.txt ") orelse return error.TestUnexpectedResult;
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/tmp/My File.txt", p);
    const q = cleanDroppedPath(gpa, "/home/u", "'~/notes/a b.md'") orelse return error.TestUnexpectedResult;
    defer gpa.free(q);
    try std.testing.expectEqualStrings("/home/u/notes/a b.md", q);
    try std.testing.expect(cleanDroppedPath(gpa, "", "hello world") == null); // not absolute
    try std.testing.expect(cleanDroppedPath(gpa, "", "two\nlines") == null); // multi-line
}

test "binaryFileExt flags binaries, passes text" {
    try std.testing.expect(binaryFileExt("paper.pdf"));
    try std.testing.expect(binaryFileExt("shot.PNG")); // case-insensitive
    try std.testing.expect(binaryFileExt("lib.a"));
    try std.testing.expect(!binaryFileExt("main.zig"));
    try std.testing.expect(!binaryFileExt("README.md"));
    try std.testing.expect(!binaryFileExt("Makefile")); // no extension
    try std.testing.expect(isImagePath("a.jpeg"));
    try std.testing.expect(!isImagePath("a.pdf"));
}

test "wrapAt: rows and columns across the right edge" {
    // No prompt, 10-column terminal: bytes 0..9 fill row 0.
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 10, 0).row);
    try std.testing.expectEqual(@as(usize, 5), wrapAt(0, 10, 5).col);
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 10, 9).row);
    // Byte 10 is the first cell of row 1.
    try std.testing.expectEqual(@as(usize, 1), wrapAt(0, 10, 10).row);
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 10, 10).col);
    // Byte 25 → row 2, col 5.
    try std.testing.expectEqual(@as(usize, 2), wrapAt(0, 10, 25).row);
    try std.testing.expectEqual(@as(usize, 5), wrapAt(0, 10, 25).col);
}

test "wrapAt: a prompt prefix shifts the whole line right" {
    // 4-column prompt: byte 5 sits at column 9 of row 0 (4+5).
    try std.testing.expectEqual(@as(usize, 0), wrapAt(4, 10, 5).row);
    try std.testing.expectEqual(@as(usize, 9), wrapAt(4, 10, 5).col);
    // byte 6 → 4+6 == 10 → row 1, col 0.
    try std.testing.expectEqual(@as(usize, 1), wrapAt(4, 10, 6).row);
    try std.testing.expectEqual(@as(usize, 0), wrapAt(4, 10, 6).col);
}

test "wrapAt: zero columns never divides by zero" {
    try std.testing.expectEqual(@as(usize, 0), wrapAt(0, 0, 3).col);
}

test "parseDsrCol: well-formed and malformed replies" {
    try std.testing.expectEqual(@as(?usize, 34), parseDsrCol("[12;34R"));
    try std.testing.expectEqual(@as(?usize, 1), parseDsrCol("[1;1R"));
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("[12R")); // no column
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("[1;0R")); // col 0 is meaningless
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("[1;xR"));
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol("12;34R")); // missing CSI intro
    try std.testing.expectEqual(@as(?usize, null), parseDsrCol(""));
}

test "fillCompletions includes ultracode slash command" {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    _ = fillCompletions(std.testing.allocator, "/ult", &out);
    var found = false;
    for (out.items) |item| {
        if (std.mem.eql(u8, item, "/ultracode")) found = true;
    }
    try std.testing.expect(found);
}

test "isImagePath: known image extensions, case-insensitive" {
    try std.testing.expect(isImagePath("photo.png"));
    try std.testing.expect(isImagePath("a.JPEG"));
    try std.testing.expect(isImagePath("x.webp"));
    try std.testing.expect(isImagePath("dir/sub/pic.gif"));
    try std.testing.expect(!isImagePath("readme.md"));
    try std.testing.expect(!isImagePath("noext"));
    try std.testing.expect(!isImagePath("archive.tar.gz"));
}
