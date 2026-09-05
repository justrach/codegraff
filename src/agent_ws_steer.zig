//! GPT-6 Astra mid-turn steering over Responses WebSocket (`response.steer`).
//!
//! GPT-5.6 and earlier do not support this. After `response.created`, a follow-up
//! typed while the turn is live is sent as `{type:response.steer, previous_response_id, input}`
//! instead of waiting for the turn to finish. The original response may end
//! `incomplete` with `reason: steered`; keep reading for the successor.
//! Queued steer exists only on this socket — a disconnect drops it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const ws = @import("ws.zig");
const main_mod = @import("main.zig");
const repl_glue = @import("repl_glue.zig");
const isStreamEnd = @import("agent_stream.zig").isStreamEnd;

pub fn modelSupports(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-6");
}

pub const Session = struct {
    live_id: []const u8 = "",
    successor_id: []const u8 = "",
    awaiting_successor: bool = false,
};

fn responseId(arena: Allocator, frame: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(Value, arena, frame, .{ .allocate = .alloc_always }) catch return "";
    if (v != .object) return "";
    const resp = v.object.get("response") orelse return "";
    if (resp != .object) return "";
    const id = resp.object.get("id") orelse return "";
    return if (id == .string) id.string else "";
}

fn incompleteSteered(arena: Allocator, frame: []const u8) bool {
    const v = std.json.parseFromSliceLeaky(Value, arena, frame, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    const t = v.object.get("type") orelse return false;
    if (t != .string or !std.mem.eql(u8, t.string, "response.incomplete")) return false;
    const resp = v.object.get("response") orelse return false;
    if (resp != .object) return false;
    const details = resp.object.get("incomplete_details") orelse return false;
    if (details != .object) return false;
    const reason = details.object.get("reason") orelse return false;
    return reason == .string and std.mem.eql(u8, reason.string, "steered");
}

pub fn noteFrame(arena: Allocator, st: *Session, frame: []const u8) void {
    const ty = blk: {
        const v = std.json.parseFromSliceLeaky(Value, arena, frame, .{ .allocate = .alloc_always }) catch return;
        if (v != .object) return;
        const t = v.object.get("type") orelse return;
        break :blk if (t == .string) t.string else "";
    };
    if (std.mem.eql(u8, ty, "response.created")) {
        const id = responseId(arena, frame);
        if (id.len == 0) return;
        if (st.live_id.len == 0) {
            st.live_id = id;
        } else if (!std.mem.eql(u8, id, st.live_id)) {
            st.successor_id = id;
        }
        return;
    }
    if (std.mem.eql(u8, ty, "response.steer.accepted") or std.mem.eql(u8, ty, "response.steer.pending")) {
        st.awaiting_successor = true;
        return;
    }
    if (incompleteSteered(arena, frame)) {
        st.awaiting_successor = true;
    }
}

pub fn shouldStop(arena: Allocator, st: *const Session, kind: anytype, sse_line: []const u8, frame: []const u8) bool {
    if (incompleteSteered(arena, frame)) return false;
    if (!isStreamEnd(arena, kind, sse_line)) return false;
    if (!st.awaiting_successor) return true;
    const id = responseId(arena, frame);
    if (st.successor_id.len > 0 and std.mem.eql(u8, id, st.successor_id)) return true;
    const ty = blk: {
        const v = std.json.parseFromSliceLeaky(Value, arena, frame, .{ .allocate = .alloc_always }) catch break :blk "";
        if (v != .object) break :blk "";
        const t = v.object.get("type") orelse break :blk "";
        break :blk if (t == .string) t.string else "";
    };
    if (std.mem.eql(u8, ty, "response.failed")) return true;
    // Original completed/failed while a successor is still due — keep reading.
    return std.mem.eql(u8, ty, "response.failed");
}

pub fn buildSteerFrame(gpa: Allocator, response_id: []const u8, input: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("type");
    try s.write("response.steer");
    try s.objectField("previous_response_id");
    try s.write(response_id);
    try s.objectField("input");
    try s.write(input);
    try s.endObject();
    return aw.toOwnedSlice();
}

fn flushOne(self: anytype, client: *ws.WsClient, st: *Session, poll_stdin: bool) !void {
    if (st.live_id.len == 0) return;
    const entry = repl_glue.popSteer() orelse return;
    if (entry.force or entry.text.len == 0) {
        if (entry.text.len > 0) self.gpa.free(entry.text);
        return;
    }
    const frame = buildSteerFrame(self.gpa, st.live_id, entry.text) catch {
        self.gpa.free(entry.text);
        return;
    };
    defer self.gpa.free(frame);
    self.gpa.free(entry.text);
    _ = poll_stdin;
    client.sendText(frame) catch return;
    st.awaiting_successor = true;
}

/// Drive one inbound WS frame. Returns true when this turn's stream is done.
pub fn tick(self: anytype, client: *ws.WsClient, frame: []const u8, poll_stdin: bool, st: *Session) !bool {
    const arena = self.arena;
    const sse = try std.fmt.allocPrint(arena, "data: {s}", .{frame});
    if (!modelSupports(self.provider.model)) {
        return isStreamEnd(arena, self.provider.kind, sse);
    }
    noteFrame(arena, st, frame);
    try flushOne(self, client, st, poll_stdin);
    return shouldStop(arena, st, self.provider.kind, sse, frame);
}

test "modelSupports is gpt-6 only" {
    try std.testing.expect(modelSupports("gpt-6-astra"));
    try std.testing.expect(modelSupports("gpt-6"));
    try std.testing.expect(!modelSupports("gpt-5.6-sol"));
    try std.testing.expect(!modelSupports("gpt-5.6"));
}

test "buildSteerFrame is type + previous_response_id + input" {
    const gpa = std.testing.allocator;
    const frame = try buildSteerFrame(gpa, "resp_1", "keep it small");
    defer gpa.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"response.steer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"previous_response_id\":\"resp_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"input\":\"keep it small\"") != null);
}

test "steered incomplete is not end of turn; successor completed is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var st: Session = .{};
    noteFrame(a, &st, "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}");
    try std.testing.expectEqualStrings("resp_1", st.live_id);
    const inc = "{\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"incomplete_details\":{\"reason\":\"steered\"}}}";
    noteFrame(a, &st, inc);
    try std.testing.expect(st.awaiting_successor);
    const Kind = @import("provider.zig").Provider.Kind;
    try std.testing.expect(!shouldStop(a, &st, Kind.responses, "data: " ++ inc, inc));
    noteFrame(a, &st, "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_2\"}}");
    try std.testing.expectEqualStrings("resp_2", st.successor_id);
    const done = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\"}}";
    try std.testing.expect(shouldStop(a, &st, Kind.responses, "data: " ++ done, done));
}
