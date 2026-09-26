//! Subagent activity on ACP. By default (mode `progress`) a child's work is
//! shown as standard `tool_call_update`s on its parent's tool call
//! (acp_subagent_progress.zig). The draft child-session stream (mode `draft`)
//! is used only when the client negotiated `subagents` and graff runs with
//! GRAFF_ACP_DRAFT_SUBAGENTS=1. Either way a child is exposed only while its
//! parent prompt is active.
const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const sink = @import("engine_sink.zig");
const stream = @import("acp_stream.zig");
const proto = @import("acp_protocol.zig");
const util = @import("util.zig");
const progress = @import("acp_subagent_progress.zig");

pub const Mode = enum { draft, progress };

pub const State = struct {
    out: *Io.Writer,
    parent: []const u8,
    output_lock: *Io.Mutex,
    mode: Mode = .draft,
};

var active: ?*State = null;

/// Connection-owned extension state. Unlike `active`, this survives parent
/// prompt boundaries so detached workers can keep reporting their progress.
pub const BackgroundState = struct {
    out: *Io.Writer,
    output_lock: *Io.Mutex,
    parent: []const u8 = "",
    enabled: bool = false,
    generation: u64 = 0,
};

var background: ?*BackgroundState = null;
var next_background_generation: u64 = 0;

/// Owned by the detached child, rather than the mutable ACP dispatch session.
pub const BackgroundHandle = struct {
    parent: []const u8,
    generation: u64,
    parent_call_id: []const u8,
};

pub fn installBackground(io: Io, state: *BackgroundState) void {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    next_background_generation +%= 1;
    state.generation = next_background_generation;
    background = state;
}

/// Detach before the ACP transport is destroyed. Child jobs can still finish
/// during the parent process's final reap, but must not write to a dead pipe.
pub fn uninstallBackground(io: Io) void {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    background = null;
}

pub fn configureBackground(io: Io, parent: []const u8, enabled: bool) void {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    const state = background orelse return;
    state.parent = parent;
    state.enabled = enabled;
}

fn backgroundSendLocked(io: Io, handle: BackgroundHandle, id: []const u8, seq: u64, event: anytype) bool {
    const state = background orelse return false;
    if (state.generation != handle.generation) return false;
    state.output_lock.lockUncancelable(io);
    defer state.output_lock.unlock(io);
    proto.writeNotification(state.out, "graff/subagent_event", .{
        .parentSessionId = handle.parent,
        .subagentSessionId = id,
        .parentToolCallId = handle.parent_call_id,
        .seq = seq,
        .event = event,
    }) catch return false;
    state.out.flush() catch {};
    return true;
}

fn backgroundSend(io: Io, handle: BackgroundHandle, id: []const u8, seq: u64, event: anytype) bool {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    return backgroundSendLocked(io, handle, id, seq, event);
}

pub fn announceBackground(a: std.mem.Allocator, io: Io, id: []const u8, name: []const u8, task: []const u8, parent_call_id: []const u8) ?BackgroundHandle {
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    const state = background orelse return null;
    if (!state.enabled or state.parent.len == 0) return null;
    const handle: BackgroundHandle = .{
        .parent = a.dupe(u8, state.parent) catch return null,
        .generation = state.generation,
        .parent_call_id = parent_call_id,
    };
    if (!backgroundSendLocked(io, handle, id, 0, .{
        .type = "spawn",
        .name = util.utf8Prefix(name, 256),
        .task = util.utf8Prefix(task, 2048),
    })) return null;
    return handle;
}

pub fn finishBackground(io: Io, handle: BackgroundHandle, id: []const u8, seq: u64, outcome: []const u8) void {
    _ = backgroundSend(io, handle, id, seq, .{ .type = "terminal", .state = outcome });
}

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
    if (state.mode != .draft) return false;
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

/// Whether this child should stream standard progress onto its parent's tool
/// call: a top-level `subagent` with a known parent call, in a prompt whose
/// client did not choose the draft child-session stream.
pub fn progressFor(io: Io, kind: []const u8, depth: u8, parent_call_id: []const u8) bool {
    if (depth != 0 or parent_call_id.len == 0 or !std.mem.eql(u8, kind, "subagent")) return false;
    if (!progress.enabled()) return false;
    main.g_gui_mu.lockUncancelable(io);
    defer main.g_gui_mu.unlock(io);
    const state = active orelse return false;
    return state.mode == .progress;
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
    background_handle: ?BackgroundHandle = null,
    seq: u64 = 1,
    progress: ?progress.Progress = null,

    pub fn engineSink(self: *ChildSink) sink.EngineSink {
        return .{ .ctx = self, .vt = &vtable };
    }

    const vtable: sink.VTable = .{ .emit = emit, .durable = false };

    fn emit(ctx: *anyopaque, stamped: sink.Stamped) void {
        const self: *ChildSink = @ptrCast(@alignCast(ctx));
        if (self.recorder) |record| record.vt.emit(record.ctx, stamped);
        if (self.background_handle) |handle| {
            self.emitBackground(stamped, handle);
            return;
        }
        if (self.progress != null) {
            self.emitProgress(stamped);
            return;
        }
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

    fn emitProgress(self: *ChildSink, stamped: sink.Stamped) void {
        const p = &self.progress.?;
        const tool_event = switch (stamped.event) {
            .text_delta => |v| blk: {
                p.addText(v.text);
                break :blk false;
            },
            .tool_call_announced => |v| blk: {
                if (v.ask_user or std.mem.eql(u8, v.name, "attempt_completion")) return;
                p.toolLine(v.name, v.input);
                break :blk true;
            },
            .tool_result => |v| blk: {
                if (!(v.is_error or v.cancelled)) return;
                var b: [progress.line_max]u8 = undefined;
                p.addLine(std.fmt.bufPrint(&b, "✗ {s} failed", .{v.name}) catch "✗ failed");
                break :blk true;
            },
            .tool_rejected => blk: {
                p.addLine("✗ tool call rejected");
                break :blk true;
            },
            else => return,
        };
        if (!p.due(util.unixMs(self.io), tool_event)) return;
        self.publishProgress("running");
    }

    fn publishProgress(self: *ChildSink, state_label: []const u8) void {
        const p = &(self.progress orelse return);
        main.g_gui_mu.lockUncancelable(self.io);
        defer main.g_gui_mu.unlock(self.io);
        const state = active orelse return;
        state.output_lock.lockUncancelable(self.io);
        defer state.output_lock.unlock(self.io);
        progress.write(state.out, state.parent, p, state_label) catch return;
        state.out.flush() catch {};
    }

    /// The child's last word on its parent's tool call. The parent's own tool
    /// result, when it has one, follows and replaces this.
    pub fn finishProgress(self: *ChildSink, outcome: []const u8) void {
        const p = &(self.progress orelse return);
        p.addLine(if (std.mem.eql(u8, outcome, "completed")) "✓ finished" else if (std.mem.eql(u8, outcome, "cancelled")) "■ cancelled" else "✗ failed");
        self.publishProgress(outcome);
    }

    fn emitBackground(self: *ChildSink, stamped: sink.Stamped, handle: BackgroundHandle) void {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var bytes: Io.Writer.Allocating = .init(a);
        defer bytes.deinit();
        const w = &bytes.writer;
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
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, w.buffered(), .{}) catch return;
        const params = parsed.object.get("params") orelse return;
        if (params != .object) return;
        const update = params.object.get("update") orelse return;
        if (backgroundSend(self.io, handle, self.id, self.seq, .{ .type = "update", .update = update }))
            self.seq += 1;
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

test "default progress mode streams the child's work onto the parent tool call" {
    var buffer: [16384]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const io = std.testing.io;
    var output_lock: Io.Mutex = .init;
    var state: State = .{ .out = &out, .parent = "parent", .output_lock = &output_lock, .mode = .progress };
    install(io, &state);
    defer uninstall(io);
    // The draft announcement is not used in progress mode.
    try std.testing.expect(!announce(io, "child", "Scout", "Inspect", "spawn-1"));
    try std.testing.expect(progressFor(io, "subagent", 0, "spawn-1"));
    try std.testing.expect(!progressFor(io, "subagent", 1, "spawn-1"));
    try std.testing.expect(!progressFor(io, "subagent", 0, ""));
    var child: ChildSink = .{ .id = "child", .io = io, .progress = .{ .parent_call_id = "spawn-1", .child_id = "child", .name = "Scout" } };
    const emit_sink = child.engineSink();
    var input: std.json.ObjectMap = .empty;
    defer input.deinit(std.testing.allocator);
    try input.put(std.testing.allocator, "path", .{ .string = "src/main.zig" });
    emit_sink.emit(io, .{ .tool_call_announced = .{ .id = "read-1", .name = "read_file", .input = .{ .object = input } } });
    emit_sink.emit(io, .{ .tool_result = .{ .id = "read-1", .name = "bash", .text = "boom", .is_error = true } });
    child.finishProgress("completed");
    const wire = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"sessionUpdate\":\"tool_call_update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"toolCallId\":\"spawn-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "read_file: src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "bash failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "finished") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"sessionId\":\"parent\"") != null);
    // No child session, no draft updates, and no status flip on the parent call.
    try std.testing.expect(std.mem.indexOf(u8, wire, "subagent_update") == null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"status\"") == null);
}
