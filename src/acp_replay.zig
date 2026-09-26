//! Project saved provider history onto ACP's user-visible replay stream.
//! This never invokes a tool: orphaned calls become failed historical rows.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const proto = @import("acp_protocol.zig");
const util = @import("util.zig");
const session_peer = @import("session_peer.zig");
const v2 = @import("acp_v2.zig");

const Call = struct { id: []const u8, finished: bool = false };

fn field(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return util.strFieldObj(obj, key);
}

fn visibleText(arena: Allocator, value: Value) ![]const u8 {
    if (value == .string) return value.string;
    if (value == .object) {
        const o = value.object;
        if (field(o, "text")) |text| return text;
        if (o.get("content")) |content| return visibleText(arena, content);
        return "";
    }
    if (value != .array) return "";
    var result: std.ArrayList(u8) = .empty;
    for (value.array.items) |part| {
        const text = try visibleText(arena, part);
        if (text.len == 0) continue;
        if (result.items.len > 0) try result.append(arena, '\n');
        try result.appendSlice(arena, text);
    }
    return result.items;
}

fn message(w: *Io.Writer, sid: []const u8, role: []const u8, text: []const u8) !void {
    if (text.len == 0) return;
    if (v2.on()) {
        // Full-content upserts need no `content: []` reset before them.
        var id: [48]u8 = undefined;
        const user = std.mem.eql(u8, role, "user");
        return proto.writeNotification(w, "session/update", .{ .sessionId = sid, .update = .{
            .sessionUpdate = if (user) "user_message" else "agent_message",
            .messageId = v2.mint(&id, if (user) "user" else "agent"),
            .content = .{.{ .type = "text", .text = text }},
        } });
    }
    try proto.writeNotification(w, "session/update", .{
        .sessionId = sid,
        .update = .{
            .sessionUpdate = if (std.mem.eql(u8, role, "user")) "user_message_chunk" else "agent_message_chunk",
            .content = .{ .type = "text", .text = text },
        },
    });
}

fn beginCall(arena: Allocator, w: *Io.Writer, sid: []const u8, calls: *std.ArrayList(Call), id: []const u8, name: []const u8) !void {
    for (calls.items) |c| if (std.mem.eql(u8, c.id, id)) return;
    try calls.append(arena, .{ .id = id });
    try proto.writeNotification(w, "session/update", .{
        .sessionId = sid,
        .update = .{
            .sessionUpdate = if (v2.on()) "tool_call_update" else "tool_call",
            .toolCallId = id,
            .title = name,
            .kind = "other",
            .status = "in_progress",
        },
    });
}

fn finishCall(arena: Allocator, w: *Io.Writer, sid: []const u8, calls: *std.ArrayList(Call), id: []const u8, output: Value, failed: bool) !void {
    try beginCall(arena, w, sid, calls, id, "Tool result");
    for (calls.items) |*c| if (std.mem.eql(u8, c.id, id)) {
        c.finished = true;
        break;
    };
    const text = try visibleText(arena, output);
    if (text.len > 0) {
        try proto.writeNotification(w, "session/update", .{
            .sessionId = sid,
            .update = .{
                .sessionUpdate = "tool_call_update",
                .toolCallId = id,
                .status = if (failed) "failed" else "completed",
                .content = .{.{ .type = "content", .content = .{ .type = "text", .text = text } }},
            },
        });
    } else {
        try proto.writeNotification(w, "session/update", .{
            .sessionId = sid,
            .update = .{ .sessionUpdate = "tool_call_update", .toolCallId = id, .status = if (failed) "failed" else "completed" },
        });
    }
}

fn isError(obj: std.json.ObjectMap) bool {
    const v = obj.get("is_error") orelse obj.get("isError") orelse return false;
    return v == .bool and v.bool;
}

fn resultFailed(obj: std.json.ObjectMap, output: Value) bool {
    if (isError(obj)) return true;
    // OpenAI Chat has no error bit; the harness persists failed tool results
    // with this exact prefix. Responses output has no lossless status field.
    return output == .string and std.mem.startsWith(u8, output.string, "[error] ");
}

fn replayPart(arena: Allocator, w: *Io.Writer, sid: []const u8, calls: *std.ArrayList(Call), role: []const u8, part: Value) !void {
    if (part != .object) {
        if (part == .string) try message(w, sid, role, part.string);
        return;
    }
    const obj = part.object;
    const typ = field(obj, "type") orelse "";
    if (std.mem.eql(u8, typ, "tool_use") or std.mem.eql(u8, typ, "function_call")) {
        const id = field(obj, "id") orelse field(obj, "call_id") orelse return;
        try beginCall(arena, w, sid, calls, id, field(obj, "name") orelse "Tool call");
        return;
    }
    if (std.mem.eql(u8, typ, "tool_result") or std.mem.eql(u8, typ, "function_call_output")) {
        const id = field(obj, "tool_use_id") orelse field(obj, "call_id") orelse return;
        const output = obj.get("content") orelse obj.get("output") orelse .null;
        try finishCall(arena, w, sid, calls, id, output, resultFailed(obj, output));
        return;
    }
    if (std.mem.eql(u8, typ, "text") or std.mem.eql(u8, typ, "input_text") or std.mem.eql(u8, typ, "output_text")) {
        if (field(obj, "text")) |text| try message(w, sid, role, text);
    }
}

/// Replay the persisted conversation in order, preserving human/assistant
/// roles and completed/failed tool evidence across Anthropic, OpenAI Chat,
/// and Responses histories. Opaque reasoning and provider metadata stay out.
pub fn replay(arena: Allocator, w: *Io.Writer, sid: []const u8, messages: []const Value) !void {
    var calls: std.ArrayList(Call) = .empty;
    for (messages) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const typ = field(obj, "type") orelse "";
        if (std.mem.eql(u8, typ, "function_call") or std.mem.eql(u8, typ, "function_call_output")) {
            try replayPart(arena, w, sid, &calls, "assistant", item);
            continue;
        }
        const role = field(obj, "role") orelse continue;
        if (std.mem.eql(u8, role, "user") and !session_peer.isHumanUserTurn(item)) continue;
        if (std.mem.eql(u8, role, "tool")) {
            const id = field(obj, "tool_call_id") orelse continue;
            const output = obj.get("content") orelse .null;
            try finishCall(arena, w, sid, &calls, id, output, resultFailed(obj, output));
            continue;
        }
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) continue;
        if (obj.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |part| try replayPart(arena, w, sid, &calls, role, part);
            } else try replayPart(arena, w, sid, &calls, role, content);
        }
        if (obj.get("tool_calls")) |tool_calls| if (tool_calls == .array) {
            for (tool_calls.array.items) |call| {
                if (call != .object) continue;
                const id = field(call.object, "id") orelse continue;
                const function = call.object.get("function") orelse .null;
                const name = if (function == .object) field(function.object, "name") orelse "Tool call" else "Tool call";
                try beginCall(arena, w, sid, &calls, id, name);
            }
        };
    }
    // A saved tool invocation without a result is historical unfinished work.
    // It must never appear newly running or as a successful recovered job.
    for (calls.items) |call| if (!call.finished) {
        try proto.writeNotification(w, "session/update", .{
            .sessionId = sid,
            .update = .{
                .sessionUpdate = "tool_call_update",
                .toolCallId = call.id,
                .status = "failed",
                .content = .{.{ .type = "content", .content = .{ .type = "text", .text = "Interrupted before a saved result was available." } }},
            },
        });
    };
}

test "ACP load replay keeps roles, tool results, failures, and orphan state" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const saved = try std.json.parseFromSliceLeaky(Value, arena,
        \\[{"role":"user","content":"Please check"},
        \\ {"role":"assistant","content":[{"type":"text","text":"Running"},{"type":"tool_use","id":"ok","name":"shell"}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"ok","content":"done"}]},
        \\ {"role":"assistant","tool_calls":[{"id":"bad","function":{"name":"edit_file"}}]},
        \\ {"role":"tool","tool_call_id":"bad","content":"[error] permission denied"},
        \\ {"type":"function_call","call_id":"orphan","name":"shell"},
        \\ {"role":"assistant","content":"Report"}]
    , .{});
    var out: Io.Writer.Allocating = .init(arena);
    try replay(arena, &out.writer, "saved", saved.array.items);
    const bytes = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"sessionUpdate\":\"user_message_chunk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"text\":\"Please check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"text\":\"Report\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"toolCallId\":\"ok\",\"status\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"toolCallId\":\"bad\",\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"toolCallId\":\"orphan\",\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"toolCallId\":\"orphan\",\"status\":\"completed\"") == null);
}
