//! Every announced ACP tool row gets exactly one terminal status (#1600).
//!
//! The engine closes an ordinary call with `tool_result` (the terminal update)
//! and then `tool_call_finished` (timing only). Meta tools (`peer_message`,
//! `load_tool_schemas`, `todo_write`, …) keep their result off the durable
//! wire, so their `tool_call_finished` is the only end they get. The stream
//! remembers which ids a result already closed: a finish for any other id
//! sends the completed/failed status itself, and a finish after a result
//! sends nothing (no duplicate, #1288).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const util = @import("util.zig");

/// The ids a `tool_result` closed recently. A ring: a finish follows its
/// call's result within the same batch, so a few dozen ids cover any batch.
pub const Resolved = struct {
    ids: [cap][64]u8 = undefined,
    lens: [cap]u8 = @splat(0),
    next: usize = 0,

    const cap = 64;

    pub fn add(self: *Resolved, id: []const u8) void {
        const n = @min(id.len, 64);
        @memcpy(self.ids[self.next][0..n], id[0..n]);
        self.lens[self.next] = @intCast(n);
        self.next = (self.next + 1) % cap;
    }

    pub fn has(self: *const Resolved, id: []const u8) bool {
        const n = @min(id.len, 64);
        for (self.ids, self.lens) |slot, len| {
            if (len != 0 and len == n and std.mem.eql(u8, slot[0..len], id[0..n])) return true;
        }
        return false;
    }
};

/// Handle `tool_call_finished`: write the terminal status unless a result
/// already closed this id. Returns whether it wrote one. Without tracking
/// (`resolved == null`) or an id it writes nothing, as before.
pub fn finish(w: *Io.Writer, session_id: []const u8, ev: std.json.ObjectMap, resolved: ?*Resolved) !bool {
    const r = resolved orelse return false;
    const id = util.strFieldObj(ev, "id") orelse return false;
    if (id.len == 0) return false;
    // attempt_completion never had a row (its payload is the final text).
    if (std.mem.eql(u8, util.strFieldObj(ev, "name") orelse "", "attempt_completion")) return false;
    if (r.has(id)) return false;
    const is_error = switch (ev.get("is_error") orelse .null) {
        .bool => |b| b,
        else => false,
    };
    try @import("acp_stream.zig").writeToolStatus(w, session_id, id, if (is_error) "failed" else "completed");
    r.add(id);
    return true;
}

const testing = std.testing;

fn object(a: std.mem.Allocator, json: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    return parsed.object;
}

test "finish closes a meta tool that never got a result, once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var resolved: Resolved = .{};
    const ev = try object(a, "{\"type\":\"tool_call_finished\",\"id\":\"pm1\",\"name\":\"peer_message\",\"is_error\":false,\"ms\":3}");
    try testing.expect(try finish(&w, "s1", ev, &resolved));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"toolCallId\":\"pm1\"") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"status\":\"completed\"") != null);
    // A repeated finish writes nothing more.
    const before = w.buffered().len;
    try testing.expect(!try finish(&w, "s1", ev, &resolved));
    try testing.expectEqual(before, w.buffered().len);
}

test "finish reports a failed meta tool as failed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var resolved: Resolved = .{};
    const ev = try object(arena.allocator(), "{\"type\":\"tool_call_finished\",\"id\":\"ld1\",\"name\":\"load_tool_schemas\",\"is_error\":true,\"ms\":1}");
    try testing.expect(try finish(&w, "s1", ev, &resolved));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"status\":\"failed\"") != null);
}

test "finish after a result, without an id, untracked, or for attempt_completion writes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var resolved: Resolved = .{};
    resolved.add("b1");
    const after_result = try object(a, "{\"type\":\"tool_call_finished\",\"id\":\"b1\",\"name\":\"bash\",\"is_error\":false}");
    try testing.expect(!try finish(&w, "s1", after_result, &resolved));
    const no_id = try object(a, "{\"type\":\"tool_call_finished\",\"name\":\"bash\",\"is_error\":false}");
    try testing.expect(!try finish(&w, "s1", no_id, &resolved));
    const fresh = try object(a, "{\"type\":\"tool_call_finished\",\"id\":\"t1\",\"name\":\"todo_write\"}");
    try testing.expect(!try finish(&w, "s1", fresh, null));
    const answer = try object(a, "{\"type\":\"tool_call_finished\",\"id\":\"ac\",\"name\":\"attempt_completion\"}");
    try testing.expect(!try finish(&w, "s1", answer, &resolved));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "the ring forgets the oldest ids" {
    var resolved: Resolved = .{};
    var tmp: [16]u8 = undefined;
    for (0..Resolved.cap + 1) |i| resolved.add(try std.fmt.bufPrint(&tmp, "id-{d}", .{i}));
    try testing.expect(!resolved.has("id-0"));
    try testing.expect(resolved.has("id-1"));
    try testing.expect(resolved.has(try std.fmt.bufPrint(&tmp, "id-{d}", .{Resolved.cap})));
}

test "EventSink: every announced id ends once, meta tools included (#1600)" {
    const stream = @import("acp_stream.zig");
    var buf: [16384]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var sid: []const u8 = "s1";
    var saw = false;
    var sink: stream.EventSink = undefined;
    sink.init(testing.allocator, &w, &sid, &saw);
    defer sink.deinit();
    // An ordinary tool: result, then finish. A meta tool: finish only (its
    // result stays off the durable wire). A failed meta tool. The answer.
    for ([_][]const u8{
        "{\"type\":\"tool_call\",\"id\":\"b1\",\"name\":\"bash\",\"input\":{\"command\":\"ls\"}}",
        "{\"type\":\"tool_result\",\"id\":\"b1\",\"name\":\"bash\",\"is_error\":false,\"text\":\"a\"}",
        "{\"type\":\"tool_call_finished\",\"id\":\"b1\",\"name\":\"bash\",\"is_error\":false,\"ms\":2}",
        "{\"type\":\"tool_call\",\"id\":\"pm1\",\"name\":\"peer_message\",\"input\":{}}",
        "{\"type\":\"tool_call_finished\",\"id\":\"pm1\",\"name\":\"peer_message\",\"is_error\":false,\"ms\":1}",
        "{\"type\":\"tool_call\",\"id\":\"td1\",\"name\":\"todo_write\",\"input\":{}}",
        "{\"type\":\"tool_call_finished\",\"id\":\"td1\",\"name\":\"todo_write\",\"is_error\":true,\"ms\":1}",
        "{\"type\":\"tool_call\",\"id\":\"ac\",\"name\":\"attempt_completion\",\"input\":{}}",
        "{\"type\":\"tool_call_finished\",\"id\":\"ac\",\"name\":\"attempt_completion\",\"is_error\":false,\"ms\":1}",
    }) |line| {
        try sink.writer.writeAll(line);
        try sink.writer.writeAll("\n");
    }
    try sink.writer.flush();
    const out = w.buffered();
    const terminal_for = struct {
        fn count(text: []const u8, id: []const u8, status: []const u8) usize {
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| {
                var key: [80]u8 = undefined;
                const want = std.fmt.bufPrint(&key, "\"toolCallId\":\"{s}\"", .{id}) catch unreachable;
                if (std.mem.indexOf(u8, line, want) != null and std.mem.indexOf(u8, line, status) != null) n += 1;
            }
            return n;
        }
    };
    try testing.expectEqual(@as(usize, 1), terminal_for.count(out, "b1", "\"status\":\"completed\""));
    try testing.expectEqual(@as(usize, 1), terminal_for.count(out, "pm1", "\"status\":\"completed\""));
    try testing.expectEqual(@as(usize, 1), terminal_for.count(out, "td1", "\"status\":\"failed\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"toolCallId\":\"ac\"") == null);
}

test "EventSink: a yield_turn handoff stays delivered past its tool's end (#1615)" {
    const stream = @import("acp_stream.zig");
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var sid: []const u8 = "s1";
    var saw = false;
    var sink: stream.EventSink = undefined;
    sink.init(testing.allocator, &w, &sid, &saw);
    defer sink.deinit();
    // tool start -> handoff text -> terminal status: the handoff is the answer
    // already on the wire, so the turn's returned handoff must not repeat it.
    for ([_][]const u8{
        "{\"type\":\"tool_call\",\"id\":\"y1\",\"name\":\"yield_turn\",\"input\":{\"message\":\"HANDOFF\"}}",
        "{\"type\":\"text\",\"text\":\"HANDOFF\"}",
        "{\"type\":\"tool_call_finished\",\"id\":\"y1\",\"name\":\"yield_turn\",\"is_error\":false,\"ms\":1}",
    }) |line| {
        try sink.writer.writeAll(line);
        try sink.writer.writeAll("\n");
    }
    try sink.writer.flush();
    try testing.expect(saw);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"status\":\"completed\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "\"text\":\"HANDOFF\""));

    // A preamble followed by a tool still leaves the real answer to come.
    for ([_][]const u8{
        "{\"type\":\"text\",\"text\":\"Let me check.\"}",
        "{\"type\":\"tool_call\",\"id\":\"r1\",\"name\":\"read_file\",\"input\":{\"path\":\"a\"}}",
        "{\"type\":\"tool_result\",\"id\":\"r1\",\"name\":\"read_file\",\"is_error\":false,\"text\":\"x\"}",
        "{\"type\":\"tool_call_finished\",\"id\":\"r1\",\"name\":\"read_file\",\"is_error\":false,\"ms\":1}",
    }) |line| {
        try sink.writer.writeAll(line);
        try sink.writer.writeAll("\n");
    }
    try sink.writer.flush();
    try testing.expect(!saw);
}
