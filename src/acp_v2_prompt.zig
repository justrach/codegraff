//! ACP v2 `session/prompt`: acceptance means insertion. The request is
//! answered with the user message's `messageId` before the turn runs; the
//! turn's outcome travels as `state_update` (running → idle + stopReason).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");
const proto = @import("acp_protocol.zig");
const acp_workspace = @import("acp_workspace.zig");
const util = @import("util.zig");
const v2 = @import("acp_v2.zig");

pub fn promptTurn(d: *engine.Dispatch, arena: Allocator, w: *Io.Writer, req: proto.Request) !void {
    const obj: ?std.json.ObjectMap = if (req.params) |p| (if (p == .object) p.object else null) else null;
    const sid = blk: {
        if (obj) |o| if (util.strFieldObj(o, "sessionId")) |s| break :blk s;
        break :blk d.session_id orelse "";
    };
    const prompt = if (obj) |o| o.get("prompt") else null;
    if (d.bind_session) |bind| bind(d.ctx, sid);
    // Everything that can reject the prompt happens before insertion, where a
    // JSON-RPC error is still the right answer.
    const config_before = engine.configOptions(d, arena) catch |err|
        return engine.respondError(w, req, proto.err_internal, @errorName(err));
    const workspace_before = acp_workspace.snapshot(d.workspace, arena);
    const text = try proto.flattenPrompt(arena, prompt);
    var id_buf: [48]u8 = undefined;
    const message_id = v2.mint(&id_buf, "user");
    if (req.id != null) try proto.writeResult(w, req.id, .{ .messageId = message_id });
    try v2.writeUserMessage(w, sid, message_id, prompt, text);
    try v2.writeRunning(w, sid);
    try w.flush();

    const outcome = run(d, arena, w, sid, text, prompt);
    engine.emitConfigChange(d, arena, w, sid, config_before) catch {};
    acp_workspace.emitChange(d.workspace, arena, w, sid, workspace_before) catch {};
    try engine.emitMeter(d, w, sid);
    switch (outcome) {
        .stop => |stop| try v2.writeIdle(w, sid, stop),
        .failed => |message| try v2.writeFailed(w, sid, message),
    }
}

const Outcome = union(enum) { stop: []const u8, failed: []const u8 };

fn run(d: *engine.Dispatch, arena: Allocator, w: *Io.Writer, sid: []const u8, text: []const u8, prompt: ?std.json.Value) Outcome {
    if (d.slash) |slash| {
        const reply = slash(d.ctx, arena, text) catch |err| return failure(d, err);
        if (reply) |plain| {
            if (plain.len > 0) proto.writeSessionUpdate(w, sid, plain) catch |err| return failure(d, err);
            return .{ .stop = "end_turn" };
        }
    }
    if (d.after_user) |after| after(d.ctx, arena, text, prompt);
    const final = d.turn(d.ctx, arena, text) catch |err| return failure(d, err);
    if (final.len > 0) proto.writeSessionUpdate(w, sid, final) catch |err| return failure(d, err);
    const extra = if (engine.extra_cancelled) |f| f() else false;
    return .{ .stop = if (engine.cancel_flag.load(.acquire) or extra) "cancelled" else "end_turn" };
}

fn failure(d: *engine.Dispatch, err: anyerror) Outcome {
    if (err == error.Interrupted or err == error.Canceled) return .{ .stop = "cancelled" };
    if (err == error.RunBudgetExhausted) return .{ .stop = "max_turn_requests" };
    return .{ .failed = if (d.error_message) |message| message(d.ctx, err) else @errorName(err) };
}

fn echoTurn(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

fn v2Session(d: *engine.Dispatch, a: Allocator, w: *Io.Writer) !void {
    v2.gate = true;
    try engine.handleLine(d, a, w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":2,\"capabilities\":{},\"info\":{\"name\":\"t\",\"version\":\"1\"}}}");
    try engine.handleLine(d, a, w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\",\"mcpServers\":[]}}");
}

test "v2 prompt: messageId ack, user_message, running, chunks, idle end_turn" {
    defer v2.resetForTest();
    const was = engine.cancel_flag.swap(false, .acq_rel);
    defer engine.cancel_flag.store(was, .release);
    const extra = engine.extra_cancelled;
    engine.extra_cancelled = null;
    defer engine.extra_cancelled = extra;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var d: engine.Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    try v2Session(&d, a, &out.writer);
    const init = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, init, "\"protocolVersion\":2,\"capabilities\"") != null);
    try std.testing.expect(v2.on());
    out.clearRetainingCapacity();
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"acp-0-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"ping\"}]}}");
    const bytes = out.writer.buffered();
    const ack = std.mem.indexOf(u8, bytes, "\"id\":3,\"result\":{\"messageId\":\"msg_user_") orelse return error.MissingAck;
    const user = std.mem.indexOf(u8, bytes, "\"sessionUpdate\":\"user_message\"") orelse return error.MissingUserMessage;
    const running = std.mem.indexOf(u8, bytes, "\"state\":\"running\"") orelse return error.MissingRunning;
    const chunk = std.mem.indexOf(u8, bytes, "\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":\"msg_agent_") orelse return error.MissingChunk;
    const idle = std.mem.indexOf(u8, bytes, "\"state\":\"idle\",\"stopReason\":\"end_turn\"") orelse return error.MissingIdle;
    try std.testing.expect(ack < user and user < running and running < chunk and chunk < idle);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"text\":\"echo:ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "stopReason\":\"end_turn\"}}") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\"id\":3"));
}

test "v2 prompt: a failed turn is already accepted, so it idles with _error" {
    defer v2.resetForTest();
    const Failing = struct {
        fn turn(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            return error.ApiError;
        }
    };
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var d: engine.Dispatch = .{ .turn = Failing.turn, .ctx = undefined };
    try v2Session(&d, a, &out.writer);
    out.clearRetainingCapacity();
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"acp-0-1\",\"prompt\":\"x\"}}");
    const bytes = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"stopReason\":\"_error\",\"_meta\":{\"graff/error\":\"ApiError\"}") != null);
}

test "v1 prompt shape is untouched when the gate is closed" {
    defer v2.resetForTest();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var d: engine.Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    v2.gate = false;
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":2}}");
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}");
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"prompt\":\"x\"}}");
    const bytes = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"protocolVersion\":1,\"agentCapabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "messageId") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "state_update") == null);
}
