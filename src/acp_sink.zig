//! ACP EngineSink: tool cards and streamed answer chunks (ADR 0013).
//!
//! `--json` maps engine events in `engine_sink.zig`, but ACP sets `json_mode`
//! and `root.out = null`, so that sink is non-durable and drops every line.
//! This sink writes `session/update` notifications onto the same stdout the
//! JSON-RPC loop already owns. Root tools only — a subagent with `out=null`
//! and no sink stays dropped.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const engine_sink = @import("engine_sink.zig");
const engine_events = @import("engine_events.zig");
const util = @import("util.zig");

const Pending = struct {
    name: [64]u8 = undefined,
    len: u8 = 0,
    id: u32 = 0,
};

var g_state: ?*State = null;

pub const State = struct {
    io: Io,
    out: *Io.Writer,
    gpa: Allocator,
    session_buf: [96]u8 = undefined,
    session_len: usize = 0,
    next_id: u32 = 1,
    pending: std.ArrayList(Pending) = .empty,
    streamed: bool = false,

    pub fn init(io: Io, out: *Io.Writer, gpa: Allocator) State {
        return .{ .io = io, .out = out, .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        self.pending.deinit(self.gpa);
    }

    pub fn setSession(self: *State, id: ?[]const u8) void {
        const s = id orelse {
            self.session_len = 0;
            return;
        };
        const n = @min(s.len, self.session_buf.len);
        @memcpy(self.session_buf[0..n], s[0..n]);
        self.session_len = n;
    }

    pub fn sessionId(self: *const State) []const u8 {
        return self.session_buf[0..self.session_len];
    }

    pub fn sink(self: *State) engine_sink.EngineSink {
        return .{ .ctx = @ptrCast(self), .vt = &vtable };
    }
};

pub fn attach(st: *State) void {
    g_state = st;
}

pub fn detach() void {
    g_state = null;
}

pub fn beginTurn() void {
    if (g_state) |s| s.streamed = false;
}

pub fn didStream() bool {
    return if (g_state) |s| s.streamed else false;
}

pub fn kindOf(name: []const u8) []const u8 {
    if (eql(name, "bash") or eql(name, "bash_output") or eql(name, "bash_kill") or eql(name, "monitor") or eql(name, "codedb"))
        return "execute";
    if (eql(name, "read_file")) return "read";
    if (eql(name, "edit_file") or eql(name, "write_file")) return "edit";
    if (eql(name, "webfetch")) return "fetch";
    return "other";
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn mint(self: *State) u32 {
    const id = self.next_id;
    self.next_id += 1;
    return id;
}

fn push(self: *State, name: []const u8, id: u32) void {
    var p: Pending = .{ .id = id, .len = @intCast(@min(name.len, 64)) };
    @memcpy(p.name[0..p.len], name[0..p.len]);
    self.pending.append(self.gpa, p) catch {};
}

fn find(self: *State, name: []const u8) ?u32 {
    for (self.pending.items) |p| {
        if (eql(p.name[0..p.len], name)) return p.id;
    }
    return null;
}

fn take(self: *State, name: []const u8) ?u32 {
    for (self.pending.items, 0..) |p, i| {
        if (eql(p.name[0..p.len], name)) return self.pending.orderedRemove(i).id;
    }
    return null;
}

const vtable = engine_sink.VTable{ .emit = emitStamped, .durable = false };

fn emitStamped(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const self: *State = @ptrCast(@alignCast(ctx));
    main_mod.g_gui_mu.lockUncancelable(self.io);
    defer main_mod.g_gui_mu.unlock(self.io);
    switch (ev.event) {
        .tool_call_announced => |t| {
            if (t.ask_user) return;
            const id = mint(self);
            push(self, t.name, id);
            writeTool(self, id, t.name, "pending", t.input, null, false);
        },
        .tool_call_started => |t| {
            if (t.ask_user) return;
            const id = find(self, t.name) orelse blk: {
                const n = mint(self);
                push(self, t.name, n);
                break :blk n;
            };
            writeTool(self, id, t.name, "in_progress", t.input, null, true);
        },
        .tool_call_finished => |t| {
            if (t.ask_user) return;
            const id = take(self, t.name) orelse mint(self);
            const status: []const u8 = if (t.is_error or t.cancelled) "failed" else "completed";
            writeTool(self, id, t.name, status, null, t.text, true);
        },
        .tool_rejected => |t| {
            const id = take(self, t.name) orelse mint(self);
            writeTool(self, id, t.name, "failed", t.input, t.message, true);
        },
        .text_delta => |d| {
            self.streamed = true;
            writeUpdate(self, .{
                .sessionUpdate = "agent_message_chunk",
                .content = .{ .type = "text", .text = d.text },
            });
        },
        else => {},
    }
}

fn writeTool(self: *State, id: u32, name: []const u8, status: []const u8, input: ?Value, result: ?[]const u8, is_update: bool) void {
    var id_buf: [24]u8 = undefined;
    const call_id = std.fmt.bufPrint(&id_buf, "tool-{d}", .{id}) catch return;
    const kind = kindOf(name);
    const clipped = if (result) |r| util.utf8Prefix(r, 4096) else "";
    if (is_update) {
        if (result != null) {
            writeUpdate(self, .{
                .sessionUpdate = "tool_call_update",
                .toolCallId = call_id,
                .status = status,
                .content = .{
                    .{ .type = "content", .content = .{ .type = "text", .text = clipped } },
                },
            });
        } else if (input) |raw| {
            writeUpdate(self, .{
                .sessionUpdate = "tool_call_update",
                .toolCallId = call_id,
                .status = status,
                .rawInput = raw,
            });
        } else {
            writeUpdate(self, .{
                .sessionUpdate = "tool_call_update",
                .toolCallId = call_id,
                .status = status,
            });
        }
        return;
    }
    if (input) |raw| {
        writeUpdate(self, .{
            .sessionUpdate = "tool_call",
            .toolCallId = call_id,
            .title = name,
            .kind = kind,
            .status = status,
            .rawInput = raw,
        });
    } else {
        writeUpdate(self, .{
            .sessionUpdate = "tool_call",
            .toolCallId = call_id,
            .title = name,
            .kind = kind,
            .status = status,
        });
    }
}

fn writeUpdate(self: *State, payload: anytype) void {
    var s: std.json.Stringify = .{ .writer = self.out };
    s.write(.{
        .jsonrpc = "2.0",
        .method = "session/update",
        .params = .{
            .sessionId = self.sessionId(),
            .update = payload,
        },
    }) catch return;
    self.out.writeByte('\n') catch return;
    self.out.flush() catch {};
}

const testing = std.testing;

fn emit(st: *State, ev: engine_events.EngineEvent) void {
    st.sink().emit(st.io, ev);
}

test "kindOf maps the job and file tools" {
    try testing.expectEqualStrings("execute", kindOf("bash"));
    try testing.expectEqualStrings("execute", kindOf("monitor"));
    try testing.expectEqualStrings("execute", kindOf("codedb"));
    try testing.expectEqualStrings("read", kindOf("read_file"));
    try testing.expectEqualStrings("edit", kindOf("edit_file"));
    try testing.expectEqualStrings("edit", kindOf("write_file"));
    try testing.expectEqualStrings("fetch", kindOf("webfetch"));
    try testing.expectEqualStrings("other", kindOf("todo_write"));
}

test "announced/started/finished emit tool_call then updates" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var st = State.init(testing.io, &aw.writer, testing.allocator);
    defer st.deinit();
    st.setSession("sess-1");
    const input = try std.json.parseFromSlice(Value, testing.allocator, "{\"command\":\"ls\"}", .{});
    defer input.deinit();
    emit(&st, .{ .tool_call_announced = .{ .name = "bash", .input = input.value } });
    emit(&st, .{ .tool_call_started = .{ .name = "bash", .input = input.value } });
    emit(&st, .{ .tool_call_finished = .{ .name = "bash", .text = "ok\n", .is_error = false, .ms = 4 } });
    const body = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, body, "\"sessionUpdate\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"toolCallId\":\"tool-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"kind\":\"execute\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"status\":\"pending\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"sessionUpdate\":\"tool_call_update\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"status\":\"in_progress\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"text\":\"ok\\n\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"sessionId\":\"sess-1\"") != null);
}

test "FIFO matches two same-name calls; a failed call is failed" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var st = State.init(testing.io, &aw.writer, testing.allocator);
    defer st.deinit();
    st.setSession("s");
    emit(&st, .{ .tool_call_announced = .{ .name = "read_file", .input = .null } });
    emit(&st, .{ .tool_call_announced = .{ .name = "read_file", .input = .null } });
    emit(&st, .{ .tool_call_finished = .{ .name = "read_file", .text = "a", .is_error = false } });
    emit(&st, .{ .tool_call_finished = .{ .name = "read_file", .text = "b", .is_error = true } });
    const body = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, body, "\"toolCallId\":\"tool-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"toolCallId\":\"tool-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"status\":\"failed\"") != null);
}

test "text_delta streams an agent_message_chunk and sets didStream" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var st = State.init(testing.io, &aw.writer, testing.allocator);
    defer st.deinit();
    attach(&st);
    defer detach();
    beginTurn();
    try testing.expect(!didStream());
    emit(&st, .{ .text_delta = .{ .text = "hi" } });
    try testing.expect(didStream());
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "\"sessionUpdate\":\"agent_message_chunk\"") != null);
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "\"text\":\"hi\"") != null);
}
