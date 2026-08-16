//! Conversation scrollback. ANSI only.
//! Consecutive tool rows collapse into a Grok-style summary until expanded.

const std = @import("std");

const app = @import("app.zig");
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
            const collapsed = self.history.items[run.start].folded;
            if (collapsed) {
                if (!first) try out.append('\n');
                first = false;
                const selected = self.focus == .scrollback and self.selected >= run.start and self.selected < run.end;
                try out.appendSlice(try summary(self, a, run.start, run.end, selected));
                i = run.end;
                continue;
            }
            var t = run.start;
            while (t < run.end) {
                if (!first) try out.append('\n');
                first = false;
                const selected = self.focus == .scrollback and t == self.selected;
                try out.appendSlice(try toolVisual(self, a, t, run.end, width, now_ms, selected));
                t = nextTool(self, t, run.end);
            }
            i = run.end;
            continue;
        }
        if (!first) try out.append('\n');
        first = false;
        const selected = self.focus == .scrollback and i == self.selected;
        try out.appendSlice(try row(self, a, i, e, width, now_ms, selected));
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
            const collapsed = self.history.items[run.start].folded;
            var lines: usize = 0;
            if (collapsed) {
                const s = summary(self, a, run.start, run.end, false) catch "";
                lines = lineCount(s);
            } else {
                var t = run.start;
                while (t < run.end) {
                    const s = toolVisual(self, a, t, run.end, width, self.now_ms, false) catch "";
                    lines += lineCount(s);
                    t = nextTool(self, t, run.end);
                }
            }
            if (visual_row >= v and visual_row < v + lines) return run.start;
            v += lines;
            i = run.end;
            continue;
        }
        const s = row(self, a, i, self.history.items[i], width, self.now_ms, false) catch "";
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
            const collapsed = self.history.items[run.start].folded;
            if (collapsed) {
                v += lineCount(summary(self, a, run.start, run.end, false) catch "");
            } else {
                var t = run.start;
                while (t < run.end) {
                    v += lineCount(toolVisual(self, a, t, run.end, width, self.now_ms, false) catch "");
                    t = nextTool(self, t, run.end);
                }
            }
            i = run.end;
            continue;
        }
        if (i == idx) return v;
        v += lineCount(row(self, a, i, self.history.items[i], width, self.now_ms, false) catch "");
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
            if (self.history.items[run.start].folded) {
                v += lineCount(summary(self, a, run.start, run.end, false) catch "");
            } else {
                var t = run.start;
                while (t < run.end) {
                    v += lineCount(toolVisual(self, a, t, run.end, width, self.now_ms, false) catch "");
                    t = nextTool(self, t, run.end);
                }
            }
            i = run.end;
            continue;
        }
        if (e.kind == .user and v < top_line) best = e.text;
        v += lineCount(row(self, a, i, e, width, self.now_ms, false) catch "");
        i += 1;
    }
    return best;
}

fn lineCount(s: []const u8) usize {
    if (s.len == 0) return 1;
    return std.mem.count(u8, s, "\n") + 1;
}

/// Is this a search-shaped tool? Answered from the tool NAME (#551). It used
/// to be answered from the whole rendered line, so `bash` running a command
/// that merely mentioned "find" counted as a search.
fn isSearch(name: []const u8) bool {
    return containsIgnoreCase(name, "search") or containsIgnoreCase(name, "grep") or containsIgnoreCase(name, "find");
}

fn isMcp(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mcp__");
}

/// What a row's classification reads. A field-backed row answers with the
/// engine's tool name; a legacy row restored from an old session has only its
/// rendered text, and keeps the looser substring behavior it was written with.
fn classifyOn(e: app.Entry) []const u8 {
    if (e.tool) |t| return t.name;
    return e.text;
}

fn rowIsMcp(e: app.Entry) bool {
    if (e.tool) |t| return isMcp(t.name);
    return std.mem.indexOf(u8, e.text, "mcp__") != null or containsIgnoreCase(e.text, "mcp");
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn summary(self: *const Model, a: std.mem.Allocator, start: usize, end: usize, selected: bool) ![]const u8 {
    const th = self.theme();
    var searches: usize = 0;
    var calls: usize = 0;
    var mcp_n: usize = 0;
    var i = start;
    while (i < end) : (i += 1) {
        const e = self.history.items[i];
        if (rowIsMcp(e)) mcp_n += 1;
        if (isSearch(classifyOn(e))) searches += 1 else calls += 1;
    }
    const sel: []const u8 = if (selected) "› " else "  ";
    // No live bar here: liveness belongs to the pending row alone. A bar on
    // every summary made the whole transcript pulse and shift while thinking.
    var out = std.array_list.Managed(u8).init(a);
    if (calls > 0) {
        const label = if (mcp_n == calls + searches)
            try std.fmt.allocPrint(a, "{s}◆ Called {d} MCP tool{s}", .{ sel, calls, if (calls == 1) "" else "s" })
        else
            try std.fmt.allocPrint(a, "{s}◆ Called {d} tool{s}", .{ sel, calls, if (calls == 1) "" else "s" });
        try out.appendSlice(try theme_mod.paint(a, if (selected) th.accent else th.muted, label));
    }
    if (searches > 0) {
        if (out.items.len > 0) try out.append('\n');
        const label = try std.fmt.allocPrint(a, "{s}◆ Searched {d} MCP tool{s}", .{ sel, searches, if (searches == 1) "" else "s" });
        try out.appendSlice(try theme_mod.paint(a, if (selected) th.accent else th.muted, label));
    }
    return out.items;
}

fn row(self: *const Model, a: std.mem.Allocator, idx: usize, e: app.Entry, width: usize, now_ms: u64, selected: bool) ![]const u8 {
    const th = self.theme();
    const mark: []const u8 = switch (e.kind) {
        .user => "",
        .assistant => "●",
        .tool => "◆",
        .system => "·",
        .err => "●",
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
    const sel: []const u8 = if (selected) "› " else "  ";
    if (e.kind == .user) {
        const line = try std.fmt.allocPrint(a, "{s}{s}#{d}{s}  {s}", .{ sel, th.muted, userNo(self, idx), theme_mod.reset, body });
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

/// A tool row's start/done phase, straight off its typed payload. A legacy row
/// (tool == null) is neither: it has no phase to read, so it renders alone.
fn isStartTool(e: app.Entry) bool {
    const t = e.tool orelse return false;
    return !t.done;
}

fn isDoneTool(e: app.Entry) bool {
    const t = e.tool orelse return false;
    return t.done;
}

fn nextTool(self: *const Model, t: usize, end: usize) usize {
    if (t + 1 < end and isStartTool(self.history.items[t]) and isDoneTool(self.history.items[t + 1]))
        return t + 2;
    return t + 1;
}

/// The display form of a tool NAME: the harness's internal names shortened,
/// and an MCP tool shown by its leaf. Operates on the name alone — the old
/// prettyTool did this by stripping a status glyph off a rendered line first.
fn displayName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read_file")) return "read";
    if (std.mem.eql(u8, name, "write_file")) return "write";
    if (std.mem.startsWith(u8, name, "mcp__")) {
        if (std.mem.lastIndexOf(u8, name, "__")) |u| {
            if (u + 2 < name.len) return name[u + 2 ..];
        }
    }
    return name;
}

/// The head of a tool row: `[status mark] name  [argument preview]`, composed
/// from FIELDS. On a paired card the name and its arguments come from the call
/// (`named`) while the status mark comes from the outcome (`status`); on a lone
/// row both are the same entry. A legacy row has only its stored line and is
/// shown verbatim rather than taken apart — the old code split that line on
/// " | ", which silently truncated any command containing one.
fn toolTitle(a: std.mem.Allocator, named: app.Entry, status: app.Entry) ![]const u8 {
    const t = named.tool orelse return named.text;
    const mark: []const u8 = if (status.tool) |s|
        (if (s.denied) "⊘ " else if (s.is_error) "✗ " else "")
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

fn toolVisual(
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
    if (!paired) return row(self, a, t, e, width, now_ms, selected);
    return toolCard(a, self.theme(), e, self.history.items[t + 1], selected, width);
}

fn toolCard(a: std.mem.Allocator, th: theme_mod.Theme, call: app.Entry, outcome: app.Entry, selected: bool, width: usize) ![]const u8 {
    const sel: []const u8 = if (selected) "› " else "  ";
    const title = try toolTitle(a, call, outcome);
    const preview = toolPreview(outcome);
    const head = try std.fmt.allocPrint(a, "{s}{s}◆{s}{s} {s}", .{ sel, if (selected) th.accent else th.muted, theme_mod.reset, th.text, title });
    if (preview == null) return theme_mod.wrapToWidth(a, head, width);
    const body = try std.fmt.allocPrint(a, "{s}{s}│  {s}{s}", .{ sel, th.muted, preview.?, theme_mod.reset });
    const joined = try std.fmt.allocPrint(a, "{s}\n{s}", .{ try theme_mod.wrapToWidth(a, head, width), try theme_mod.wrapToWidth(a, body, width) });
    return joined;
}

fn thinkingGlyph(now_ms: u64) []const u8 {
    // A soft 1s blink on the PENDING row only. A fully static frame made
    // run.zig's hash-diff suppress every paint for a background op's whole
    // duration — 8s of literally zero terminal output read as a freeze. One
    // changing glyph on one line keeps the paints flowing while historical
    // rows stay byte-identical (the earlier full-transcript pulse bug).
    return if ((now_ms / 500) % 2 == 0) "❙" else "❘";
}

fn thinkingLabel(now_ms: u64) []const u8 {
    _ = now_ms;
    // Grok: static "Thinking" — motion is only the ❙ flicker.
    return "Thinking";
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}

fn strip(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = theme_mod.skipEsc(s, i);
            continue;
        }
        out.append(s[i]) catch {};
        i += 1;
    }
    return out.items;
}

fn tail(a: std.mem.Allocator, s: []const u8, width: usize, max_lines: usize) ![]const u8 {
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

test "thinking animation is Grok ❙ flicker plus static Thinking" {
    try std.testing.expectEqualStrings("Thinking", thinkingLabel(0));
    try std.testing.expectEqualStrings(thinkingLabel(0), thinkingLabel(320));
    try std.testing.expectEqualStrings("❙", thinkingGlyph(0));
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
    const t0 = try render(&m, arena.allocator(), 80, 0);
    const t140 = try render(&m, arena.allocator(), 80, 140);
    var it = std.mem.splitScalar(u8, t0, '\n');
    var saw_summary = false;
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "Called") != null) {
            saw_summary = true;
            try std.testing.expect(std.mem.indexOf(u8, ln, "❙") == null);
        }
    }
    try std.testing.expect(saw_summary);
    try std.testing.expectEqualStrings(t0, t140);
    // Across a blink half-period exactly ONE line — the pending row — may
    // change; every historical row stays byte-identical. (Full staticness
    // went the other way into a paint freeze; full pulsing was the original
    // bug. The contract is: motion exists, and it is confined.)
    const t500 = try render(&m, arena.allocator(), 80, 500);
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

test "collapsed tool run is one Called summary" {
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
    try std.testing.expect(std.mem.indexOf(u8, text, "Called 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "⚙ bash") == null);
    m.toggleToolGroup(1);
    const open = try render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, open, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "Called 2") == null);
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

test "Called summary visual row maps back to the tool group" {
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
        if (std.mem.indexOf(u8, ln, "Called") != null) {
            hit = vis;
            break;
        }
    }
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(usize, 1), indexAtVisual(&m, hit.?, 80).?);
}

test "collapsed search run is one Searched summary" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.pushTool(.{ .name = "grep", .detail = "needle" });
    try m.pushTool(.{ .name = "grep", .detail = "3 hits", .done = true });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "Searched 2") != null);
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
