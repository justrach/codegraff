//! Mid-turn ACP `session/update` stream. The agent's --json events (thought,
//! text, tool_call, tool_result) become v1 session updates so a client can
//! render tools from the first call — not only the final answer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const util = @import("util.zig");
const proto = @import("acp_protocol.zig");

pub fn kindFor(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "codedb") or std.mem.eql(u8, name, "skill"))
        return "read";
    if (std.mem.eql(u8, name, "edit_file") or std.mem.eql(u8, name, "write_file"))
        return "edit";
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "bash_output") or std.mem.eql(u8, name, "bash_kill"))
        return "execute";
    if (std.mem.eql(u8, name, "webfetch")) return "fetch";
    if (std.mem.eql(u8, name, "todo_write") or std.mem.eql(u8, name, "todo_read"))
        return "think";
    return "other";
}

fn titleFor(name: []const u8, input: Value) []const u8 {
    if (input == .object) {
        if (util.strFieldObj(input.object, "path")) |p| return p;
        if (util.strFieldObj(input.object, "command")) |c| return c;
        if (util.strFieldObj(input.object, "url")) |u| return u;
    }
    return name;
}

pub fn writeThought(w: *Io.Writer, session_id: []const u8, text: []const u8) !void {
    try proto.writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{
            .sessionUpdate = "agent_thought_chunk",
            .content = .{ .type = "text", .text = text },
        },
    });
}

pub fn writeMessage(w: *Io.Writer, session_id: []const u8, text: []const u8) !void {
    try proto.writeSessionUpdate(w, session_id, text);
}

pub fn writeToolCall(w: *Io.Writer, session_id: []const u8, id: []const u8, name: []const u8, input: Value) !void {
    try proto.writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{
            .sessionUpdate = "tool_call",
            .toolCallId = id,
            .title = titleFor(name, input),
            .kind = kindFor(name),
            .status = "pending",
            .rawInput = input,
        },
    });
}

pub fn writeToolDone(w: *Io.Writer, session_id: []const u8, id: []const u8, is_error: bool, text: []const u8) !void {
    try proto.writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{
            .sessionUpdate = "tool_call_update",
            .toolCallId = id,
            .status = if (is_error) "failed" else "completed",
            .content = .{
                .{ .type = "content", .content = .{ .type = "text", .text = text } },
            },
        },
    });
}

fn storeId(id_buf: *[64]u8, id: []const u8) []const u8 {
    @memset(id_buf, 0);
    const n = @min(id.len, id_buf.len - 1);
    @memcpy(id_buf[0..n], id[0..n]);
    return id_buf[0..n];
}

fn lastId(id_buf: *const [64]u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, id_buf, 0) orelse id_buf.len;
    return if (n == 0) "call-1" else id_buf[0..n];
}

/// Translate one --json event object into zero or one session/update.
/// `id_buf` holds the last minted toolCallId when the event has no `id`.
pub fn translateEvent(
    w: *Io.Writer,
    session_id: []const u8,
    ev: Value,
    id_buf: *[64]u8,
    next_tool: *u32,
) !enum { none, thought, text, tool } {
    if (ev != .object) return .none;
    const typ = util.strFieldObj(ev.object, "type") orelse return .none;
    if (std.mem.eql(u8, typ, "reasoning")) {
        const text = util.strFieldObj(ev.object, "text") orelse return .none;
        if (text.len == 0) return .none;
        try writeThought(w, session_id, text);
        return .thought;
    }
    if (std.mem.eql(u8, typ, "text")) {
        const text = util.strFieldObj(ev.object, "text") orelse return .none;
        if (text.len == 0) return .none;
        try writeMessage(w, session_id, text);
        return .text;
    }
    if (std.mem.eql(u8, typ, "tool_call") or std.mem.eql(u8, typ, "tool_call_started")) {
        const name = util.strFieldObj(ev.object, "name") orelse "tool";
        const input = ev.object.get("input") orelse Value{ .object = .empty };
        const id = if (util.strFieldObj(ev.object, "id")) |given|
            storeId(id_buf, given)
        else blk: {
            next_tool.* += 1;
            var tmp: [32]u8 = undefined;
            const minted = std.fmt.bufPrint(&tmp, "call-{d}", .{next_tool.*}) catch "call";
            break :blk storeId(id_buf, minted);
        };
        try writeToolCall(w, session_id, id, name, input);
        return .tool;
    }
    if (std.mem.eql(u8, typ, "tool_result") or std.mem.eql(u8, typ, "tool_call_finished") or std.mem.eql(u8, typ, "tool_rejected")) {
        const use_id = if (util.strFieldObj(ev.object, "id")) |given| storeId(id_buf, given) else lastId(id_buf);
        const text = util.strFieldObj(ev.object, "text") orelse util.strFieldObj(ev.object, "message") orelse "";
        const is_error = switch (ev.object.get("is_error") orelse .null) {
            .bool => |b| b,
            else => std.mem.eql(u8, typ, "tool_rejected"),
        };
        try writeToolDone(w, session_id, use_id, is_error, text);
        return .tool;
    }
    return .none;
}

/// Line-splitting writer: --json JSONL in, ACP session/update out.
pub const EventSink = struct {
    out: *Io.Writer,
    session_id: *[]const u8,
    saw_text: *bool,
    pending: std.ArrayList(u8),
    gpa: Allocator,
    next_tool: u32 = 0,
    last_id: [64]u8 = @splat(0),
    buf: [4096]u8 = undefined,
    writer: Io.Writer = undefined,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    pub fn init(self: *EventSink, gpa: Allocator, out: *Io.Writer, session_id: *[]const u8, saw_text: *bool) void {
        self.* = .{
            .out = out,
            .session_id = session_id,
            .saw_text = saw_text,
            .pending = .empty,
            .gpa = gpa,
            .writer = .{ .vtable = &vtable, .buffer = &self.buf, .end = 0 },
        };
    }

    pub fn deinit(self: *EventSink) void {
        self.writer.flush() catch {};
        if (self.pending.items.len > 0) self.translateLine(self.pending.items);
        self.pending.deinit(self.gpa);
    }

    fn feed(self: *EventSink, bytes: []const u8) void {
        self.pending.appendSlice(self.gpa, bytes) catch return;
        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
            const line = self.pending.items[0..nl];
            self.translateLine(line);
            std.mem.copyForwards(u8, self.pending.items, self.pending.items[nl + 1 ..]);
            self.pending.shrinkRetainingCapacity(self.pending.items.len - (nl + 1));
        }
    }

    fn translateLine(self: *EventSink, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        var parsed = std.json.parseFromSlice(Value, self.gpa, trimmed, .{}) catch return;
        defer parsed.deinit();
        const kind = translateEvent(self.out, self.session_id.*, parsed.value, &self.last_id, &self.next_tool) catch return;
        if (kind == .text) self.saw_text.* = true;
        self.out.flush() catch {};
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *EventSink = @alignCast(@fieldParentPtr("writer", w));
        self.feed(w.buffer[0..w.end]);
        w.end = 0;
        const slices = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var written: usize = 0;
        for (slices) |b| {
            self.feed(b);
            written += b.len;
        }
        var i: usize = 0;
        while (i < splat) : (i += 1) self.feed(pattern);
        written += pattern.len * splat;
        return written;
    }
};

const testing = std.testing;

test "kindFor maps catalog tools onto ACP kinds" {
    try testing.expectEqualStrings("read", kindFor("read_file"));
    try testing.expectEqualStrings("edit", kindFor("edit_file"));
    try testing.expectEqualStrings("execute", kindFor("bash"));
    try testing.expectEqualStrings("fetch", kindFor("webfetch"));
    try testing.expectEqualStrings("think", kindFor("todo_write"));
    try testing.expectEqualStrings("other", kindFor("ask_user"));
}

test "translateEvent: reasoning and text become chunks" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const thought = try std.json.parseFromSlice(Value, a, "{\"type\":\"reasoning\",\"text\":\"look\"}", .{});
    defer thought.deinit();
    var id_buf: [64]u8 = @splat(0);
    var next: u32 = 0;
    try testing.expectEqual(.thought, try translateEvent(&w, "s1", thought.value, &id_buf, &next));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "agent_thought_chunk") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "look") != null);

    w = .fixed(&buf);
    const text = try std.json.parseFromSlice(Value, a, "{\"type\":\"text\",\"text\":\"hi\"}", .{});
    defer text.deinit();
    try testing.expectEqual(.text, try translateEvent(&w, "s1", text.value, &id_buf, &next));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "agent_message_chunk") != null);
}

test "translateEvent: tool_call then tool_result share a minted id" {
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const call = try std.json.parseFromSlice(Value, a, "{\"type\":\"tool_call\",\"name\":\"read_file\",\"input\":{\"path\":\"a.zig\"}}", .{});
    defer call.deinit();
    var id_buf: [64]u8 = @splat(0);
    var next: u32 = 0;
    try testing.expectEqual(.tool, try translateEvent(&w, "s1", call.value, &id_buf, &next));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"sessionUpdate\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "call-1") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"kind\":\"read\"") != null);

    w = .fixed(&buf);
    const result = try std.json.parseFromSlice(Value, a, "{\"type\":\"tool_result\",\"name\":\"read_file\",\"is_error\":false,\"text\":\"fn main\"}", .{});
    defer result.deinit();
    try testing.expectEqual(.tool, try translateEvent(&w, "s1", result.value, &id_buf, &next));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "tool_call_update") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "call-1") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "completed") != null);
}

test "EventSink translates a JSONL reasoning line through the writer" {
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var sid: []const u8 = "s1";
    var saw = false;
    var sink: EventSink = undefined;
    sink.init(testing.allocator, &w, &sid, &saw);
    defer sink.deinit();
    try sink.writer.writeAll("{\"type\":\"reasoning\",\"text\":\"hmm\"}\n");
    try sink.writer.flush();
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "agent_thought_chunk") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "hmm") != null);
    try testing.expect(!saw);
}
