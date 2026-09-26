//! Standard ACP v1 subagent progress (ADR 0205). While a child works, its
//! parent's `agent` tool call receives `tool_call_update`s whose `content` is
//! a short rolling log of what the child is doing: each tool it calls, any
//! failure, and the tail of the message it is writing. Every ACP client
//! renders tool call content, so this needs no capability or flag. Updates
//! carry no `status`: the parent's own tool result decides that, and a
//! detached child's spawn call stays completed instead of spinning forever.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const proto = @import("acp_protocol.zig");
const stream = @import("acp_stream.zig");
const util = @import("util.zig");

pub const max_lines = 12;
pub const line_max = 160;
pub const tail_max = 280;
/// Text deltas publish at most this often; tool events publish immediately.
pub const text_interval_ms: i64 = 400;

pub const Progress = struct {
    parent_call_id: []const u8,
    child_id: []const u8,
    name: []const u8,
    lines: [max_lines][line_max]u8 = undefined,
    lens: [max_lines]usize = @splat(0),
    count: usize = 0,
    tail: [tail_max]u8 = undefined,
    tail_len: usize = 0,
    last_ms: i64 = 0,

    pub fn addLine(p: *Progress, text: []const u8) void {
        const slot = p.count % max_lines;
        const cut = util.utf8Prefix(text, line_max);
        var n: usize = 0;
        for (cut) |c| {
            p.lines[slot][n] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
            n += 1;
        }
        p.lens[slot] = n;
        p.count += 1;
        // A new step starts a new message; the old tail belongs to the step before.
        p.tail_len = 0;
    }

    /// Keep the last `tail_max` bytes of the message being written, cut on a
    /// UTF-8 boundary.
    pub fn addText(p: *Progress, delta: []const u8) void {
        if (delta.len >= tail_max) {
            var start = delta.len - tail_max;
            while (start < delta.len and (delta[start] & 0xC0) == 0x80) start += 1;
            const rest = delta[start..];
            @memcpy(p.tail[0..rest.len], rest);
            p.tail_len = rest.len;
            return;
        }
        const keep = @min(p.tail_len, tail_max - delta.len);
        var start = p.tail_len - keep;
        while (start < p.tail_len and (p.tail[start] & 0xC0) == 0x80) start += 1;
        std.mem.copyForwards(u8, p.tail[0 .. p.tail_len - start], p.tail[start..p.tail_len]);
        const base = p.tail_len - start;
        @memcpy(p.tail[base..][0..delta.len], delta);
        p.tail_len = base + delta.len;
    }

    pub fn toolLine(p: *Progress, name: []const u8, input: Value) void {
        var buf: [line_max]u8 = undefined;
        const title = stream.titleFor(name, input);
        const line = if (std.mem.eql(u8, title, name))
            std.fmt.bufPrint(&buf, "▸ {s}", .{name}) catch name
        else
            std.fmt.bufPrint(&buf, "▸ {s}: {s}", .{ name, util.utf8Prefix(title, line_max - name.len - 8) }) catch name;
        p.addLine(line);
    }

    /// Oldest to newest, then the message tail.
    pub fn render(p: *const Progress, buf: []u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        const first = if (p.count > max_lines) p.count - max_lines else 0;
        var i = first;
        while (i < p.count) : (i += 1) {
            const slot = i % max_lines;
            if (i > first) w.writeAll("\n") catch break;
            w.writeAll(p.lines[slot][0..p.lens[slot]]) catch break;
        }
        if (p.tail_len > 0) {
            if (p.count > 0) w.writeAll("\n\n") catch {};
            w.writeAll(std.mem.trim(u8, p.tail[0..p.tail_len], " \n")) catch {};
        }
        return w.buffered();
    }

    pub fn due(p: *Progress, now_ms: i64, tool_event: bool) bool {
        if (!tool_event and now_ms - p.last_ms < text_interval_ms) return false;
        p.last_ms = now_ms;
        return true;
    }
};

/// One progress update on the parent's tool call, in the parent's session.
pub fn write(w: *Io.Writer, parent_session: []const u8, p: *const Progress, state: []const u8) !void {
    var buf: [max_lines * (line_max + 1) + tail_max + 8]u8 = undefined;
    try proto.writeNotification(w, "session/update", .{
        .sessionId = parent_session,
        .update = .{
            .sessionUpdate = "tool_call_update",
            .toolCallId = p.parent_call_id,
            .content = .{
                .{ .type = "content", .content = .{ .type = "text", .text = p.render(&buf) } },
            },
            ._meta = .{ .@"graff/subagent" = .{ .sessionId = p.child_id, .name = p.name, .state = state } },
        },
    });
}

/// GRAFF_ACP_SUBAGENT_PROGRESS=0 turns the stream off.
pub fn enabled() bool {
    const v = std.c.getenv("GRAFF_ACP_SUBAGENT_PROGRESS") orelse return true;
    return !std.mem.eql(u8, std.mem.span(v), "0");
}

test "the log keeps the newest steps and a UTF-8-safe message tail" {
    var p: Progress = .{ .parent_call_id = "spawn-1", .child_id = "sa-1", .name = "Scout" };
    var i: usize = 0;
    while (i < max_lines + 3) : (i += 1) {
        var b: [32]u8 = undefined;
        p.addLine(std.fmt.bufPrint(&b, "step {d}", .{i}) catch unreachable);
    }
    var out: [4096]u8 = undefined;
    const text = p.render(&out);
    try std.testing.expect(std.mem.indexOf(u8, text, "step 0\n") == null);
    try std.testing.expect(std.mem.startsWith(u8, text, "step 3"));
    try std.testing.expect(std.mem.endsWith(u8, text, "step 14"));
    var long: [600]u8 = undefined;
    for (&long, 0..) |*c, k| c.* = if (k % 3 == 0) 0xE2 else if (k % 3 == 1) 0x96 else 0xB8; // "▸" repeated
    p.addText(&long);
    try std.testing.expect(p.tail_len <= tail_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.tail[0..p.tail_len]));
    p.addText("done.");
    try std.testing.expect(std.mem.endsWith(u8, p.tail[0..p.tail_len], "done."));
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.tail[0..p.tail_len]));
}

test "text publishes on an interval, tool events at once" {
    var p: Progress = .{ .parent_call_id = "c", .child_id = "s", .name = "n" };
    try std.testing.expect(p.due(1000, false));
    try std.testing.expect(!p.due(1100, false));
    try std.testing.expect(p.due(1150, true));
    try std.testing.expect(p.due(1600, false));
}
