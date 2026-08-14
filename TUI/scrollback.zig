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

fn lineCount(s: []const u8) usize {
    if (s.len == 0) return 1;
    return std.mem.count(u8, s, "\n") + 1;
}

fn isSearch(text: []const u8) bool {
    return containsIgnoreCase(text, "search") or containsIgnoreCase(text, "grep") or containsIgnoreCase(text, "find");
}

fn isMcp(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "mcp__") != null or containsIgnoreCase(text, "mcp");
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
        const t = self.history.items[i].text;
        if (isMcp(t)) mcp_n += 1;
        if (isSearch(t)) searches += 1 else calls += 1;
    }
    const sel: []const u8 = if (selected) "› " else "  ";
    const live = if (self.pending != null)
        try std.fmt.allocPrint(a, "{s}❙{s} ", .{ if (flickerOn(self.now_ms)) th.accent else th.muted, theme_mod.reset })
    else
        "";
    var out = std.array_list.Managed(u8).init(a);
    if (calls > 0) {
        const label = if (mcp_n == calls + searches)
            try std.fmt.allocPrint(a, "{s}{s}◆ Called {d} MCP tool{s}", .{ sel, live, calls, if (calls == 1) "" else "s" })
        else
            try std.fmt.allocPrint(a, "{s}{s}◆ Called {d} tool{s}", .{ sel, live, calls, if (calls == 1) "" else "s" });
        try out.appendSlice(try theme_mod.paint(a, if (selected) th.accent else th.muted, label));
    }
    if (searches > 0) {
        if (out.items.len > 0) try out.append('\n');
        const label = try std.fmt.allocPrint(a, "{s}{s}◆ Searched {d} MCP tool{s}", .{ sel, live, searches, if (searches == 1) "" else "s" });
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
        thinkingLabel(now_ms)
    else if (e.kind == .tool)
        try toolTitle(a, e.text)
    else if (e.folded)
        firstLine(e.text)
    else
        e.text;
    const body = switch (e.kind) {
        .assistant => try @import("markdown.zig").renderTinted(a, raw, th.accent, th.muted, th.text),
        .user => try @import("markdown.zig").renderUser(a, raw, th.accent, th.text),
        else => raw,
    };
    const sel: []const u8 = if (selected) "› " else "  ";
    if (e.kind == .user) {
        const line = try std.fmt.allocPrint(a, "{s}{s}#{d}{s}  {s}", .{ sel, th.muted, userNo(self, idx), theme_mod.reset, body });
        return theme_mod.wrapToWidth(a, line, width);
    }
    if (e.kind == .pending) {
        const fg = if (flickerOn(now_ms)) th.accent else th.muted;
        const line = try std.fmt.allocPrint(a, "{s}{s}❙{s} {s}{s}", .{ sel, fg, theme_mod.reset, body, theme_mod.reset });
        return theme_mod.wrapToWidth(a, line, width);
    }
    const line = try std.fmt.allocPrint(a, "{s}{s}{s}{s} {s}{s}", .{ sel, color, mark, theme_mod.reset, body, theme_mod.reset });
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

fn prettyTool(text: []const u8) []const u8 {
    var s = std.mem.trim(u8, text, " \t");
    const prefixes = [_][]const u8{ "⚙ ", "✓ ", "✗ ", "⊘ " };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) s = s[p.len..];
    }
    if (std.mem.startsWith(u8, s, "mcp__")) {
        if (std.mem.lastIndexOf(u8, s, "__")) |u| {
            if (u + 2 < s.len) return s[u + 2 ..];
        }
    }
    return s;
}

fn isStartTool(text: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, text, " \t"), "⚙ ");
}

fn isDoneTool(text: []const u8) bool {
    const s = std.mem.trim(u8, text, " \t");
    return std.mem.startsWith(u8, s, "✓ ") or std.mem.startsWith(u8, s, "✗ ") or std.mem.startsWith(u8, s, "⊘ ");
}

fn nextTool(self: *const Model, t: usize, end: usize) usize {
    if (t + 1 < end and isStartTool(self.history.items[t].text) and isDoneTool(self.history.items[t + 1].text))
        return t + 2;
    return t + 1;
}

fn shortToolName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read_file")) return "read";
    if (std.mem.eql(u8, name, "write_file")) return "write";
    return name;
}

fn toolTitle(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const pretty = prettyTool(text);
    const cut = std.mem.indexOf(u8, pretty, " | ") orelse pretty.len;
    const head = pretty[0..cut];
    const sp = std.mem.indexOfScalar(u8, head, ' ') orelse return shortToolName(head);
    const name = shortToolName(head[0..sp]);
    const rest = std.mem.trim(u8, head[sp + 1 ..], " \t");
    if (rest.len == 0) return name;
    return std.fmt.allocPrint(a, "{s}  {s}", .{ name, rest });
}

fn toolPreview(text: []const u8) ?[]const u8 {
    const pretty = prettyTool(text);
    const at = std.mem.indexOf(u8, pretty, " | ") orelse return null;
    const body = std.mem.trim(u8, pretty[at + 3 ..], " \t");
    return if (body.len == 0) null else body;
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
    const paired = t + 1 < end and isStartTool(e.text) and isDoneTool(self.history.items[t + 1].text);
    if (!paired) return row(self, a, t, e, width, now_ms, selected);
    return toolCard(a, self.theme(), e.text, self.history.items[t + 1].text, selected, width);
}

fn toolCard(a: std.mem.Allocator, th: theme_mod.Theme, start_text: []const u8, done_text: []const u8, selected: bool, width: usize) ![]const u8 {
    const sel: []const u8 = if (selected) "› " else "  ";
    const title = try toolTitle(a, start_text);
    const preview = toolPreview(done_text);
    const head = try std.fmt.allocPrint(a, "{s}{s}◆{s} {s}", .{ sel, if (selected) th.accent else th.muted, theme_mod.reset, title });
    if (preview == null) return theme_mod.wrapToWidth(a, head, width);
    const body = try std.fmt.allocPrint(a, "{s}{s}│  {s}{s}", .{ sel, th.muted, preview.?, theme_mod.reset });
    const joined = try std.fmt.allocPrint(a, "{s}\n{s}", .{ try theme_mod.wrapToWidth(a, head, width), try theme_mod.wrapToWidth(a, body, width) });
    return joined;
}

fn flickerOn(now_ms: u64) bool {
    return (now_ms / 140) % 2 == 0;
}

fn thinkingGlyph(now_ms: u64) []const u8 {
    _ = now_ms;
    return "❙";
}

fn thinkingLabel(now_ms: u64) []const u8 {
    const frames = [_][]const u8{ "thinking   ", "thinking.  ", "thinking.. ", "thinking..." };
    return frames[(now_ms / 320) % frames.len];
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
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (@import("turn.zig").isToolLine(t)) continue;
        try lines.append(ln);
    }
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

test "thinking animation is a word, not a lone spinner" {
    try std.testing.expect(std.mem.startsWith(u8, thinkingLabel(0), "thinking"));
    try std.testing.expect(!std.mem.eql(u8, thinkingLabel(0), thinkingLabel(320)));
    try std.testing.expectEqualStrings("❙", thinkingGlyph(0));
    try std.testing.expect(flickerOn(0) != flickerOn(140));
}

test "prettyTool strips mcp prefix" {
    try std.testing.expectEqualStrings("memo", prettyTool("✓ mcp__codedbpro__memo"));
    try std.testing.expectEqualStrings("faster_search", prettyTool("⚙ mcp__codedbpro__faster_search"));
    try std.testing.expectEqualStrings("bash", prettyTool("⚙ bash"));
}

test "collapsed tool run is one Called summary" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.push(.tool, "⚙ bash");
    try m.push(.tool, "✓ bash");
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
    try m.push(.tool, "⚙ bash");
    try m.push(.tool, "✓ bash");
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
    try m.push(.tool, "⚙ grep needle");
    try m.push(.tool, "✓ grep needle");
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
    try m.push(.tool, "⚙ read src/foo.zig");
    try m.push(.tool, "✓ read | const std = @import(\"std\");");
    m.toggleToolGroup(0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "const std") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Called") == null);
}
