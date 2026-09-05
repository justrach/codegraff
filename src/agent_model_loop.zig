//! Shared lexical loop stop for live delivery and buffered final responses.
//! No global cancellation flag: a local ModelLoop stop never cancels siblings
//! or borrows the user-interruption/reconnect paths.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const Value = std.json.Value;
const Kind = @import("provider.zig").Provider.Kind;
const Detector = @import("stream_repetition.zig").Detector;
const sink_mod = @import("engine_sink.zig");
const main_mod = @import("main.zig");
pub const marker = "stopped: model loop";

pub const Stream = struct {
    detector: Detector = .{},

    /// Parse only actual assistant text. Never inspect reasoning or tool args.
    /// Capture works even when the frontend doesn't paint streaming deltas.
    pub fn event(self: *Stream, agent: *Agent, payload: []const u8, paint: bool) !void {
        const parsed = std.json.parseFromSlice(Value, agent.gpa, payload, .{}) catch return;
        defer parsed.deinit();
        const text = delta(agent.provider.kind, parsed.value);
        if (text.len == 0) return;
        const enabled = !agent.compaction_request and agent.output_schema == null;
        const n = if (enabled) self.detector.feed(text) else text.len;
        try agent.partial_text.appendSlice(agent.arena, text[0..n]);
        if (!self.detector.stopped) return;
        if (paint) emitText(agent, text[0..n]);
        return error.ModelLoop;
    }
};

fn str(v: ?Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}
fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

pub fn delta(kind: Kind, value: Value) []const u8 {
    switch (kind) {
        .responses => return if (std.mem.eql(u8, str(get(value, "type")), "response.output_text.delta")) str(get(value, "delta")) else "",
        .anthropic => {
            if (!std.mem.eql(u8, str(get(value, "type")), "content_block_delta")) return "";
            const d = get(value, "delta") orelse return "";
            return if (std.mem.eql(u8, str(get(d, "type")), "text_delta")) str(get(d, "text")) else "";
        },
        .openai => {
            const choices = get(value, "choices") orelse return "";
            if (choices != .array or choices.array.items.len == 0) return "";
            const d = get(choices.array.items[0], "delta") orelse return "";
            return str(get(d, "content"));
        },
    }
}

pub fn emitText(agent: *Agent, text: []const u8) void {
    if (text.len == 0) return;
    if (agent.out == null) {
        if (main_mod.unattended and !main_mod.json_mode and !agent.sub) {
            if (main_mod.g_out) |w| {
                w.writeAll(text) catch {};
                w.flush() catch {};
                agent.streamed_text = true;
            }
        }
    } else {
        agent.streamed_text = true;
        sink_mod.forAgent(agent).emit(agent.io, .{ .text_delta = .{ .text = text } });
    }
}

/// Run before step delivery/history insertion. Includes non-streaming replies
/// and completion snapshots whose text was not present in live deltas.
pub fn checkResponse(agent: *Agent, root: std.json.ObjectMap) !void {
    if (agent.compaction_request or agent.output_schema != null) return;
    var detector: Detector = .{};
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(agent.gpa);
    switch (agent.provider.kind) {
        .openai => {
            const choices = root.get("choices") orelse return;
            if (choices != .array or choices.array.items.len == 0) return;
            const msg = get(choices.array.items[0], "message") orelse return;
            if (get(msg, "tool_calls") != null or get(msg, "function_call") != null) return;
            try text.appendSlice(agent.gpa, str(get(msg, "content")));
        },
        .anthropic, .responses => {
            const blocks = root.get(if (agent.provider.kind == .responses) "output" else "content") orelse return;
            if (blocks != .array) return;
            for (blocks.array.items) |block| {
                const ty = str(get(block, "type"));
                if (std.mem.eql(u8, ty, "tool_use") or std.mem.eql(u8, ty, "function_call")) return;
                if (std.mem.eql(u8, ty, "text")) try text.appendSlice(agent.gpa, str(get(block, "text")));
                if (std.mem.eql(u8, ty, "message")) {
                    const content = get(block, "content") orelse continue;
                    if (content != .array) continue;
                    for (content.array.items) |part| {
                        if (std.mem.eql(u8, str(get(part, "type")), "output_text"))
                            try text.appendSlice(agent.gpa, str(get(part, "text")));
                    }
                }
            }
        },
    }
    const n = detector.feed(text.items);
    detector.finish();
    if (!detector.stopped) return;
    agent.partial_text.clearRetainingCapacity();
    try agent.partial_text.appendSlice(agent.arena, text.items[0..n]);
    if (agent.codex_ws) |c| c.dead = true;
    agent.closeCodexWs();
    return error.ModelLoop;
}

/// runTurn catches ModelLoop and returns this directly, BEFORE any semantic
/// completion guard can reopen the turn. Save one assistant message and emit
/// only unseen text plus a short marker. The ordinary final event remains the
/// caller's responsibility, exactly as for an ordinary completed answer.
pub fn finishError(agent: *Agent, err: anyerror) ![]const u8 {
    if (err != error.ModelLoop) return err;
    return finish(agent);
}

pub fn finish(agent: *Agent) ![]const u8 {
    const partial = std.mem.trim(u8, agent.partial_text.items, " \t\r\n");
    const final = try std.fmt.allocPrint(agent.arena, "{s}\n\n{s}", .{ partial, marker });
    try agent.messages.append(try @import("messages.zig").textMessage(agent.arena, "assistant", final));
    if (!agent.sub) {
        if (!agent.streamed_text) emitText(agent, partial);
        emitText(agent, "\n\nstopped: model loop\n");
        sink_mod.forAgent(agent).emit(agent.io, .{ .stream_complete = .{ .streamed_text = agent.streamed_text } });
    }
    if (agent.tracer) |tr| tr.note("turn", marker);
    return final;
}

test "model loop wire extraction excludes tool arguments and reasoning" {
    const cases = [_]struct { kind: Kind, raw: []const u8, expected: []const u8 }{
        .{ .kind = .responses, .raw = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}", .expected = "hello" },
        .{ .kind = .responses, .raw = "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"hello\"}", .expected = "" },
        .{ .kind = .anthropic, .raw = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}", .expected = "hello" },
        .{ .kind = .anthropic, .raw = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"hello\"}}", .expected = "" },
        .{ .kind = .openai, .raw = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}", .expected = "hello" },
        .{ .kind = .openai, .raw = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"hello\"}}]}", .expected = "" },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, case.raw, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.expected, delta(case.kind, parsed.value));
    }
}

test {
    _ = @import("stream_repetition.zig");
    _ = @import("agent_model_loop_test.zig");
    _ = @import("agent_model_loop_transport_test.zig");
}
