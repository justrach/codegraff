//! The interactive line editor: readLine() reads one input line in raw
//! terminal mode with history navigation (HistoryNav, #101), tab
//! completion, bracketed paste, the `@` file picker, drag-and-drop path
//! insertion, and clipboard image paste (Ctrl-V). Split out of main.zig
//! (600-line goal). The redraw/setLine/delRange/prevWord/nextWord/addMark
//! buffer helpers + the wrap/completion/palette math live in input_util.zig
//! (imported here) to stay under the line goal. main.zig back-imports
//! Agent + saveSession; the alias here is `main_mod`, not `root`, since
//! readLine's own first parameter is named `root`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const ansi = @import("ansi.zig");
const style = &ansi.style;

const terminal = @import("term.zig");
const tty = terminal.tty;
const termCols = terminal.termCols;
const inputPending = terminal.inputPending;
const inputPendingTimed = terminal.inputPendingTimed;

const pickers = @import("pickers.zig");
const PickItem = pickers.PickItem;
const listPicker = pickers.listPicker;

const vision = @import("vision.zig");
const stageImagePath = vision.stageImagePath;
const grabClipboardImage = vision.grabClipboardImage;

const input_util = @import("input_util.zig");
const fillCompletions = input_util.fillCompletions;
const LineRender = input_util.LineRender;
const parseDsrCol = input_util.parseDsrCol;
const cleanDroppedPath = input_util.cleanDroppedPath;
const collectRepoFiles = input_util.collectRepoFiles;
const isImagePath = input_util.isImagePath;
const redraw = input_util.redraw;
const setLine = input_util.setLine;
const delRange = input_util.delRange;
const prevWord = input_util.prevWord;
const nextWord = input_util.nextWord;
const addMark = input_util.addMark;
const util = @import("util.zig");

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const session = @import("session.zig");
const Agent = agent_mod.Agent;
const saveSession = session.saveSession;

/// History + unsent-draft navigation for the line editor (#101). Mirrors the
/// GUI's promptHistoryNavigation.ts: stepping UP out of the fresh slot snapshots
/// the half-typed draft; stepping DOWN past the newest entry restores it instead
/// of clearing the line. `idx == history.len` is the fresh (editing) slot.
const HistoryNav = struct {
    idx: usize,
    draft: ?[]const u8 = null, // owned snapshot of the unsent line; freed by the caller

    fn init(history_len: usize) HistoryNav {
        return .{ .idx = history_len };
    }

    /// UP / older. `current` is the live buffer. Returns the text the buffer
    /// should show next, or null to leave it unchanged (already at the oldest).
    /// Leaving the fresh slot snapshots `current` as the draft to restore later.
    fn up(self: *HistoryNav, gpa: Allocator, history: []const []const u8, current: []const u8) ?[]const u8 {
        if (self.idx == 0) return null;
        if (self.idx == history.len) { // leaving the fresh slot: keep the draft
            if (self.draft) |d| gpa.free(d);
            self.draft = gpa.dupe(u8, current) catch null;
        }
        self.idx -= 1;
        return history[self.idx];
    }

    /// DOWN / newer. Returns the text to show next, or null to leave it
    /// unchanged (already at the fresh slot). Past the newest entry, restores the
    /// snapshotted draft (or "" when there was none) instead of clearing it.
    fn down(self: *HistoryNav, history: []const []const u8) ?[]const u8 {
        if (self.idx >= history.len) return null;
        self.idx += 1;
        if (self.idx == history.len) return self.draft orelse "";
        return history[self.idx];
    }
};

test "HistoryNav: up snapshots the draft, down past newest restores it (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{ "first", "second" };
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);

    // up from the fresh slot → newest entry, draft snapshotted
    try std.testing.expectEqualStrings("second", nav.up(gpa, &history, "draft in progress").?);
    // up again → older entry
    try std.testing.expectEqualStrings("first", nav.up(gpa, &history, "second").?);
    // up at the oldest → no change
    try std.testing.expect(nav.up(gpa, &history, "first") == null);
    // down → back to newest
    try std.testing.expectEqualStrings("second", nav.down(&history).?);
    // down past newest → the draft is restored, NOT cleared (the bug)
    try std.testing.expectEqualStrings("draft in progress", nav.down(&history).?);
    // down at the fresh slot → no change
    try std.testing.expect(nav.down(&history) == null);
}

test "HistoryNav: no draft → fresh slot returns empty, no leak (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{"only"};
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);
    try std.testing.expectEqualStrings("only", nav.up(gpa, &history, "").?);
    try std.testing.expectEqualStrings("", nav.down(&history).?); // empty draft → empty line, as today
}

/// Read one input line with a tiny raw-mode editor: ↑/↓ walk history,
/// Tab completes/cycles (models, providers, slash commands), backspace edits,
/// Ctrl-C cancels the line, Ctrl-D on an empty line is EOF. `buf` is reused
/// across calls and holds the result (valid until the next call). Returns the
/// line, or null on EOF. Falls back to a plain buffered line read when stdin
/// isn't a TTY (pipes, tests). DECSC/DECRC saves/restores the cursor to redraw.
pub fn readLine(
    root: *Agent,
    in: *Io.Reader,
    out: *Io.Writer,
    gpa: Allocator,
    history: *std.ArrayList([]const u8),
    buf: *std.ArrayList(u8),
) !?[]const u8 {
    const raw_state = tty.enterRaw(true) orelse return in.takeDelimiter('\n');
    defer tty.restore(raw_state);

    buf.clearRetainingCapacity();
    var cur: usize = 0; // cursor index within buf
    var nav: HistoryNav = .init(history.items.len); // history + unsent-draft nav (#101)
    defer if (nav.draft) |d| gpa.free(d);
    out.writeAll("\x1b[?2004h") catch {}; // enable bracketed paste (terminal wraps pastes in ESC[200~ … ESC[201~)
    defer out.writeAll("\x1b[?2004l") catch {};
    out.flush() catch {};

    // Where does input start? Ask the terminal (DSR 6) for the column right
    // after the prompt; the renderer treats those columns as a fixed prefix
    // and wraps the input across rows below it. Cursor moves in redraw are all
    // relative (never an absolute DECSC anchor), so a wrap-induced scroll
    // shifts the whole block together and never strands the prompt. Typed-
    // ahead text bytes that race the reply are replayed into the edit loop
    // below; a typed-ahead escape sequence inside that ~ms window is dropped.
    var prompt_col: usize = 1; // 1-based column where the buffer renders
    var rstate: LineRender = .{}; // rows used + cursor row of the last redraw
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var pend_i: usize = 0;
    out.writeAll("\x1b[6n") catch {};
    out.flush() catch {};
    dsr: {
        var esc: [16]u8 = undefined;
        var n: usize = 0;
        var in_esc = false;
        while (true) {
            // A local terminal answers DSR in a few milliseconds. Do not hold
            // every prompt for 500ms when a multiplexer drops/delays it: the
            // main loop's CSI 'R' arm adopts a late reply without losing layout.
            if (in.buffered().len == 0 and !inputPendingTimed(20)) break :dsr;
            const b = in.takeByte() catch break :dsr;
            if (!in_esc) {
                if (b == 0x1b) {
                    in_esc = true;
                    n = 0;
                    continue;
                }
                pending.append(gpa, b) catch {};
                if (pending.items.len > 64) break :dsr;
                continue;
            }
            if (n == 0 and b != '[') { // Alt-chord typed ahead: drop it
                in_esc = false;
                continue;
            }
            if (n < esc.len) {
                esc[n] = b;
                n += 1;
            }
            if (n >= 2 and b >= 0x40 and b <= 0x7e) { // CSI final byte
                if (b == 'R') { // the reply: ESC [ row ; col R
                    prompt_col = parseDsrCol(esc[0..n]) orelse 1;
                    break :dsr;
                }
                in_esc = false; // some other CSI typed ahead — drop it
                n = 0;
            }
        }
    }
    // Narrow terminal: when the prompt leaves too little room (the token-
    // stats prompt nearly fills a small window), give the input its own
    // row — what shells do — rather than wrapping in a sliver beside the
    // prompt.
    if (termCols() < prompt_col + 16) {
        out.writeAll("\r\n") catch {};
        out.flush() catch {};
        prompt_col = 1;
    }

    // Tab-completion cycle state.
    var comp_items: std.ArrayList([]const u8) = .empty;
    defer comp_items.deinit(gpa);
    var comp_base: usize = 0;
    var comp_idx: usize = 0;
    var comp_active = false;

    // Bracketed-paste collapse: a multi-line paste becomes a "[Pasted text #N
    // +L lines]" placeholder in the buffer; on submit each placeholder is
    // expanded back to its full text.
    const Paste = struct { ph: []const u8, body: []const u8 };
    var pastes: std.ArrayList(Paste) = .empty;
    defer {
        for (pastes.items) |p| {
            gpa.free(p.ph);
            gpa.free(p.body);
        }
        pastes.deinit(gpa);
    }

    // File paths inserted by the @ picker or a drag-and-drop (plus the
    // "[Image]" attachment marker): redraw renders these spans highlighted.
    // Editing inside a span just drops its highlight — the text stays.
    var marks: std.ArrayList([]const u8) = .empty;
    defer {
        for (marks.items) |m| gpa.free(m);
        marks.deinit(gpa);
    }

    while (true) {
        // Replay any text bytes that raced the DSR reply, then read live.
        const c = if (pend_i < pending.items.len) blk: {
            const b = pending.items[pend_i];
            pend_i += 1;
            break :blk b;
        } else blk: {
            // While the input contains `ultracode`, drift the ember shine
            // across the letters: poll for input with a slower 140ms timeout,
            // and on each idle tick advance the phase + redraw so the hue
            // glides at ~7fps rather than flickering.
            while (main_mod.use_color and std.ascii.indexOfIgnoreCase(buf.items, "ultracode") != null) {
                if (inputPendingTimed(140)) break; // keystroke ready — read it below
                input_util.g_shine_phase +%= 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            }
            break :blk in.takeByte() catch return null;
        };
        if (c != 0x09) comp_active = false; // any non-Tab key ends the cycle
        switch (c) {
            0x09 => { // Tab: complete, or cycle through matches on repeat
                if (!comp_active) {
                    comp_items.clearRetainingCapacity();
                    comp_base = fillCompletions(gpa, buf.items, &comp_items);
                    if (comp_items.items.len == 0) continue;
                    comp_idx = 0;
                    comp_active = true;
                } else if (comp_items.items.len > 0) {
                    comp_idx = (comp_idx + 1) % comp_items.items.len;
                } else continue;
                buf.shrinkRetainingCapacity(comp_base);
                buf.appendSlice(gpa, comp_items.items[comp_idx]) catch {};
                cur = buf.items.len;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            '\r', '\n' => {
                // The cursor may be mid-block; step past the last input row so
                // the submitted line and whatever prints next start cleanly.
                // The second newline leaves a blank-line gutter between the
                // submitted prompt and the model output, so it is easy to see
                // where the response starts.
                if (rstate.rows - 1 > rstate.crow) out.print("\x1b[{d}B", .{rstate.rows - 1 - rstate.crow}) catch {};
                out.writeAll("\r\n\r\n") catch {};
                out.flush() catch {};
                // Expand any pasted placeholders back to their full text.
                for (pastes.items) |p| {
                    if (std.mem.indexOf(u8, buf.items, p.ph) == null) continue;
                    const sz = std.mem.replacementSize(u8, buf.items, p.ph, p.body);
                    const tmp = gpa.alloc(u8, sz) catch break;
                    _ = std.mem.replace(u8, buf.items, p.ph, p.body, tmp);
                    buf.clearRetainingCapacity();
                    buf.appendSlice(gpa, tmp) catch {};
                    gpa.free(tmp);
                }
                break;
            },
            0x01 => { // Ctrl-A → start of line
                cur = 0;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x05 => { // Ctrl-E → end of line
                cur = buf.items.len;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x02 => if (cur > 0) { // Ctrl-B → left
                cur -= 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x06 => if (cur < buf.items.len) { // Ctrl-F → right
                cur += 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x17, 0x1f => { // Ctrl-W / Ctrl-_ → delete previous word
                const s = prevWord(buf.items, cur);
                if (s < cur) {
                    delRange(buf, s, cur);
                    cur = s;
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                }
            },
            0x15 => if (cur > 0) { // Ctrl-U → delete to start of line
                delRange(buf, 0, cur);
                cur = 0;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x0b => if (cur < buf.items.len) { // Ctrl-K → delete to end of line
                buf.shrinkRetainingCapacity(cur);
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x16 => { // Ctrl-V: attach a clipboard image (macOS) at the cursor
                var msg: ?[]const u8 = null;
                if (grabClipboardImage(root.io)) |p| switch (stageImagePath(root, p)) {
                    .ok => {
                        const marker = "[Image] ";
                        buf.insertSlice(gpa, cur, marker) catch {};
                        cur += marker.len;
                        addMark(gpa, &marks, "[Image]");
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    .no_vision => msg = "this model can't see images — /model to a vision one (claude-*, gpt-5*)",
                    .read_fail => msg = "couldn't read the clipboard image",
                } else msg = if (builtin.os.tag == .macos) "no image on the clipboard — copy an image first (this is Ctrl-V; ⌘V can't be captured)" else "clipboard image paste is macOS-only — use /image <path>";
                if (msg) |m| { // feedback below the input, then redraw the prompt+buffer fresh
                    if (rstate.rows - 1 > rstate.crow) out.print("\x1b[{d}B", .{rstate.rows - 1 - rstate.crow}) catch {};
                    out.print("\r\n{s}· {s}{s}", .{ style.dim, m, style.reset }) catch {};
                    root.prompt() catch {};
                    rstate = .{};
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                }
            },
            0x7f, 0x08 => if (cur > 0) { // backspace → delete char before cursor
                delRange(buf, cur - 1, cur);
                cur -= 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x03 => { // Ctrl-C: clear a non-empty line; on an empty line, quit
                if (buf.items.len == 0) {
                    out.writeAll("^C\n") catch {};
                    out.flush() catch {};
                    return null;
                }
                buf.clearRetainingCapacity();
                cur = 0;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
            0x1a => { // Ctrl-Z: save the session and quit (like a safe Ctrl-D)
                out.writeAll("^Z — saving & quit\n") catch {};
                out.flush() catch {};
                saveSession(root, root.arena, root.session_name) catch {};
                return null;
            },
            0x04 => { // Ctrl-D: EOF on empty line, else forward-delete
                if (buf.items.len == 0) {
                    out.writeAll("\n") catch {};
                    return null;
                }
                if (cur < buf.items.len) {
                    delRange(buf, cur, cur + 1);
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                }
            },
            0x1b => { // escape sequence: arrows, Alt/Option chords, CSI
                // A bare Esc (no byte follows) clears the line — without
                // this the chord read below would block and silently eat
                // the next keypress.
                if (in.buffered().len == 0 and !inputPending()) {
                    buf.clearRetainingCapacity();
                    cur = 0;
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    continue;
                }
                const b1 = in.takeByte() catch break;
                if (b1 == 0x7f or b1 == 0x08) { // Option/Alt+Delete → delete previous word
                    const s = prevWord(buf.items, cur);
                    if (s < cur) {
                        delRange(buf, s, cur);
                        cur = s;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    }
                    continue;
                }
                if (b1 == 'b') { // Alt-b → word left
                    cur = prevWord(buf.items, cur);
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    continue;
                }
                if (b1 == 'f') { // Alt-f → word right
                    cur = nextWord(buf.items, cur);
                    redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    continue;
                }
                if (b1 == 'd') { // Alt-d → delete next word
                    const e = nextWord(buf.items, cur);
                    if (e > cur) {
                        delRange(buf, cur, e);
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    }
                    continue;
                }
                if (b1 != '[') continue;
                // CSI: collect params until a final byte (0x40..0x7e).
                var params: [16]u8 = undefined;
                var pn: usize = 0;
                var final: u8 = 0;
                while (true) {
                    const x = in.takeByte() catch break;
                    if (x >= 0x40 and x <= 0x7e) {
                        final = x;
                        break;
                    }
                    if (pn < params.len) {
                        params[pn] = x;
                        pn += 1;
                    }
                }
                const ps = params[0..pn];
                const word_mod = std.mem.indexOfScalar(u8, ps, ';') != null; // 1;3 (alt) / 1;5 (ctrl)
                switch (final) {
                    'A' => if (nav.up(gpa, history.items, buf.items)) |text| { // up → history back; snapshots draft (#101)
                        setLine(gpa, buf, text);
                        cur = buf.items.len;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'B' => if (nav.down(history.items)) |text| { // down → history forward; restores draft past newest (#101)
                        setLine(gpa, buf, text);
                        cur = buf.items.len;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'C' => { // right (word-right with a modifier)
                        cur = if (word_mod) nextWord(buf.items, cur) else @min(cur + 1, buf.items.len);
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'D' => { // left (word-left with a modifier)
                        cur = if (word_mod) prevWord(buf.items, cur) else (if (cur > 0) cur - 1 else 0);
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'H' => {
                        cur = 0;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'F' => {
                        cur = buf.items.len;
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    'R' => { // late DSR cursor-position reply (slow or
                        // multiplexed terminal missed the 20ms startup
                        // window): adopt the real input column so the
                        // horizontal window stays exact instead of the
                        // column-1 fallback. Same narrow-terminal policy as
                        // startup: too little room after the prompt → the
                        // input moves to its own row.
                        if (std.mem.indexOfScalar(u8, ps, ';')) |semi| {
                            const col = std.fmt.parseInt(usize, ps[semi + 1 ..], 10) catch 0;
                            if (col > 0) {
                                if (termCols() < col + 16) {
                                    out.writeAll("\r\n") catch {};
                                    prompt_col = 1;
                                } else prompt_col = col;
                            }
                        }
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                    },
                    '~' => {
                        if (std.mem.eql(u8, ps, "200")) { // bracketed paste start
                            var blob: std.ArrayList(u8) = .empty;
                            defer blob.deinit(gpa);
                            while (true) { // read until the ESC[201~ end marker
                                const x = in.takeByte() catch break;
                                blob.append(gpa, x) catch break;
                                if (std.mem.endsWith(u8, blob.items, "\x1b[201~")) {
                                    blob.shrinkRetainingCapacity(blob.items.len - 6);
                                    break;
                                }
                            }
                            var pasted = blob.items;
                            if (pasted.len > 0 and pasted[pasted.len - 1] == '\n') pasted = pasted[0 .. pasted.len - 1];
                            const lines = std.mem.count(u8, pasted, "\n") + 1;
                            const dropped = cleanDroppedPath(gpa, root.home, pasted);
                            defer if (dropped) |dp| gpa.free(dp);
                            const drop_exists = if (dropped) |dp| blk: {
                                Io.Dir.cwd().access(root.io, dp, .{}) catch break :blk false;
                                break :blk true;
                            } else false;
                            if (drop_exists) {
                                // Drag-and-dropped file: terminals paste the path
                                // escaped/quoted with a trailing space. An image on a
                                // vision model is staged as an attachment (like /image
                                // and Ctrl-V); anything else inlines the cleaned full
                                // path however long it is.
                                var staged = false;
                                var dmsg: ?[]const u8 = null;
                                if (isImagePath(dropped.?)) switch (stageImagePath(root, dropped.?)) {
                                    .ok => staged = true,
                                    .no_vision => dmsg = "this model can't see images — ✓ in /models' vision column shows ones that can; path inlined instead",
                                    .read_fail => dmsg = "couldn't read that image (missing or >5MB) — path inlined instead",
                                };
                                if (staged) {
                                    const marker = "[Image] ";
                                    buf.insertSlice(gpa, cur, marker) catch {};
                                    cur += marker.len;
                                    addMark(gpa, &marks, "[Image]");
                                } else {
                                    buf.insertSlice(gpa, cur, dropped.?) catch {};
                                    cur += dropped.?.len;
                                    addMark(gpa, &marks, dropped.?);
                                }
                                if (dmsg) |m| { // feedback below the input, then redraw fresh (below)
                                    if (rstate.rows - 1 > rstate.crow) out.print("\x1b[{d}B", .{rstate.rows - 1 - rstate.crow}) catch {};
                                    out.print("\r\n{s}· {s}{s}", .{ style.dim, m, style.reset }) catch {};
                                    root.prompt() catch {};
                                    rstate = .{};
                                }
                            } else if (lines == 1 and pasted.len <= 80) {
                                buf.insertSlice(gpa, cur, pasted) catch {}; // short single-line paste: inline
                                cur += pasted.len;
                            } else { // multi-line/long: collapse to a placeholder, expand on submit
                                const ph = std.fmt.allocPrint(gpa, "[Pasted text #{d} +{d} lines]", .{ pastes.items.len + 1, lines }) catch "";
                                const body = gpa.dupe(u8, pasted) catch "";
                                if (ph.len > 0 and body.len > 0) {
                                    pastes.append(gpa, .{ .ph = ph, .body = body }) catch {};
                                    buf.insertSlice(gpa, cur, ph) catch {};
                                    cur += ph.len;
                                }
                            }
                            redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        } else if (std.mem.eql(u8, ps, "3")) { // forward delete
                            if (cur < buf.items.len) {
                                delRange(buf, cur, cur + 1);
                                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                            }
                        } else if (std.mem.eql(u8, ps, "1") or std.mem.eql(u8, ps, "7")) {
                            cur = 0;
                            redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        } else if (std.mem.eql(u8, ps, "4") or std.mem.eql(u8, ps, "8")) {
                            cur = buf.items.len;
                            redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        }
                    },
                    else => {},
                }
            },
            else => if (c >= 0x20) { // printable: insert at cursor
                // '@' at a word boundary opens a fuzzy file picker over the
                // repo (cwd walk, dot/build dirs skipped); the picked path is
                // inserted at the cursor. A literal '@' still types fine —
                // cancel the picker (esc/ctrl-c), or type it mid-word.
                if (c == '@' and (cur == 0 or buf.items[cur - 1] == ' ')) {
                    var files: std.ArrayList([]const u8) = .empty;
                    defer {
                        for (files.items) |f| gpa.free(f);
                        files.deinit(gpa);
                    }
                    collectRepoFiles(root.io, gpa, &files);
                    if (files.items.len > 0) {
                        var items: std.ArrayList(PickItem) = .empty;
                        defer items.deinit(gpa);
                        for (files.items) |f| items.append(gpa, .{ .name = f }) catch {};
                        const picked = listPicker(root, root.arena, out, "File ›", items.items);
                        // The alt-screen picker (DECSET 1049) restores the main
                        // screen and cursor on exit, so the input block and
                        // rstate still match — just redraw over them below.
                        if (picked) |idx| {
                            buf.insertSlice(gpa, cur, files.items[idx]) catch {};
                            cur += files.items[idx].len;
                            addMark(gpa, &marks, files.items[idx]);
                        }
                        redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
                        continue;
                    }
                }
                buf.insert(gpa, cur, c) catch {};
                cur += 1;
                redraw(out, buf.items, cur, marks.items, &rstate, prompt_col);
            },
        }
    }

    const trimmed = std.mem.trim(u8, buf.items, " \t\r");
    if (trimmed.len > 0 and util.rememberInput(buf.items) and (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], buf.items))) {
        const dup = gpa.dupe(u8, buf.items) catch return buf.items;
        history.append(gpa, dup) catch {};
    }
    return buf.items;
}
