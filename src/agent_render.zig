//! Incremental streaming markdown renderer: the byte-at-a-time classifier
//! (mdByte/mdTryClassify/...) that decides a line's kind (prose, header,
//! fence, table row, rule) as early as possible and streams styled output
//! immediately, plus the non-streaming line renderer (renderMdLine) used
//! for whole buffered lines (table rows, compaction summaries). Split out
//! of the Agent struct (#123, 600-line goal); see agent_table.zig for the
//! table-specific piece this plugs into.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const terminal = @import("term.zig");
const termCols = terminal.termCols;

const tick_gate = @import("tick_gate.zig"); // #tui-tick: subagent ticks land at line boundaries

// isTableSeparator lives in agent_table.zig; reached through the Agent
// struct's member alias.
const isTableSeparator = Agent.isTableSeparator;

/// Incremental streaming markdown: every delta byte either prints
/// immediately or is held only as long as classification demands. Each
/// line starts in .classify (md_buf accumulates the prefix); the moment
/// the prefix proves what the line is, the buffered bytes are emitted
/// with their styling and subsequent bytes stream straight through —
/// prose and bullets/numbered items word-by-word with eager **bold** /
/// `code` span styling, headers and fenced code styled-then-raw.
/// Only genuinely whole-line constructs stay held to line end: fence
/// toggles, tables, horizontal rules (and any still-ambiguous prefix).
/// Well-formed markdown renders identically to renderMdLine; a span left
/// unclosed at line end differs cosmetically (styled text, markers
/// dropped) from renderMdLine's literal-marker fallback.
pub fn streamMarkdown(self: *Agent, text: []const u8) void {
    const w = self.out orelse return;
    for (text) |b| self.mdByte(w, b);
    w.flush() catch {};
    // Only now, with the delta actually on the terminal, may a parallel
    // child's activity line through — and only if this delta ended a row
    // (#tui-tick). Subagents render no markdown, so this is the root's stream.
    if (!self.sub and !main_mod.json_mode) _ = tick_gate.setLineStart(atLineStart(self));
}

/// True when the renderer has nothing painted on the current row: it committed
/// its last line with a newline and holds no prefix. A still-held/classifying
/// line has printed nothing yet but counts as mid-line anyway — a tick delayed
/// by one line is harmless, a tick inside a word is the bug.
pub fn atLineStart(self: *const Agent) bool {
    return self.md_kind == .classify and self.md_buf.items.len == 0 and self.md_word.items.len == 0;
}

pub const MdKind = enum { classify, hold, prose, header, fenced };

pub const MdSpan = enum { normal, star, bold, bold_star, code };

const TaskItem = struct { checked: bool, text: []const u8 };

fn taskItem(body: []const u8) ?TaskItem {
    if (body.len < 6 or (body[0] != '-' and body[0] != '*' and body[0] != '+') or body[1] != ' ' or body[2] != '[' or body[4] != ']' or body[5] != ' ') return null;
    if (body[3] != ' ' and body[3] != 'x' and body[3] != 'X') return null;
    return .{ .checked = body[3] != ' ', .text = body[6..] };
}

fn headingColor(level: usize) []const u8 {
    return if (level <= 2) style.accent else style.yellow;
}

fn renderHeading(w: *Io.Writer, level: usize, text: []const u8) void {
    const marker: []const u8 = if (level <= 2) "◆" else "▸";
    w.print("{s}{s}{s} ", .{ style.bold, headingColor(level), marker }) catch {};
    renderInline(w, text);
    w.writeAll(style.reset) catch {};
}

fn mdStartItem(self: *Agent, w: *Io.Writer, held: []const u8, lead: usize, prefix_len: usize, marker: []const u8, color: []const u8) void {
    self.md_kind = .prose;
    self.md_span = .normal;
    self.md_col = lead + 2;
    self.md_indent = lead + 2;
    w.writeAll(held[0..lead]) catch {};
    w.print("{s}{s}{s} ", .{ color, marker, style.reset }) catch {};
    const rest = held[lead + prefix_len ..];
    var tmp: [8]u8 = undefined;
    const n = @min(rest.len, tmp.len);
    @memcpy(tmp[0..n], rest[0..n]);
    self.md_buf.clearRetainingCapacity();
    for (tmp[0..n]) |rb| self.mdSpanByte(w, rb);
}

pub fn mdByte(self: *Agent, w: *Io.Writer, b: u8) void {
    if (b == '\n') {
        // A swallowed line (table row joining the buffer) keeps its
        // newline too — the table renders with its own line breaks.
        if (self.mdFinishLine(w)) w.writeByte('\n') catch {};
        return;
    }
    switch (self.md_kind) {
        .classify => {
            self.md_buf.append(self.gpa, b) catch {};
            self.mdTryClassify(w);
        },
        .hold => self.md_buf.append(self.gpa, b) catch {},
        .prose => self.mdSpanByte(w, b),
        .header, .fenced => w.writeByte(b) catch {},
    }
}

/// Look at the held line prefix and commit to a line kind as soon as the
/// bytes allow. Staying silent (returning with .classify) means "not
/// decidable yet" — at most a few bytes for every construct.
pub fn mdTryClassify(self: *Agent, w: *Io.Writer) void {
    const held = self.md_buf.items;
    var lead: usize = 0;
    while (lead < held.len and held[lead] == ' ') lead += 1;
    const body = held[lead..];
    if (body.len == 0) return; // only indentation so far

    // A buffered table ends at the first line that isn't another row —
    // render it before this line emits anything.
    if (self.md_table.items.len > 0 and body[0] != '|') self.flushTable(w);

    if (self.md_fence) {
        // Inside a fence the only special line is the ``` closer.
        const bt = countPrefix(body, '`');
        if (bt == body.len) {
            if (bt >= 3) self.md_kind = .hold; // closer: whole-line render
            return; // 1-2 backticks: could still become the closer
        }
        self.md_kind = .fenced; // body text: dim it and stream
        w.writeAll(style.dim) catch {};
        w.writeAll(held) catch {};
        self.md_buf.clearRetainingCapacity();
        return;
    }
    switch (body[0]) {
        '`' => {
            const bt = countPrefix(body, '`');
            if (bt >= 3) {
                self.md_kind = .hold; // fence opener
            } else if (bt < body.len) {
                self.mdStartProse(w); // inline code span
            } // else: 1-2 leading backticks, undecided
        },
        '#' => {
            const hn = countPrefix(body, '#');
            if (hn == body.len) return; // could still grow
            if (hn > 6 or body[hn] != ' ') {
                self.mdStartProse(w);
                return;
            }
            // Hold headings to line end so inline bold/code renders too.
            var ns = hn + 1;
            while (ns < body.len and body[ns] == ' ') ns += 1;
            if (ns == body.len) return;
            self.md_kind = .hold;
        },
        '|' => self.md_kind = .hold, // table row: cells need the whole line
        '-', '_', '*', '+' => {
            const run = countPrefix(body, body[0]);
            if (body[0] != '+' and run == body.len) return; // possible rule
            if ((body[0] == '-' or body[0] == '*' or body[0] == '+') and run == 1 and body.len >= 2 and body[1] == ' ') {
                if (body.len == 2) return;
                if (body[2] == '[' and body.len < 6) return;
                if (taskItem(body)) |task| {
                    mdStartItem(self, w, held, lead, 6, if (task.checked) "☑" else "☐", if (task.checked) style.green else style.yellow);
                } else {
                    mdStartItem(self, w, held, lead, 2, if (lead == 0) "•" else "◦", style.accent);
                }
                return;
            }
            if (body[0] == '+' and body.len == 1) return; // "+ " bullet still possible
            self.mdStartProse(w);
        },
        '0'...'9' => {
            var d: usize = 0;
            while (d < body.len and body[d] >= '0' and body[d] <= '9') d += 1;
            if (d == body.len) return; // all digits: could become "12. "
            if (body[d] == '.' or body[d] == ')') {
                if (d + 1 == body.len) return; // "12." — needs one more byte
                if (body[d + 1] == ' ') { // numbered item
                    self.md_kind = .prose;
                    self.md_span = .normal;
                    self.md_col = lead + d + 2; // "12. " — align under the text
                    self.md_indent = lead + d + 2;
                    w.writeAll(held[0..lead]) catch {};
                    w.print("{s}{s}{c}{s} ", .{ style.accent, body[0..d], body[d], style.reset }) catch {};
                    const rest = body[d + 2 ..];
                    var tmp: [8]u8 = undefined;
                    const n = @min(rest.len, tmp.len);
                    @memcpy(tmp[0..n], rest[0..n]);
                    self.md_buf.clearRetainingCapacity();
                    for (tmp[0..n]) |rb| self.mdSpanByte(w, rb);
                    return;
                }
            }
            self.mdStartProse(w);
        },
        '>' => {
            if (body.len == 1) return;
            if (body[1] == ' ') {
                mdStartItem(self, w, held, lead, 2, "│", style.dim);
                return;
            }
            self.mdStartProse(w);
        },
        else => self.mdStartProse(w),
    }
}

/// Commit to plain prose: replay the held prefix through the inline-span
/// machine, then stream subsequent bytes directly.
pub fn mdStartProse(self: *Agent, w: *Io.Writer) void {
    self.md_kind = .prose;
    self.md_span = .normal;
    var lead: usize = 0;
    while (lead < self.md_buf.items.len and self.md_buf.items[lead] == ' ') lead += 1;
    self.md_indent = lead; // wrapped lines keep the line's indentation
    for (self.md_buf.items) |b| self.mdSpanByte(w, b);
    self.md_buf.clearRetainingCapacity();
}

/// Streaming counterpart of renderInline: a left-to-right toggle machine
/// for **bold** and `code` spans that styles eagerly — the opener turns
/// styling on as soon as it's seen instead of waiting for the closer.
/// Literal bytes route through mdWrapByte (terminal-width word wrap);
/// style sequences through mdStyle (zero-width, ordered with the word).
pub fn mdSpanByte(self: *Agent, w: *Io.Writer, b: u8) void {
    switch (self.md_span) {
        .normal => switch (b) {
            '*' => self.md_span = .star,
            '`' => {
                self.mdStyle(w, style.yellow);
                self.md_span = .code;
            },
            else => self.mdWrapByte(w, b),
        },
        .star => if (b == '*') {
            self.mdStyle(w, style.bold);
            self.md_span = .bold;
        } else {
            self.mdWrapByte(w, '*'); // lone star is literal
            self.md_span = .normal;
            self.mdSpanByte(w, b);
        },
        .bold => switch (b) {
            '*' => self.md_span = .bold_star,
            else => self.mdWrapByte(w, b),
        },
        .bold_star => if (b == '*') {
            self.mdStyle(w, style.reset);
            self.md_span = .normal;
        } else {
            self.mdWrapByte(w, '*');
            self.md_span = .bold;
            self.mdSpanByte(w, b);
        },
        .code => if (b == '`') {
            self.mdStyle(w, style.reset);
            self.md_span = .normal;
        } else self.mdWrapByte(w, b),
    }
}

/// Terminal-width word wrap for streamed prose. Literal bytes buffer
/// into the current word; a space flushes it — and a word that would
/// cross the terminal edge breaks the line first and continues under
/// the hanging indent (set by the bullet/numbered/prose classifiers),
/// instead of hard-wrapping at column 0 mid-word.
pub fn mdWrapByte(self: *Agent, w: *Io.Writer, b: u8) void {
    if (b == ' ') {
        self.mdFlushWord(w);
        if (self.md_col < self.mdWidth()) {
            w.writeByte(' ') catch {};
            self.md_col += 1;
        } else if (self.md_col > self.md_indent) {
            self.mdWrapBreak(w); // line full: break instead of the space
        } // already at a fresh indent: swallow the space
        return;
    }
    self.md_word.append(self.gpa, b) catch {
        w.writeByte(b) catch {}; // can't buffer: degrade to direct write
        return;
    };
    if ((b & 0xC0) != 0x80) self.md_word_vis += 1; // UTF-8 leads only
}

/// Style sequences are zero-width but must stay ordered with the word
/// they're inside of — buffer them with a pending word, else pass through.
pub fn mdStyle(self: *Agent, w: *Io.Writer, s: []const u8) void {
    if (self.md_word.items.len > 0) {
        self.md_word.appendSlice(self.gpa, s) catch {};
    } else w.writeAll(s) catch {};
}

pub fn mdFlushWord(self: *Agent, w: *Io.Writer) void {
    if (self.md_word.items.len == 0) return;
    const vis = self.md_word_vis;
    const width = self.mdWidth();
    // Break before a word that would cross the edge — unless the line is
    // already fresh or the word can't fit any line (URLs: let the
    // terminal wrap it rather than shred it).
    if (self.md_col + vis > width and self.md_col > self.md_indent and self.md_indent + vis <= width)
        self.mdWrapBreak(w);
    w.writeAll(self.md_word.items) catch {};
    self.md_col += vis;
    self.md_word.clearRetainingCapacity();
    self.md_word_vis = 0;
}

pub fn mdWrapBreak(self: *Agent, w: *Io.Writer) void {
    w.writeByte('\n') catch {};
    for (0..self.md_indent) |_| w.writeByte(' ') catch {};
    self.md_col = self.md_indent;
}

pub fn mdWidth(self: *Agent) usize {
    if (self.md_width == 0) self.md_width = termCols();
    return self.md_width;
}

/// Settle the span machine at line end: pending markers print literally,
/// open spans close their styling.
pub fn mdSpanEnd(self: *Agent, w: *Io.Writer) void {
    self.mdFlushWord(w);
    switch (self.md_span) {
        .normal => {},
        .star => w.writeByte('*') catch {},
        .bold, .code => w.writeAll(style.reset) catch {},
        .bold_star => {
            w.writeByte('*') catch {};
            w.writeAll(style.reset) catch {};
        },
    }
    self.md_span = .normal;
}

/// End of line (newline or stream end): render anything still held,
/// settle styling, and reset the per-line state. Returns false when the
/// line was a table row swallowed into md_table — the caller then skips
/// the newline; the table prints its own when it flushes.
pub fn mdFinishLine(self: *Agent, w: *Io.Writer) bool {
    switch (self.md_kind) {
        // Still held: a whole-line construct or a prefix too short to
        // classify — renderMdLine does exactly the right thing (and
        // toggles md_fence for fence lines).
        .classify, .hold => {
            const line = self.md_buf.items;
            var lead: usize = 0;
            while (lead < line.len and line[lead] == ' ') lead += 1;
            if (!self.md_fence and lead < line.len and line[lead] == '|') {
                // Table row: buffer it — columns can only align once the
                // whole table is known.
                if (self.gpa.dupe(u8, line[lead..])) |dup| {
                    self.md_table.append(self.gpa, dup) catch self.gpa.free(dup);
                    self.md_buf.clearRetainingCapacity();
                    self.md_kind = .classify;
                    self.md_span = .normal;
                    return false;
                } else |_| {}
            }
            if (self.md_table.items.len > 0) self.flushTable(w);
            self.renderMdLine(w, line);
        },
        .prose => self.mdSpanEnd(w),
        .header, .fenced => w.writeAll(style.reset) catch {},
    }
    self.md_buf.clearRetainingCapacity();
    self.md_kind = .classify;
    self.md_span = .normal;
    self.md_col = 0;
    self.md_indent = 0;
    self.md_width = 0; // re-read the terminal width next line (resizes)
    return true;
}

pub fn countPrefix(s: []const u8, c: u8) usize {
    var i: usize = 0;
    while (i < s.len and s[i] == c) i += 1;
    return i;
}

/// Columns a cell occupies once rendered: matched **bold**/`code` markers
/// drop, and multi-byte UTF-8 sequences count as one column (wide CJK
/// glyphs are approximated as one).
pub fn inlineVisibleLen(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
                n += codepointCount(s[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }
        if (s[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                n += codepointCount(s[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        }
        if ((s[i] & 0xC0) != 0x80) n += 1;
        i += 1;
    }
    return n;
}

pub fn codepointCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
    }
    return n;
}

/// Flush the trailing partial line at stream end (no forced newline — the
/// caller adds the separating newline), and reset fence state.
pub fn flushStreamTail(self: *Agent) void {
    const w = self.out orelse return;
    _ = self.mdFinishLine(w); // may swallow a final table row…
    if (self.md_table.items.len > 0) self.flushTable(w); // …then render it
    w.flush() catch {};
    self.md_fence = false;
}

/// Render one markdown line to ANSI (portable SGR only — bold/color, no
/// italic, so iTerm/Ghostty/Terminal/Windows-Terminal all agree): code
/// fences + fenced bodies dimmed, ATX headers bold-coral, `-`/`*`/`+`
/// bullets → coral •, and inline `**bold**` / `` `code` `` spans.
pub fn renderMdLine(self: *Agent, w: *Io.Writer, line: []const u8) void {
    var lead: usize = 0;
    while (lead < line.len and line[lead] == ' ') lead += 1;
    const body = line[lead..];
    if (std.mem.startsWith(u8, body, "```")) {
        self.md_fence = !self.md_fence;
        // Fence lines render as a dim rule — "── zig ────…" opening with
        // the language label when given, plain "────…" otherwise —
        // instead of raw backticks. Body lines stay unprefixed so code
        // copies cleanly out of the terminal.
        const lang = std.mem.trim(u8, body[3..], " `");
        w.writeAll(style.dim) catch {};
        var used: usize = 0;
        if (self.md_fence and lang.len > 0) {
            w.print("── {s} ", .{lang}) catch {};
            used = 4 + codepointCount(lang); // "── " + label + " "
        }
        while (used < 40) : (used += 1) w.writeAll("─") catch {};
        w.writeAll(style.reset) catch {};
        return;
    }
    if (self.md_fence) {
        w.print("{s}{s}{s}", .{ style.dim, line, style.reset }) catch {};
        return;
    }
    // ATX header: 1-6 '#' then a space.
    var h: usize = 0;
    while (h < body.len and body[h] == '#') h += 1;
    if (h >= 1 and h <= 6 and h < body.len and body[h] == ' ') {
        const head = std.mem.trim(u8, body[h + 1 ..], " ");
        renderHeading(w, h, head);
        return;
    }
    // Horizontal rule: a line of only -, *, or _ (3+).
    if (body.len >= 3 and isRule(body)) {
        w.print("{s}────────────{s}", .{ style.dim, style.reset }) catch {};
        return;
    }
    // Table row (GFM): starts with '|'. Separator row → dim rule; data row
    // → cells joined by a dim │, each rendered inline.
    if (body.len > 0 and body[0] == '|') {
        if (isTableSeparator(body)) {
            w.print("{s}────────────{s}", .{ style.dim, style.reset }) catch {};
            return;
        }
        var cells = std.mem.splitScalar(u8, body, '|');
        var first = true;
        while (cells.next()) |cell| {
            const c = std.mem.trim(u8, cell, " ");
            if (c.len == 0) continue;
            if (!first) w.print("{s} │ {s}", .{ style.dim, style.reset }) catch {};
            first = false;
            renderInline(w, c);
        }
        return;
    }
    if (taskItem(body)) |task| {
        w.writeAll(line[0..lead]) catch {};
        w.print("{s}{s}{s} ", .{ if (task.checked) style.green else style.yellow, if (task.checked) "☑" else "☐", style.reset }) catch {};
        renderInline(w, task.text);
        return;
    }
    if (std.mem.startsWith(u8, body, "> ")) {
        w.writeAll(line[0..lead]) catch {};
        w.print("{s}│{s} ", .{ style.dim, style.reset }) catch {};
        renderInline(w, body[2..]);
        return;
    }
    // Bullet list item.
    if (std.mem.startsWith(u8, body, "- ") or std.mem.startsWith(u8, body, "* ") or std.mem.startsWith(u8, body, "+ ")) {
        w.writeAll(line[0..lead]) catch {};
        w.print("{s}{s}{s} ", .{ style.accent, if (lead == 0) "•" else "◦", style.reset }) catch {};
        renderInline(w, body[2..]);
        return;
    }
    // Numbered list: digits then '.' or ')' then a space.
    var d: usize = 0;
    while (d < body.len and body[d] >= '0' and body[d] <= '9') d += 1;
    if (d >= 1 and d + 1 < body.len and (body[d] == '.' or body[d] == ')') and body[d + 1] == ' ') {
        w.writeAll(line[0..lead]) catch {};
        w.print("{s}{s}{c}{s} ", .{ style.accent, body[0..d], body[d], style.reset }) catch {};
        renderInline(w, body[d + 2 ..]);
        return;
    }
    renderInline(w, line);
}

/// True if every char is one of '-', '*', '_' (markdown thematic break).
pub fn isRule(body: []const u8) bool {
    const c0 = body[0];
    if (c0 != '-' and c0 != '*' and c0 != '_') return false;
    for (body) |c| if (c != c0) return false;
    return true;
}

/// Emit a line with inline `**bold**` and `` `code` `` spans styled; the
/// markers themselves are dropped. Unmatched markers print literally.
pub fn renderInline(w: *Io.Writer, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
                w.print("{s}{s}{s}", .{ style.bold, s[i + 2 .. end], style.reset }) catch {};
                i = end + 2;
                continue;
            }
        }
        if (s[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                w.print("{s}{s}{s}", .{ style.yellow, s[i + 1 .. end], style.reset }) catch {};
                i = end + 1;
                continue;
            }
        }
        w.writeByte(s[i]) catch {};
        i += 1;
    }
}

test "codepointCount: counts UTF-8 codepoints, not bytes" {
    try std.testing.expectEqual(@as(usize, 5), codepointCount("hello"));
    try std.testing.expectEqual(@as(usize, 0), codepointCount(""));
    try std.testing.expectEqual(@as(usize, 1), codepointCount("é")); // 2 bytes, 1 codepoint
    try std.testing.expectEqual(@as(usize, 3), codepointCount("a→b")); // arrow is 3 bytes
}

test "inlineVisibleLen: matched **bold**/`code` markers drop from the visible width" {
    try std.testing.expectEqual(@as(usize, 5), inlineVisibleLen("hello"));
    try std.testing.expectEqual(@as(usize, 4), inlineVisibleLen("**bold**"));
    try std.testing.expectEqual(@as(usize, 4), inlineVisibleLen("`code`"));
    try std.testing.expectEqual(@as(usize, 1), inlineVisibleLen("é")); // wide glyph counts as one column
    try std.testing.expectEqual(@as(usize, 2), inlineVisibleLen("**")); // unmatched marker is literal
}
