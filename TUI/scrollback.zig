//! Conversation scrollback. ANSI only. render() is the uncached full layout
//! that layout_cache.zig memoizes per block and that its tests hold it to.
//! Consecutive tool rows collapse into a Grok-style summary until expanded.

const std = @import("std");

const app = @import("app.zig");
const diff_mod = @import("diff.zig");
const foldhdr = @import("foldhdr.zig");
const glyphs = @import("glyphs.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// Soft pulse so a live turn reads as motion, not a lone spinner glyph.
pub fn render(self: *const Model, a: std.mem.Allocator, width: usize, now_ms: u64) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    var first = true;
    while (i < self.history.items.len) {
        const e = self.history.items[i];
        if (e.kind == .tool) {
            const run = self.toolRun(i);
            if (!first) try out.append('\n');
            first = false;
            try out.appendSlice(try runVisual(self, a, run.start, run.end, width, now_ms));
            i = run.end;
            continue;
        }
        if (!first) try out.append('\n');
        first = false;
        const selected = self.focus == .scrollback and i == self.selected;
        try out.appendSlice(try row(self, a, userNo(self, i), e, width, now_ms, selected));
        i += 1;
    }
    if (self.pending) |job| {
        if (!self.cancel_requested) {
            if (job.stream.snapshot(a)) |live| {
                if (!first) try out.append('\n');
                first = false;
                try out.appendSlice(try theme_mod.paint(a, self.theme().muted, try tail(a, strip(a, live), width, 4)));
            }
            if (self.steer_queue.items.len > 0) {
                if (!first) try out.append('\n');
                try out.appendSlice(try theme_mod.paint(a, self.theme().muted, try std.fmt.allocPrint(a, "  ↳ {d} queued · empty Enter sends now", .{self.steer_queue.items.len})));
            }
        }
    }
    return out.items;
}

/// Mid-relative visual row → history index (collapsed group maps to its start).
pub fn indexAtVisual(self: *const Model, visual_row: usize, width: usize) ?usize {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var v: usize = 0;
    var i: usize = 0;
    while (i < self.history.items.len) {
        if (self.history.items[i].kind == .tool) {
            const run = self.toolRun(i);
            const lines = lineCount(runVisual(self, a, run.start, run.end, width, self.now_ms) catch "");
            if (visual_row >= v and visual_row < v + lines) return run.start;
            v += lines;
            i = run.end;
            continue;
        }
        const s = row(self, a, userNo(self, i), self.history.items[i], width, self.now_ms, false) catch "";
        const lines = lineCount(s);
        if (visual_row >= v and visual_row < v + lines) return i;
        v += lines;
        i += 1;
    }
    return null;
}

/// Total visual rows of the transcript at `width` (mirrors render()).
pub fn totalVisualLines(self: *const Model, width: usize) usize {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const text = render(self, arena.allocator(), width, self.now_ms) catch return 0;
    if (text.len == 0) return 0; // render.zig pops the empty tail; agree with it
    return lineCount(text);
}

/// First visual row of entry `idx` (a collapsed group maps to its start).
pub fn visualOfIndex(self: *const Model, idx: usize, width: usize) ?usize {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var v: usize = 0;
    var i: usize = 0;
    while (i < self.history.items.len) {
        if (self.history.items[i].kind == .tool) {
            const run = self.toolRun(i);
            if (idx >= run.start and idx < run.end) return v;
            v += lineCount(runVisual(self, a, run.start, run.end, width, self.now_ms) catch "");
            i = run.end;
            continue;
        }
        if (i == idx) return v;
        v += lineCount(row(self, a, userNo(self, i), self.history.items[i], width, self.now_ms, false) catch "");
        i += 1;
    }
    return null;
}

/// The last user prompt whose first visual row sits strictly above
/// `top_line` — the grok sticky-header candidate. Same row math as
/// visualOfIndex so the pin agrees with what the viewport actually shows.
pub fn stickyUserAbove(self: *const Model, top_line: usize, width: usize) ?[]const u8 {
    if (top_line == 0) return null;
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var best: ?[]const u8 = null;
    var v: usize = 0;
    var i: usize = 0;
    while (i < self.history.items.len and v < top_line) {
        const e = self.history.items[i];
        if (e.kind == .tool) {
            const run = self.toolRun(i);
            v += lineCount(runVisual(self, a, run.start, run.end, width, self.now_ms) catch "");
            i = run.end;
            continue;
        }
        if (e.kind == .user and v < top_line) best = e.text;
        v += lineCount(row(self, a, userNo(self, i), e, width, self.now_ms, false) catch "");
        i += 1;
    }
    return best;
}

pub fn lineCount(s: []const u8) usize {
    if (s.len == 0) return 1;
    return std.mem.count(u8, s, "\n") + 1;
}

/// Is this a search-shaped tool? Answered from the tool NAME (#551). It used
/// to be answered from the whole rendered line, so `bash` running a command
/// that merely mentioned "find" counted as a search.
/// One whole tool run as the transcript shows it: grok's disclosure header,
/// and — when the run is open — the cards under it, hanging off a light
/// gutter. Every reader of the transcript's row math goes through here, so
/// the header can never be counted by one and missed by another.
pub fn runVisual(self: *const Model, a: std.mem.Allocator, start: usize, end: usize, width: usize, now_ms: u64) ![]const u8 {
    if (start >= end) return "";
    const open = !self.history.items[start].folded;
    const in_run = self.focus == .scrollback and self.selected >= start and self.selected < end;
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(try header(self, a, start, end, width, now_ms, in_run));
    if (!open) return out.items;
    var t = start;
    while (t < end) {
        try out.append('\n');
        const one = self.focus == .scrollback and t == self.selected;
        const card = try toolVisual(self, a, t, end, width -| foldhdr.gutter_cols, now_ms, one);
        try out.appendSlice(try indent(a, self.theme(), card));
        t = nextTool(self, t, end);
    }
    return out.items;
}

/// The run's own row: `[selection mark][chevron] [verb phrase]`. Always ONE
/// line — a menu entry's rule, and what keeps the click math a straight
/// screen-row → run mapping.
pub fn header(self: *const Model, a: std.mem.Allocator, start: usize, end: usize, width: usize, now_ms: u64, selected: bool) ![]const u8 {
    const th = self.theme();
    const r = foldhdr.scan(self, start, end);
    if (r.calls == 0) return "";
    const open = !self.history.items[start].folded;
    const sel = glyphs.frame(&glyphs.row_mark, @intFromBool(!selected));
    // No live bar here: liveness belongs to the pending row alone. A bar on
    // every header made the whole transcript pulse and shift while thinking —
    // the settle flash below is a single bounded change, not a tick.
    const plain = theme_mod.takeCols(
        try std.fmt.allocPrint(a, "{s}{s} {s}", .{ sel, foldhdr.chevron(open), try foldhdr.phrase(a, r) }),
        width,
    );
    const fg = if (selected or foldhdr.flashing(r, now_ms)) th.accent else th.muted;
    if (!foldhdr.flashing(r, now_ms)) return theme_mod.paint(a, fg, plain);
    // The settle tint is a FIELD, not a ribbon: padded out to the full width
    // and closed back onto the canvas bg, so the row under it inherits
    // nothing (the same rule diff.zig's bands follow).
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(foldhdr.flashBg(th));
    try out.appendSlice(fg);
    try out.appendSlice(plain);
    var pad = width -| theme_mod.visibleLen(plain);
    while (pad > 0) : (pad -= 1) try out.append(' ');
    try out.appendSlice(th.bg);
    try out.appendSlice(theme_mod.reset);
    return out.items;
}

/// Hang a card off the open run's gutter — every line of it, so a wrapped
/// title and a banded diff stay inside the same rail.
fn indent(a: std.mem.Allocator, th: theme_mod.Theme, card: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var it = std.mem.splitScalar(u8, card, '\n');
    var first = true;
    while (it.next()) |ln| {
        if (!first) try out.append('\n');
        first = false;
        try out.appendSlice(th.muted);
        try out.appendSlice(foldhdr.gutter);
        try out.appendSlice(theme_mod.reset);
        try out.appendSlice(ln);
    }
    return out.items;
}

pub fn row(self: *const Model, a: std.mem.Allocator, user_no: u32, e: app.Entry, width: usize, now_ms: u64, selected: bool) ![]const u8 {
    const th = self.theme();
    const mark: []const u8 = switch (e.kind) {
        .user => "",
        .assistant => glyphs.assistant,
        .tool => glyphs.tool,
        .system => glyphs.system,
        .err => glyphs.assistant,
        .pending => thinkingGlyph(now_ms),
    };
    const color: []const u8 = switch (e.kind) {
        .user => th.text,
        .assistant, .pending => th.accent,
        .tool, .system => th.muted,
        .err => th.error_fg,
    };
    const raw = if (e.kind == .pending)
        // A background engine op (/compact, !cmd) names itself; a model turn
        // pushes an empty row and gets the generic label.
        (if (e.text.len > 0) e.text else thinkingLabel(now_ms))
    else if (e.kind == .tool)
        try toolTitle(a, e, e)
    else if (e.folded)
        firstLine(e.text)
    else
        e.text;
    const body = switch (e.kind) {
        .assistant => try @import("markdown.zig").renderThemed(a, raw, th, width -| 4), // the "  ● " gutter costs 4 cols
        .user => try @import("markdown.zig").renderUser(a, raw, th.accent, th.text),
        else => raw,
    };
    const sel = glyphs.frame(&glyphs.row_mark, @intFromBool(!selected));
    if (e.kind == .user) {
        const line = try std.fmt.allocPrint(a, "{s}{s}#{d}{s}  {s}", .{ sel, th.muted, user_no, theme_mod.reset, body });
        return theme_mod.wrapToWidth(a, line, width);
    }
    if (e.kind == .pending) {
        const line = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s} {s}{s}", .{ sel, th.accent, thinkingGlyph(now_ms), theme_mod.reset, th.muted, body, theme_mod.reset });
        return theme_mod.wrapToWidth(a, line, width);
    }
    const body_fg = if (e.kind == .err) th.error_fg else th.text;
    const line = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s} {s}{s}", .{ sel, color, mark, theme_mod.reset, body_fg, body, theme_mod.reset });
    return theme_mod.wrapToWidth(a, line, width);
}

fn userNo(self: *const Model, idx: usize) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i <= idx and i < self.history.items.len) : (i += 1) {
        if (self.history.items[i].kind == .user) n += 1;
    }
    return if (n == 0) 1 else n;
}

// The run-walk primitives live in foldhdr.zig, which needs them to COUNT a
// run before this file can draw one. Re-exported here so every caller (and
// every test written against them) keeps one name for one rule.
const isStartTool = foldhdr.isStartTool;
const isDoneTool = foldhdr.isDoneTool;
pub const nextTool = foldhdr.nextTool;
const displayName = foldhdr.displayName;

/// The head of a tool row: `[status mark] name  [argument preview]`, composed
/// from FIELDS. On a paired card the name and its arguments come from the call
/// (`named`) while the status mark comes from the outcome (`status`); on a lone
/// row both are the same entry. A legacy row has only its stored line and is
/// shown verbatim rather than taken apart — the old code split that line on
/// " | ", which silently truncated any command containing one.
fn toolTitle(a: std.mem.Allocator, named: app.Entry, status: app.Entry) ![]const u8 {
    const t = named.tool orelse return named.text;
    const mark: []const u8 = if (status.tool) |s|
        (if (s.denied) glyphs.denied ++ " " else if (s.is_error) glyphs.failed ++ " " else "")
    else
        "";
    const name = displayName(t.name);
    // A finished row's detail is its RESULT preview and belongs in the body.
    const args = if (t.done) "" else t.detail;
    if (args.len == 0) return if (mark.len == 0) name else std.fmt.allocPrint(a, "{s}{s}", .{ mark, name });
    return std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, name, args });
}

/// The one-line body under a tool card: the outcome's result preview.
fn toolPreview(e: app.Entry) ?[]const u8 {
    const t = e.tool orelse return null;
    if (!t.done or t.detail.len == 0) return null;
    return t.detail;
}

pub fn toolVisual(
    self: *const Model,
    a: std.mem.Allocator,
    t: usize,
    end: usize,
    width: usize,
    now_ms: u64,
    selected: bool,
) ![]const u8 {
    const e = self.history.items[t];
    const paired = t + 1 < end and isStartTool(e) and isDoneTool(self.history.items[t + 1]);
    if (!paired) return row(self, a, 0, e, width, now_ms, selected); // a tool row is never numbered
    return toolCard(a, self.theme(), e, self.history.items[t + 1], selected, width);
}

fn toolCard(a: std.mem.Allocator, th: theme_mod.Theme, call: app.Entry, outcome: app.Entry, selected: bool, width: usize) ![]const u8 {
    const sel = glyphs.frame(&glyphs.row_mark, @intFromBool(!selected));
    const title = try toolTitle(a, call, outcome);
    const preview = toolPreview(outcome);
    const head = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s} {s}", .{ sel, if (selected) th.accent else th.muted, glyphs.tool, theme_mod.reset, th.text, title });
    if (preview == null) return theme_mod.wrapToWidth(a, head, width);
    // A patch-shaped result is banded, not quoted: diff.zig owns its wrap.
    if (diff_mod.looksLikeUnified(preview.?)) return std.fmt.allocPrint(a, "{s}\n{s}", .{ try theme_mod.wrapToWidth(a, head, width), try diff_mod.renderThemed(a, preview.?, th, width) });
    const body = try std.fmt.allocPrint(a, "{s}{s}│  {s}{s}", .{ sel, th.muted, preview.?, theme_mod.reset });
    const joined = try std.fmt.allocPrint(a, "{s}\n{s}", .{ try theme_mod.wrapToWidth(a, head, width), try theme_mod.wrapToWidth(a, body, width) });
    return joined;
}

fn thinkingGlyph(now_ms: u64) []const u8 {
    // A soft 1s blink on the PENDING row only. A fully static frame made
    // run.zig's hash-diff suppress every paint for a background op's whole
    // duration — 8s of literally zero terminal output read as a freeze. One
    // changing glyph on one line keeps the paints flowing while historical
    // rows stay byte-identical (the earlier full-transcript pulse bug). The
    // frames come from the registry, which pins each to ONE column so the
    // label beside them never steps sideways as they tick (glyphs.zig).
    return glyphs.frame(&glyphs.thinking, now_ms / 500);
}

fn thinkingLabel(now_ms: u64) []const u8 {
    _ = now_ms;
    // Grok: static "Thinking" — motion is only the one-column blink.
    return "Thinking";
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}

/// The live tail is raw model bytes: escapes, C0 controls (a CR would rewind
/// the row) and the half glyph a delta boundary left behind all have to go
/// before it reaches a frame. Same filter the finished message gets.
pub fn strip(a: std.mem.Allocator, s: []const u8) []const u8 {
    return @import("markdown.zig").sanitize(a, s) catch s;
}

pub fn tail(a: std.mem.Allocator, s: []const u8, width: usize, max_lines: usize) ![]const u8 {
    var lines = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, s, '\n');
    // No tool-line filter any more: the live buffer carries PROSE only —
    // answer text and (with /thinking on) reasoning. Tool activity reaches the
    // transcript as typed events, so nothing here has to guess which lines the
    // sink drew (#551).
    while (it.next()) |ln| try lines.append(ln);
    const start = if (lines.items.len > max_lines) lines.items.len - max_lines else 0;
    var out = std.array_list.Managed(u8).init(a);
    for (lines.items[start..], 0..) |ln, n| {
        if (n > 0) try out.append('\n');
        try out.appendSlice(try theme_mod.wrapToWidth(a, try std.fmt.allocPrint(a, "    {s}", .{ln}), width));
    }
    return out.items;
}

test "firstLine stops at newline" {
    try std.testing.expectEqualStrings("ab", firstLine("ab\ncd"));
}

test "thinking animation is a one-column blink plus a static Thinking" {
    try std.testing.expectEqualStrings("Thinking", thinkingLabel(0));
    try std.testing.expectEqualStrings(thinkingLabel(0), thinkingLabel(320));
    try std.testing.expectEqualStrings(glyphs.thinking[0], thinkingGlyph(0));
    // The glyph must actually FLICKER across a half-period, and be stable
    // within one — a fully static pending row suppressed every paint for a
    // background op's whole duration (verified live: 8s of zero output).
    try std.testing.expectEqualStrings(thinkingGlyph(0), thinkingGlyph(140));
    try std.testing.expect(!std.mem.eql(u8, thinkingGlyph(0), thinkingGlyph(500)));
}

test "a live turn never pulses or shifts historical rows" {
    const engine = @import("engine.zig");
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    // Pushed against a clock well past the settle window, so the fold header's
    // one-second flash is already over and the only motion under test is the
    // pending blink. The flash itself is exercised below.
    m.now_ms = 100_000;
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    try m.push(.assistant, "done");
    try m.push(.pending, "");
    var sbuf: [16]u8 = undefined;
    var none: [0]engine.Turn = .{};
    var job: engine.Job = .{
        .gpa = std.testing.allocator,
        .history = &none,
        .params = .{},
        .stream = .{ .buf = &sbuf },
    };
    m.pending = &job;
    defer m.pending = null;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t0 = try render(&m, arena.allocator(), 80, 200_000);
    const t140 = try render(&m, arena.allocator(), 80, 200_140);
    var it = std.mem.splitScalar(u8, t0, '\n');
    var saw_summary = false;
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "Ran bash") != null) {
            saw_summary = true;
            try std.testing.expect(std.mem.indexOf(u8, ln, glyphs.thinking[0]) == null);
        }
    }
    try std.testing.expect(saw_summary);
    try std.testing.expectEqualStrings(t0, t140);
    // Across a blink half-period exactly ONE line — the pending row — may
    // change; every historical row stays byte-identical. (Full staticness
    // went the other way into a paint freeze; full pulsing was the original
    // bug. The contract is: motion exists, and it is confined.)
    const t500 = try render(&m, arena.allocator(), 80, 200_500);
    var it0 = std.mem.splitScalar(u8, t0, '\n');
    var it5 = std.mem.splitScalar(u8, t500, '\n');
    var changed: usize = 0;
    while (it0.next()) |a0| {
        const a5 = it5.next() orelse "";
        if (!std.mem.eql(u8, a0, a5)) {
            changed += 1;
            try std.testing.expect(std.mem.indexOf(u8, a0, "Thinking") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), changed);
}

test "the settle flash is the ONE extra moving row, and it stops on its own" {
    // A deliberate widening of the pin above. A tool run that has just settled
    // owns a second moving row for one second — its header, tinted — and that
    // is the whole of the allowance: the flash is a single on→off transition
    // on a single row, not a tick, so the transcript still cannot pulse.
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.now_ms = 10_000;
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lit = try render(&m, arena.allocator(), 80, 10_000);
    const mid = try render(&m, arena.allocator(), 80, 10_900);
    const off = try render(&m, arena.allocator(), 80, 11_000);
    const later = try render(&m, arena.allocator(), 80, 60_000);
    // Nothing moves WITHIN the window...
    try std.testing.expectEqualStrings(lit, mid);
    // ...the tint is real while it is up...
    try std.testing.expect(std.mem.indexOf(u8, lit, foldhdr.flashBg(m.theme())) != null);
    try std.testing.expect(std.mem.indexOf(u8, off, foldhdr.flashBg(m.theme())) == null);
    // ...it closes back onto the canvas so the row below inherits nothing...
    var it = std.mem.splitScalar(u8, lit, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, foldhdr.flashBg(m.theme())) == null) continue;
        try std.testing.expect(std.mem.endsWith(u8, ln, theme_mod.reset));
        try std.testing.expect(std.mem.indexOf(u8, ln, m.theme().bg) != null);
    }
    // ...and exactly ONE row differs across the on→off edge.
    var a0 = std.mem.splitScalar(u8, lit, '\n');
    var a1 = std.mem.splitScalar(u8, off, '\n');
    var changed: usize = 0;
    while (a0.next()) |x| {
        const y = a1.next() orelse "";
        if (!std.mem.eql(u8, x, y)) {
            changed += 1;
            try std.testing.expect(std.mem.indexOf(u8, y, "Ran bash") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), changed);
    // After that the row is done moving for good.
    try std.testing.expectEqualStrings(off, later);
}

test "displayName shortens an mcp tool to its leaf, reading the NAME" {
    // The old prettyTool took a rendered LINE and stripped a status glyph off
    // it first; this takes the engine's tool name, which is all it ever needed.
    try std.testing.expectEqualStrings("memo", displayName("mcp__codedbpro__memo"));
    try std.testing.expectEqualStrings("faster_search", displayName("mcp__codedbpro__faster_search"));
    try std.testing.expectEqualStrings("bash", displayName("bash"));
    try std.testing.expectEqualStrings("read", displayName("read_file"));
}

test {
    _ = @import("scrollback_tests.zig");
}

test "a collapsed tool run is one verb header, and it flips open" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    try m.push(.assistant, "done");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "#1") != null);
    // One logical call — the announce and its outcome — read in past tense,
    // behind a closed chevron.
    try std.testing.expect(std.mem.indexOf(u8, text, "Ran bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, glyphs.chev_closed ++ " Ran bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "⚙ bash") == null);
    m.toggleToolGroup(1);
    const open = try render(&m, arena.allocator(), 80, 0);
    // Open: the same header, chevron flipped, cards under it on the gutter.
    try std.testing.expect(std.mem.indexOf(u8, open, glyphs.chev_open ++ " Ran bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, glyphs.chev_closed ++ " Ran bash") == null);
    try std.testing.expect(std.mem.indexOf(u8, open, foldhdr.gutter) != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "Called") == null);
}

test "long assistant lines wrap to the terminal width" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.assistant, "Hey. I am in /Users/blackfloofie/codegraff on a very long branch name so this must wrap");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 40, 0);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        try std.testing.expect(theme_mod.visibleLen(ln) <= 40);
    }
}

test "the header's visual row maps back to the tool group" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80, 0);
    var vis: usize = 0;
    var hit: ?usize = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| : (vis += 1) {
        if (std.mem.indexOf(u8, ln, "Ran bash") != null) {
            hit = vis;
            break;
        }
    }
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(usize, 1), indexAtVisual(&m, hit.?, 80).?);
}

test "collapsed search run reads as a search, in past tense" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.pushTool(.{ .name = "grep", .detail = "needle" });
    try m.pushTool(.{ .name = "grep", .detail = "3 hits", .done = true });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "Searched 1 pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "⚙ grep") == null);
    m.toggleToolGroup(0);
    const open = try render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, open, "needle") != null);
}

test "expanded read card shows the path and preview" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.pushTool(.{ .name = "read_file", .detail = "src/foo.zig" });
    try m.pushTool(.{ .name = "read_file", .detail = "const std = @import(\"std\");", .done = true });
    m.toggleToolGroup(0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "const std") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Called") == null);
}
