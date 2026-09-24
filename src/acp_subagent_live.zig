//! ACP v1 draft subagent stream. A child is exposed only while its parent
//! prompt is active and only after the client negotiated `subagents`.
const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const sink = @import("engine_sink.zig");
const stream = @import("acp_stream.zig");
const proto = @import("acp_protocol.zig");
const util = @import("util.zig");

pub const State = struct {
    out: *Io.Writer,
    parent: []const u8,
    output_lock: *Io.Mutex,
};

var active: ?*State = null;

pub fn eligible(kind: []const u8, depth: u8, detached: bool) bool {
    return depth == 0 and !detached and std.mem.eql(u8, kind, "subagent");
}

pub fn install(io: Io, state: *State) void {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    active = state;
}

pub fn uninstall(io: Io) void {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    active = null;
}

pub fn announce(io: Io, id: []const u8, name: []const u8, task: []const u8, parent_call_id: []const u8) bool {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    const state = active orelse return false;
    state.output_lock.lockUncancelable(io);
    defer state.output_lock.unlock(io);
    proto.writeNotification(state.out, "session/update", .{ .sessionId = state.parent, .update = .{
        .sessionUpdate = "subagent_update",
        .subagentSessionId = id,
        .name = util.utf8Prefix(name, 256),
        .task = util.utf8Prefix(task, 2048),
        ._meta = .{ .@"graff/parentToolCallId" = parent_call_id },
    } }) catch return false;
    state.out.flush() catch {};
    return true;
}

pub fn finish(io: Io, id: []const u8, outcome: []const u8, parent_call_id: []const u8) void {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    const state = active orelse return;
    state.output_lock.lockUncancelable(io);
    defer state.output_lock.unlock(io);
    proto.writeNotification(state.out, "session/update", .{ .sessionId = state.parent, .update = .{
        .sessionUpdate = "subagent_update",
        .subagentSessionId = id,
        .state = outcome,
        ._meta = .{ .@"graff/parentToolCallId" = parent_call_id },
    } }) catch return;
    state.out.flush() catch {};
}

/// Fan out the child's semantic events to its own ACP session, retaining the
/// existing recorder sink for graff/agents inspection and terminal frontends.
pub const ChildSink = struct {
    id: []const u8,
    io: Io,
    recorder: ?sink.EngineSink = null,

    pub fn engineSink(self: *ChildSink) sink.EngineSink {
        return .{ .ctx = self, .vt = &vtable };
    }

    const vtable: sink.VTable = .{ .emit = emit, .durable = false };

    fn emit(ctx: *anyopaque, stamped: sink.Stamped) void {
        const self: *ChildSink = @ptrCast(@alignCast(ctx));
        if (self.recorder) |record| record.vt.emit(record.ctx, stamped);
        main.g_gui_mu.lockUncancelable(self.io);
        defer main.g_gui_mu.unlock(self.io);
        const state = active orelse return;
        state.output_lock.lockUncancelable(self.io);
        defer state.output_lock.unlock(self.io);
        const w = state.out;
        switch (stamped.event) {
            .reasoning_delta => |v| stream.writeThought(w, self.id, v.text) catch return,
            .text_delta => |v| stream.writeMessage(w, self.id, v.text) catch return,
            .tool_call_announced => |v| {
                if (v.ask_user or std.mem.eql(u8, v.name, "attempt_completion")) return;
                stream.writeToolCall(w, self.id, v.id, v.name, v.input) catch return;
            },
            .tool_result => |v| {
                if (v.ask_user or std.mem.eql(u8, v.name, "attempt_completion")) return;
                stream.writeToolDone(w, self.id, v.id, v.is_error or v.cancelled, v.text) catch return;
            },
            .tool_rejected => |v| stream.writeToolDone(w, self.id, v.id, true, v.message) catch return,
            else => return,
        }
        w.flush() catch {};
    }
};

test "negotiated child stream announces before activity and terminates on parent" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const io = std.testing.io;
    var output_lock: Io.Mutex = .init;
    var state: State = .{ .out = &out, .parent = "parent", .output_lock = &output_lock };
    install(io, &state);
    defer uninstall(io);
    try std.testing.expect(announce(io, "child", "Scout", "Inspect the code", "spawn-1"));
    var child: ChildSink = .{ .id = "child", .io = io };
    const emit_sink = child.engineSink();
    emit_sink.emit(io, .{ .reasoning_delta = .{ .text = "I will inspect it" } });
    emit_sink.emit(io, .{ .tool_call_announced = .{ .id = "read-1", .name = "read_file", .input = .null } });
    emit_sink.emit(io, .{ .tool_result = .{ .id = "read-1", .name = "read_file", .text = "contents", .is_error = false } });
    emit_sink.emit(io, .{ .text_delta = .{ .text = "Found the cause" } });
    finish(io, "child", "completed", "spawn-1");
    const wire = out.buffered();
    const announced = std.mem.indexOf(u8, wire, "\"subagentSessionId\":\"child\"") orelse return error.MissingAnnouncement;
    const thought = std.mem.indexOf(u8, wire, "agent_thought_chunk") orelse return error.MissingThought;
    const call = std.mem.indexOf(u8, wire, "\"toolCallId\":\"read-1\"") orelse return error.MissingTool;
    const answer = std.mem.indexOf(u8, wire, "Found the cause") orelse return error.MissingAnswer;
    const terminal = std.mem.indexOf(u8, wire, "\"state\":\"completed\"") orelse return error.MissingTerminal;
    try std.testing.expect(announced < thought and thought < call and call < answer and answer < terminal);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"sessionId\":\"child\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"graff/parentToolCallId\":\"spawn-1\"") != null);
}

test "draft child sessions exclude detached and nested workers" {
    try std.testing.expect(eligible("subagent", 0, false));
    try std.testing.expect(!eligible("subagent", 0, true));
    try std.testing.expect(!eligible("subagent", 1, false));
    try std.testing.expect(!eligible("workflow_task", 0, false));
}
