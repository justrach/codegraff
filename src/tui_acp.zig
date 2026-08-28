//! In-process ACP client for the fullscreen TUI (ADR 0041).
//!
//! Same initialize / session/new / prompt / cancel envelopes as Zed and
//! `apps/native`. Thought, tools, and answer text render from `session/update`.
//! No child `graff acp` — one Agent, one conversation.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const acp = @import("acp.zig");
const acp_engine = @import("acp_engine.zig");
const acp_stream = @import("acp_stream.zig");
const proto = @import("acp_protocol.zig");
const agent_mod = @import("agent.zig");
const engine_events = @import("engine_events.zig");
const engine_sink = @import("engine_sink.zig");
const label = @import("agent_tool_label.zig");
const main_mod = @import("main.zig");
const obs = @import("obs.zig");
const repl = @import("repl.zig");
const repl_glue = @import("repl_glue.zig");
const telemetry = @import("telemetry.zig");
const tui = @import("tui");
const tui_sink = @import("tui_sink.zig");
const util = @import("util.zig");

threadlocal var tls: ?*Session = null;

pub fn attach(s: *Session) void {
    tls = s;
}

pub fn detach() void {
    tls = null;
}

pub fn sessionId() ?[]const u8 {
    const s = tls orelse return null;
    return if (s.session_id.len == 0) null else s.session_id;
}

pub fn cancel() void {
    const s = tls orelse return;
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    acp.handleLine(&s.dispatch, arena_state.allocator(), &w, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\"}") catch {};
}

/// Maps one ACP `session/update` line onto the TUI stream / event queue.
pub const Apply = struct {
    queue: *tui.EventQueue,
    stream: *repl.StreamBuf,
    show_thinking: bool = false,
    reasoning_open: bool = false,
    last_title: [160]u8 = undefined,
    last_title_len: usize = 0,
};

pub fn applyBuffered(a: *Apply, gpa: Allocator, bytes: []const u8) void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| applyLine(a, gpa, line);
}

pub fn applyLine(a: *Apply, gpa: Allocator, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;
    var parsed = std.json.parseFromSlice(Value, gpa, trimmed, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method = util.strFieldObj(parsed.value.object, "method") orelse return;
    if (!std.mem.eql(u8, method, "session/update")) return;
    const params = parsed.value.object.get("params") orelse return;
    if (params != .object) return;
    const update = params.object.get("update") orelse return;
    if (update != .object) return;
    const kind = util.strFieldObj(update.object, "sessionUpdate") orelse return;
    if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
        const text = contentText(update.object) orelse return;
        if (text.len == 0 or !a.show_thinking) return;
        a.reasoning_open = true;
        a.stream.appendBytes(text);
        return;
    }
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        const text = contentText(update.object) orelse return;
        if (text.len == 0) return;
        if (a.reasoning_open) {
            a.reasoning_open = false;
            a.stream.appendBytes("\n");
        }
        a.stream.appendBytes(text);
        return;
    }
    if (std.mem.eql(u8, kind, "tool_call")) {
        const title = util.strFieldObj(update.object, "title") orelse "tool";
        const name = util.strFieldObj(update.object, "name") orelse title;
        rememberTitle(a, name);
        if (label.skipTranscript(name)) return;
        a.queue.push(.{ .tool_started = .{ .name = name, .detail = cap(title, 160) } });
        return;
    }
    if (std.mem.eql(u8, kind, "tool_call_update")) {
        if (tui.rawStream()) |raw| raw.len.store(0, .release);
        const title = a.last_title[0..a.last_title_len];
        if (title.len == 0 or label.skipTranscript(title)) return;
        const status = util.strFieldObj(update.object, "status") orelse "completed";
        const failed = std.mem.eql(u8, status, "failed");
        const text = updateText(update.object);
        a.queue.push(.{ .tool_finished = .{
            .name = title,
            .detail = cap(text, 80),
            .is_error = failed,
        } });
    }
}

fn contentText(update: std.json.ObjectMap) ?[]const u8 {
    const content = update.get("content") orelse return null;
    if (content != .object) return null;
    return util.strFieldObj(content.object, "text");
}

fn updateText(update: std.json.ObjectMap) []const u8 {
    const content = update.get("content") orelse return "";
    if (content != .array or content.array.items.len == 0) return "";
    const first = content.array.items[0];
    if (first != .object) return "";
    const inner = first.object.get("content") orelse return "";
    if (inner != .object) return "";
    return util.strFieldObj(inner.object, "text") orelse "";
}

fn rememberTitle(a: *Apply, title: []const u8) void {
    const n = @min(title.len, a.last_title.len);
    @memcpy(a.last_title[0..n], title[0..n]);
    a.last_title_len = n;
}

fn cap(s: []const u8, n: usize) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, s, '\n')) |i| s[0..i] else s;
    return line[0..@min(line.len, n)];
}

fn toolTitle(name: []const u8, input: Value) []const u8 {
    if (input == .object) {
        if (util.strFieldObj(input.object, "path")) |p| return p;
        if (util.strFieldObj(input.object, "command")) |c| return c;
        if (util.strFieldObj(input.object, "url")) |u| return u;
    }
    return name;
}

const Transcript = struct {
    gpa: Allocator,
    session_id: []const u8,
    apply: *Apply,
};

const transcript_vt: engine_sink.VTable = .{ .emit = transcriptEmit, .durable = false };

fn transcriptEmit(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const t: *Transcript = @ptrCast(@alignCast(ctx));
    var aw: Io.Writer.Allocating = .init(t.gpa);
    defer aw.deinit();
    writeUpdate(&aw.writer, t.session_id, ev.event) catch return;
    if (aw.writer.buffered().len == 0) return;
    applyBuffered(t.apply, t.gpa, aw.writer.buffered());
}

fn writeUpdate(w: *Io.Writer, session_id: []const u8, ev: engine_events.EngineEvent) !void {
    switch (ev) {
        .reasoning_delta => |d| try acp_stream.writeThought(w, session_id, d.text),
        .text_delta, .tool_arg_delta => |d| try acp_stream.writeMessage(w, session_id, d.text),
        .tool_call_announced => |c| {
            if (label.skipTranscript(c.name)) return;
            try proto.writeNotification(w, "session/update", .{
                .sessionId = session_id,
                .update = .{
                    .sessionUpdate = "tool_call",
                    .toolCallId = "call-1",
                    .title = toolTitle(c.name, c.input),
                    .kind = acp_stream.kindFor(c.name),
                    .status = "in_progress",
                    .rawInput = c.input,
                    .name = c.name,
                },
            });
        },
        .tool_result => |r| {
            if (label.skipTranscript(r.name)) return;
            try acp_stream.writeToolDone(w, session_id, "call-1", r.is_error, r.text);
        },
        .tool_rejected => |r| {
            if (label.skipTranscript(r.name)) return;
            try acp_stream.writeToolDone(w, session_id, "call-1", true, r.message);
        },
        else => {},
    }
}

const Fanout = struct {
    first: engine_sink.EngineSink,
    second: engine_sink.EngineSink,
};

const fan_vt: engine_sink.VTable = .{ .emit = fanEmit, .durable = false };

fn fanEmit(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const f: *Fanout = @ptrCast(@alignCast(ctx));
    f.first.vt.emit(f.first.ctx, ev);
    f.second.vt.emit(f.second.ctx, ev);
}

const Pending = struct {
    ctx: ?*anyopaque,
    gpa: Allocator,
    history: []const repl.Turn,
    params: repl.Params,
    stream: *repl.StreamBuf,
    result: ?[]const u8 = null,
};

pub const Session = struct {
    gpa: Allocator,
    dispatch: acp_engine.Dispatch = undefined,
    session_id_buf: [80]u8 = undefined,
    session_id: []const u8 = "",
    next_rpc: u32 = 1,
    pending: ?Pending = null,

    pub fn init(self: *Session, gpa: Allocator, seed: u64) void {
        self.* = .{
            .gpa = gpa,
            .dispatch = .{
                .turn = dispatchTurn,
                .ctx = @ptrCast(self),
                .seed = seed,
                .bind_session = bindSession,
            },
        };
    }

    pub fn ensure(self: *Session) void {
        if (self.session_id.len != 0) return;
        acp_engine.implementation_version = main_mod.harness_version;
        acp_engine.on_cancel = syncEsc;
        acp_engine.extra_cancelled = liveCancelled;
        var buf: [2048]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        acp.handleLine(&self.dispatch, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}") catch {};
        w = .fixed(&buf);
        acp.handleLine(&self.dispatch, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}") catch {};
        if (self.dispatch.session_id) |sid| bindSession(@ptrCast(self), sid);
    }
};

fn bindSession(ctx: *anyopaque, sid: []const u8) void {
    const s: *Session = @ptrCast(@alignCast(ctx));
    const n = @min(sid.len, s.session_id_buf.len);
    @memcpy(s.session_id_buf[0..n], sid[0..n]);
    s.session_id = s.session_id_buf[0..n];
}

fn syncEsc() void {
    agent_mod.Agent.esc_cancel.store(true, .release);
}

fn liveCancelled() bool {
    return agent_mod.Agent.esc_cancel.load(.acquire);
}

fn dispatchTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    _ = arena;
    _ = text;
    const s: *Session = @ptrCast(@alignCast(ctx));
    const p = &(s.pending orelse return "");
    p.result = repl_glue.replTurnCb(p.ctx, p.gpa, p.history, p.params, p.stream);
    return "";
}

fn liveStream(stream: *tui.StreamBuf) *repl.StreamBuf {
    comptime {
        if (@sizeOf(tui.StreamBuf) != @sizeOf(repl.StreamBuf) or
            @offsetOf(tui.StreamBuf, "buf") != @offsetOf(tui.StreamBuf, "buf") or
            @offsetOf(tui.StreamBuf, "len") != @offsetOf(repl.StreamBuf, "len"))
            @compileError("tui.StreamBuf and repl.StreamBuf must stay layout-identical");
    }
    return @ptrCast(stream);
}

fn promptJson(arena: Allocator, id: u32, session_id: []const u8, text: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/prompt\",\"params\":{{\"sessionId\":", .{id});
    try std.json.Stringify.value(session_id, .{}, &aw.writer);
    try aw.writer.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, &aw.writer);
    try aw.writer.writeAll("}]}}");
    return aw.writer.buffered();
}

/// A TUI model turn: ACP `session/prompt`, transcript from `session/update`.
pub fn turn(
    ctx: ?*anyopaque,
    gpa: Allocator,
    history: []const tui.Turn,
    params: tui.Params,
    stream: *tui.StreamBuf,
    events: *tui.EventQueue,
) ?[]const u8 {
    var turns = std.array_list.Managed(repl.Turn).init(gpa);
    defer {
        for (turns.items) |t| gpa.free(t.text);
        turns.deinit();
    }
    for (history) |t| {
        const text = gpa.dupe(u8, t.text) catch continue;
        turns.append(.{ .role = switch (t.role) {
            .user => .user,
            .assistant => .assistant,
        }, .text = text }) catch gpa.free(text);
    }
    var last_len: u32 = 0;
    const user_text: []const u8 = if (history.len > 0 and history[history.len - 1].role == .user) blk: {
        last_len = @intCast(@min(history[history.len - 1].text.len, std.math.maxInt(u32)));
        break :blk history[history.len - 1].text;
    } else "";
    const model = if (ctx) |p| @as(*repl_glue.ReplCtx, @ptrCast(@alignCast(p))).provider.model else "";
    obs.prompt(last_len, model);

    var session_storage: Session = undefined;
    const session = tls orelse blk: {
        session_storage.init(gpa, 0xac01);
        break :blk &session_storage;
    };
    session.ensure();

    const rstream = liveStream(stream);
    var apply: Apply = .{ .queue = events, .stream = rstream, .show_thinking = params.thinking };
    var transcript: Transcript = .{ .gpa = gpa, .session_id = session.session_id, .apply = &apply };
    var bridge: tui_sink.Bridge = .{
        .queue = events,
        .stream = rstream,
        .show_thinking = params.thinking,
        .acp_owns_transcript = true,
    };
    var fan: Fanout = .{
        .first = .{ .ctx = @ptrCast(&transcript), .vt = &transcript_vt },
        .second = tui_sink.forBridge(&bridge),
    };
    engine_sink.bindTurnSink(.{ .ctx = @ptrCast(&fan), .vt = &fan_vt });
    defer engine_sink.unbindTurnSink();

    acp_engine.cancel_flag.store(false, .release);
    session.pending = .{
        .ctx = ctx,
        .gpa = gpa,
        .history = turns.items,
        .params = .{
            .effort = @enumFromInt(@intFromEnum(params.effort)),
            .fast = params.fast,
            .thinking = params.thinking,
            .ultracode = params.ultracode,
            .mode = switch (params.mode) {
                .normal => .normal,
                .plan => .plan,
                .always_approve => .always_approve,
            },
            .strict = params.strict,
            .goal = params.goal,
        },
        .stream = rstream,
    };
    defer session.pending = null;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = promptJson(arena, session.next_rpc, session.session_id, user_text) catch {
        if (telemetry.g_telem) |t| t.countTurn() else obs.turn(.failed);
        return null;
    };
    session.next_rpc += 1;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    acp.handleLine(&session.dispatch, arena, &aw.writer, line) catch {
        obs.turn(.failed);
        return null;
    };
    applyBuffered(&apply, gpa, aw.writer.buffered());
    const result = if (session.pending) |p| p.result else null;
    if (result != null) {
        if (telemetry.g_telem) |t| t.countTurn() else obs.turn(.completed);
    } else obs.turn(.failed);
    return result;
}

fn echoTurn(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

test "applyLine: thought then text land on the live tail" {
    var q: tui.EventQueue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var buf: [128]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream, .show_thinking = true };
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"why\"}}}}");
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}}");
    const snap = stream.snapshot(std.testing.allocator) orelse return error.NoStream;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("why\nhi", snap);
}

test "applyLine: tool_call then tool_call_update become typed rows" {
    var q: tui.EventQueue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var buf: [32]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream };
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"name\":\"read_file\",\"title\":\"note.txt\",\"kind\":\"read\",\"status\":\"in_progress\"}}}");
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call_update\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"ok\\nmore\"}}]}}}");
    const evs = q.drain();
    defer q.free(evs);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqualStrings("read_file", evs[0].tool_started.name);
    try std.testing.expectEqualStrings("note.txt", evs[0].tool_started.detail);
    try std.testing.expectEqualStrings("ok", evs[1].tool_finished.detail);
    try std.testing.expect(!evs[1].tool_finished.is_error);
}

test "transcript sink: tool_call keeps the catalog name, title is the path" {
    var q: tui.EventQueue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var buf: [32]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream };
    var t: Transcript = .{ .gpa = std.testing.allocator, .session_id = "s1", .apply = &a };
    const sink: engine_sink.EngineSink = .{ .ctx = @ptrCast(&t), .vt = &transcript_vt };
    var input_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer input_state.deinit();
    const input = try std.json.parseFromSliceLeaky(Value, input_state.allocator(), "{\"path\":\"note.txt\"}", .{});
    sink.emit(undefined, .{ .tool_call_announced = .{ .name = "read_file", .input = input } });
    const evs = q.drain();
    defer q.free(evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualStrings("read_file", evs[0].tool_started.name);
    try std.testing.expectEqualStrings("note.txt", evs[0].tool_started.detail);
}

test "transcript sink: EngineEvent text becomes a session/update on the stream" {
    var q: tui.EventQueue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var buf: [64]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream };
    var t: Transcript = .{ .gpa = std.testing.allocator, .session_id = "s1", .apply = &a };
    const sink: engine_sink.EngineSink = .{ .ctx = @ptrCast(&t), .vt = &transcript_vt };
    sink.emit(undefined, .{ .text_delta = .{ .text = "hello" } });
    const snap = stream.snapshot(std.testing.allocator) orelse return error.NoStream;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("hello", snap);
}

test "session/prompt echo reaches the TUI stream as agent_message_chunk" {
    var q: tui.EventQueue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var buf: [64]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream };
    var s: Session = undefined;
    s.init(std.testing.allocator, 0xac01);
    s.dispatch.turn = echoTurn;
    s.ensure();
    try std.testing.expect(std.mem.startsWith(u8, s.session_id, "acp-"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = try promptJson(arena_state.allocator(), 3, s.session_id, "ping");
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try acp.handleLine(&s.dispatch, arena_state.allocator(), &aw.writer, line);
    applyBuffered(&a, std.testing.allocator, aw.writer.buffered());
    const snap = stream.snapshot(std.testing.allocator) orelse return error.NoStream;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("echo:ping", snap);
}

test "session/cancel latches the engine cancel flag" {
    var s: Session = undefined;
    s.init(std.testing.allocator, 1);
    attach(&s);
    defer detach();
    agent_mod.Agent.esc_cancel.store(false, .release);
    acp_engine.cancel_flag.store(false, .release);
    cancel();
    try std.testing.expect(acp_engine.cancel_flag.load(.acquire));
    try std.testing.expect(agent_mod.Agent.esc_cancel.load(.acquire));
    agent_mod.Agent.esc_cancel.store(false, .release);
    acp_engine.cancel_flag.store(false, .release);
}
