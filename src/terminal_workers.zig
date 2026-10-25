//! Read-only, mouse-enabled inspection of this process's existing child feed.
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;
const Agent = @import("agent.zig").Agent;
const activity = @import("subagent_activity.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;
const term = @import("term.zig");
const safe = @import("line_repl_disclosure.zig").sanitized;
const cellWidth = @import("repl_markdown.zig").codepointWidth;

pub const Point = struct { x: usize, y: usize };
pub const Action = union(enum) { none, up, down, select, back, quit, tools, thoughts, refresh, click: Point };

pub const Keys = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    pub fn feed(self: *Keys, b: u8) Action {
        if (self.len == 0) {
            return switch (b) {
                0x1b => blk: {
                    self.bytes[0] = b;
                    self.len = 1;
                    break :blk .none;
                },
                '\r', '\n' => .select,
                0x03, 'q' => .quit,
                0x7f, 0x08 => .back,
                'k' => .up,
                'j' => .down,
                't' => .tools,
                'h' => .thoughts,
                'r' => .refresh,
                else => .none,
            };
        }
        if (self.len == self.bytes.len) {
            self.len = 0;
            return .none;
        }
        self.bytes[self.len] = b;
        self.len += 1;
        if (self.len == 2) {
            if (b != '[') {
                self.len = 0;
                return .back;
            }
            return .none;
        }
        if (b < 0x40 or b > 0x7e) return .none;
        const packet = self.bytes[0..self.len];
        self.len = 0;
        if (std.mem.eql(u8, packet, "\x1b[A")) return .up;
        if (std.mem.eql(u8, packet, "\x1b[B")) return .down;
        if (std.mem.startsWith(u8, packet, "\x1b[<") and (b == 'M' or b == 'm')) {
            var parts = std.mem.splitScalar(u8, packet[3 .. packet.len - 1], ';');
            const button = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return .none;
            const x = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return .none;
            const y = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return .none;
            if (parts.next() != null or x == 0 or y == 0 or b == 'm') return .none;
            if (button == 64) return .up;
            if (button == 65) return .down;
            if (button & 3 == 0 and button & 64 == 0) return .{ .click = .{ .x = x, .y = y } };
        }
        if (b == 'u') {
            const end = std.mem.indexOfScalar(u8, packet, ';') orelse packet.len - 1;
            const code = std.fmt.parseInt(u32, packet[2..end], 10) catch return .none;
            return switch (code) {
                13 => .select,
                27 => .back,
                113 => .quit,
                else => .none,
            };
        }
        return .none;
    }
    pub fn expire(self: *Keys) Action {
        const escape = self.len == 1;
        self.len = 0;
        return if (escape) .back else .none;
    }
};

pub fn snapshot(a: A, io: Io, dir: Io.Dir, id: []const u8) !activity.Snapshot {
    if (!activity.validId(id)) return error.InvalidChildId;
    const name = try std.fmt.allocPrint(a, "{s}.json", .{id});
    const bytes = try dir.readFileAlloc(io, name, a, .limited(activity.file_limit));
    const result = try std.json.parseFromSliceLeaky(activity.Snapshot, a, bytes, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, result.agent.id, id) or result.events.len > activity.max_events) return error.InvalidChildSnapshot;
    return result;
}

fn oneLine(a: A, text: []const u8) ![]const u8 {
    const cleaned = try safe(a, text);
    for (cleaned) |*b| if (b.* == '\n' or b.* == '\t') {
        b.* = ' ';
    };
    return cleaned;
}

fn statusColor(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "failed")) return style.red;
    if (std.mem.eql(u8, status, "completed")) return style.green;
    return style.accent;
}
fn mark(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "failed")) return "✗";
    if (std.mem.eql(u8, status, "completed")) return "✓";
    return "●";
}

/// Styled bytes are ours; untrusted snapshot strings are sanitized first.
fn advance(text: []const u8, i: usize) usize {
    if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
        var end = i + 2;
        while (end < text.len) : (end += 1) if (text[end] >= 0x40 and text[end] <= 0x7e) return end + 1;
        return text.len;
    }
    return @min(text.len, i + (std.unicode.utf8ByteSequenceLength(text[i]) catch 1));
}
fn width(text: []const u8, i: usize, end: usize) usize {
    if (text[i] == 0x1b) return 0;
    return cellWidth(std.unicode.utf8Decode(text[i..end]) catch '?');
}
fn clipped(out: *Io.Writer, text: []const u8, cols: usize) !void {
    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        const end = advance(text, i);
        const n = width(text, i, end);
        if (used + n > cols) break;
        try out.writeAll(text[i..end]);
        used += n;
        i = end;
    }
    try out.writeAll(style.reset);
}

pub fn wrap(a: A, text: []const u8, cols: usize) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var start: usize = 0;
        var i: usize = 0;
        var used: usize = 0;
        var space: ?usize = null;
        while (i < line.len) {
            const end = advance(line, i);
            const n = width(line, i, end);
            if (used + n > @max(cols, 2) and i > start) {
                const cut = if (line[i] == ' ') i else if (space) |s| (if (s > start) s else i) else i;
                try result.append(a, line[start..cut]);
                start = if (cut < line.len and line[cut] == ' ') cut + 1 else cut;
                i = start;
                used = 0;
                space = null;
                continue;
            }
            if (line[i] == ' ') space = i;
            used += n;
            i = end;
        }
        try result.append(a, line[start..]);
    }
    return result.items;
}

fn markdown(root: *Agent, a: A, out: *Io.Writer, text: []const u8) !void {
    const cleaned = try safe(a, text);
    var view = root.*;
    view.md_fence = false;
    var lines = std.mem.splitScalar(u8, cleaned, '\n');
    while (lines.next()) |line| {
        view.renderMdLine(out, line);
        try out.writeByte('\n');
    }
}

pub fn detail(root: *Agent, a: A, child: activity.Snapshot, tools: bool, thoughts: bool) ![]const u8 {
    var buffer: Io.Writer.Allocating = .init(a);
    const out = &buffer.writer;
    try out.print("{s}Task{s}\n", .{ style.bold, style.reset });
    try markdown(root, a, out, child.agent.task);
    try out.print("\n{s}Activity{s}\n", .{ style.bold, style.reset });
    for (child.events) |event| {
        if (std.mem.eql(u8, event.type, "tool_call")) {
            try out.print("{s}↳ {s}{s}  {s}\n", .{ style.accent, try safe(a, event.name), style.reset, try safe(a, event.text) });
        } else if (std.mem.eql(u8, event.type, "tool_result")) {
            try out.print("{s}{s} {s}{s}\n", .{ if (event.is_error) style.red else style.muted, if (event.is_error) "✗" else "✓", try safe(a, event.name), style.reset });
            if (tools or event.is_error) try markdown(root, a, out, event.text);
        } else if (std.mem.eql(u8, event.type, "reasoning")) {
            if (thoughts) try markdown(root, a, out, event.text);
        } else if (std.mem.eql(u8, event.type, "text") and child.response.len == 0) {
            try markdown(root, a, out, event.text);
        }
    }
    if (child.response.len > 0) {
        try out.print("\n{s}Report{s}\n", .{ style.bold, style.reset });
        try markdown(root, a, out, child.response);
    }
    if (child.agent.truncated) try out.print("\n{s}Earlier activity omitted (bounded snapshot).{s}\n", .{ style.muted, style.reset });
    return buffer.written();
}

pub fn drawList(a: A, out: *Io.Writer, rows: []const activity.Meta, selected: usize, cols: usize, height: usize) !usize {
    try clipped(out, try std.fmt.allocPrint(a, "{s}{s}Workers{s}  {d} recent agents", .{ style.bold, style.accent, style.reset, rows.len }), cols -| 1);
    try out.print("\n{s}", .{style.muted});
    try clipped(out, "Click an agent to inspect its activity", cols -| 1);
    try out.writeAll("\n\n");
    const visible = @max(@as(usize, 1), (height -| 5) / 3);
    const chosen = @min(selected, rows.len -| 1);
    const off = if (chosen >= visible) chosen - visible + 1 else 0;
    for (rows[off..@min(rows.len, off + visible)], off..) |row, index| {
        const title = try std.fmt.allocPrint(a, "{s}{s} {s}{s}  {s}{s}{s}", .{ statusColor(row.status), mark(row.status), if (index == selected) style.bold else style.text, try oneLine(a, row.label), style.reset, style.muted, try oneLine(a, row.status) });
        try out.writeAll(if (index == selected) "› " else "  ");
        try clipped(out, title, cols -| 3);
        try out.writeAll("\n    ");
        const seat = if (row.model.len == 0) "starting" else try oneLine(a, row.model);
        try out.writeAll(style.muted);
        try clipped(out, seat, cols -| 5);
        try out.writeAll("\n\n");
    }
    if (rows.len == 0) try clipped(out, "No subagents yet.", cols -| 1);
    return off;
}

pub fn clickedRow(point: Point, off: usize, total: usize, cols: usize, height: usize) ?usize {
    const visible = @max(@as(usize, 1), (height -| 5) / 3);
    if (point.x == 0 or point.x >= cols or point.y < 4 or point.y >= 4 + visible * 3) return null;
    const index = off + (point.y - 4) / 3;
    return if (index < total) index else null;
}

fn browse(root: *Agent, out: *Io.Writer, dir: Io.Dir, initial: []const u8) !void {
    const input = root.in orelse return;
    const raw = term.tty.enterRaw(true) orelse return;
    defer term.tty.restore(raw);
    const gate = @import("tick_gate.zig");
    gate.hold();
    defer {
        out.writeAll("\x1b[0m\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
        _ = gate.setLineStart(true);
    }
    try out.writeAll("\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?25l");
    var selected: usize = 0;
    var id_buf: [64]u8 = undefined;
    var id: []const u8 = "";
    if (initial.len > 0) {
        @memcpy(id_buf[0..initial.len], initial);
        id = id_buf[0..initial.len];
    }
    var scroll: usize = 0;
    var tools = false;
    var thoughts = false;
    var keys: Keys = .{};
    var arena = std.heap.ArenaAllocator.init(root.gpa);
    defer arena.deinit();
    while (term.tty.isForeground()) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const cols = term.termCols();
        const height = term.termRows();
        const rows = try @import("acp_agent_activity.zig").list(a, root.io, dir);
        selected = @min(selected, rows.len -| 1);
        try out.writeAll("\x1b[2J\x1b[H");
        var off: usize = 0;
        if (id.len == 0) {
            off = try drawList(a, out, rows, selected, cols, height);
        } else if (snapshot(a, root.io, dir, id)) |child| {
            const title = try std.fmt.allocPrint(a, "← Workers  /  {s}{s}{s}", .{ style.bold, try oneLine(a, child.agent.label), style.reset });
            try clipped(out, title, cols -| 1);
            try out.writeByte('\n');
            try out.writeAll(statusColor(child.agent.status));
            try clipped(out, try std.fmt.allocPrint(a, "{s} · {s}", .{ try oneLine(a, child.agent.status), try oneLine(a, child.agent.model) }), cols -| 1);
            try out.writeAll("\n\n");
            const lines = try wrap(a, try detail(root, a, child, tools, thoughts), cols -| 3);
            const room = height -| 5;
            scroll = @min(scroll, lines.len -| room);
            for (lines[scroll..@min(lines.len, scroll + room)]) |line| {
                try out.writeAll(style.text);
                try clipped(out, line, cols -| 1);
                try out.writeByte('\n');
            }
        } else |_| {
            try clipped(out, "Activity unavailable. Esc goes back.", cols -| 1);
        }
        try out.print("\x1b[{d};1H{s}", .{ height, style.muted });
        try clipped(out, if (id.len == 0) "↑/↓ move · click/Enter inspect · Esc/q close" else "↑/↓ scroll · Esc back · t tools · h thoughts · q close", cols -| 1);
        try out.flush();
        const action: Action = if (term.tty.pollPrompt(input, 500))
            keys.feed(@import("input_util.zig").editByte(input) orelse return)
        else
            keys.expire();
        switch (action) {
            .quit => return,
            .back => if (id.len > 0) {
                id = "";
                scroll = 0;
            } else return,
            .up => if (id.len > 0) {
                scroll -|= 1;
            } else {
                selected -|= 1;
            },
            .down => if (id.len > 0) {
                scroll +|= 1;
            } else {
                selected = @min(selected + 1, rows.len -| 1);
            },
            .tools => tools = !tools,
            .thoughts => thoughts = !thoughts,
            .select, .click => {
                if (id.len > 0) {
                    if (action == .click and action.click.y <= 2) {
                        id = "";
                        scroll = 0;
                    }
                } else {
                    const index = if (action == .click) clickedRow(action.click, off, rows.len, cols, height) orelse continue else selected;
                    if (index < rows.len) {
                        const chosen = rows[index].id;
                        @memcpy(id_buf[0..chosen.len], chosen);
                        id = id_buf[0..chosen.len];
                        scroll = 0;
                    }
                }
            },
            .none, .refresh => {},
        }
    }
}

pub fn tryHandle(root: *Agent, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/workers") and !std.mem.startsWith(u8, line, "/workers ")) return false;
    const id = std.mem.trim(u8, line["/workers".len..], " \t");
    if (id.len > 0 and !activity.validId(id)) {
        try out.writeAll("usage: /workers [child-id]\n");
        return true;
    }
    const self = @import("proc_identity.zig").selfRecord(root.io);
    var buf: [80]u8 = undefined;
    const path = try std.fmt.allocPrint(root.gpa, "{s}/{s}/{s}", .{ root.home, @import("presence.zig").registry_subdir, try activity.directory(&buf, self.pid, self.start_id) });
    defer root.gpa.free(path);
    var dir = Io.Dir.cwd().openDir(root.io, path, .{ .iterate = true }) catch {
        try out.writeAll("No subagents yet. Workers appear here when they start.\n");
        return true;
    };
    defer dir.close(root.io);
    if (root.in != null and @import("main.zig").use_color and term.termCols() >= 20 and term.termRows() >= 10) {
        try browse(root, out, dir, id);
    } else {
        var arena = std.heap.ArenaAllocator.init(root.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (id.len > 0) {
            const child = snapshot(a, root.io, dir, id) catch {
                try out.writeAll("Subagent activity is unavailable.\n");
                return true;
            };
            try out.writeAll(try detail(root, a, child, false, false));
        } else {
            const rows = try @import("acp_agent_activity.zig").list(a, root.io, dir);
            for (rows) |row| try out.print("{s}  {s}  {s}\n", .{ row.id, try oneLine(a, row.status), try oneLine(a, row.label) });
            if (rows.len == 0) try out.writeAll("No subagents yet.\n");
        }
    }
    try out.flush();
    return true;
}
