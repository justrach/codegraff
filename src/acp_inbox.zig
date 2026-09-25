//! Own ACP stdin while dispatch is busy; cancellation never waits behind a turn (#809).
const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const proto = @import("acp_protocol.zig");
const cancel_source = @import("cancel_source.zig");
const acp_ask = @import("acp_ask.zig");
const stdin_line = @import("stdin_line.zig");

test {
    _ = stdin_line;
}

pub const Inbox = struct {
    permission: ?*@import("acp_permission.zig").Bridge = null,
    gpa: std.mem.Allocator,
    io: Io,
    reader: *Io.Reader,
    mutex: Io.Mutex = .init,
    ready: Io.Condition = .init,
    lines: std.ArrayList([]u8) = .empty,
    eof: bool = false,
    session_id: ?[]u8 = null,
    cancelled: bool = false,
    active: bool = false,
    tick: bool = false,
    future: ?Io.Future(void) = null,
    tick_future: ?Io.Future(void) = null,

    pub const Event = union(enum) {
        line: []const u8,
        tick,
    };

    pub fn start(self: *Inbox) !void {
        // async may run the endless reader inline when its worker quota is
        // busy, preventing the dispatcher from ever answering initialize.
        self.future = try self.io.concurrent(pump, .{self});
        self.tick_future = try self.io.concurrent(tickPump, .{self});
    }

    pub fn deinit(self: *Inbox) void {
        if (self.tick_future) |*f| f.cancel(self.io);
        if (self.future) |*f| f.cancel(self.io);
        for (self.lines.items) |line| self.gpa.free(line);
        self.lines.deinit(self.gpa);
        if (self.session_id) |sid| self.gpa.free(sid);
    }

    pub fn next(self: *Inbox, arena: std.mem.Allocator) !?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.lines.items.len == 0 and !self.eof)
            self.ready.waitUncancelable(self.io, &self.mutex);
        if (self.lines.items.len == 0) return null;
        const line = self.lines.orderedRemove(0);
        defer self.gpa.free(line);
        return try arena.dupe(u8, line);
    }

    /// Idle loop: a stdin line, a 200ms poll tick, or EOF (`null`).
    /// A queued line always wins over a tick so a prompt is never delayed.
    pub fn wait(self: *Inbox, arena: std.mem.Allocator) !?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.lines.items.len == 0 and !self.eof and !self.tick)
            self.ready.waitUncancelable(self.io, &self.mutex);
        if (self.lines.items.len > 0) {
            const line = self.lines.orderedRemove(0);
            defer self.gpa.free(line);
            return .{ .line = try arena.dupe(u8, line) };
        }
        if (self.tick) {
            self.tick = false;
            return .tick;
        }
        return null;
    }

    /// A finished background job wants a turn now. Safe from the pump thread:
    /// it only sets the tick the idle loop already drains.
    pub fn nudge(self: *Inbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.eof) return;
        self.tick = true;
        self.ready.broadcast(self.io);
    }

    /// Called after prepareRootTurn, under the same lock as incoming cancel.
    pub fn begin(self: *Inbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active = true;
        if (self.cancelled) cancel_source.cancel(.acp_cancel);
    }

    pub fn end(self: *Inbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active = false;
        self.cancelled = false;
        if (self.session_id) |sid| self.gpa.free(sid);
        self.session_id = null;
    }

    fn accept(self: *Inbox, line: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        if (self.permission) |bridge| {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch .null;
            if (bridge.accept(value)) return;
        }
        const req = proto.parseRequest(arena.allocator(), line);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (req) |r| {
            const sid: ?[]const u8 = blk: {
                const params = r.params orelse break :blk null;
                if (params != .object) break :blk null;
                const value = params.object.get("sessionId") orelse break :blk null;
                break :blk if (value == .string) value.string else null;
            };
            if (std.mem.eql(u8, r.method, "session/cancel") and r.id == null) {
                if (self.session_id) |current| {
                    if (sid == null or std.mem.eql(u8, sid.?, current)) {
                        self.cancelled = true;
                        if (self.active) cancel_source.cancel(.acp_cancel);
                        acp_ask.cancelIfWaiting();
                        if (self.permission) |bridge| bridge.cancel();
                    }
                }
                return;
            }
            if (std.mem.eql(u8, r.method, "session/answer")) {
                const obj: ?std.json.ObjectMap = if (r.params) |p| (if (p == .object) p.object else null) else null;
                const cancelled_answer = if (obj) |o| switch (o.get("cancelled") orelse .null) {
                    .bool => |b| b,
                    else => false,
                } else false;
                const answer_text: []const u8 = if (obj) |o| blk: {
                    const v = o.get("text") orelse break :blk "";
                    break :blk if (v == .string) v.string else "";
                } else "";
                _ = acp_ask.reply(answer_text, cancelled_answer);
                return;
            }
            if (std.mem.eql(u8, r.method, "session/prompt") and self.session_id == null)
                self.session_id = try self.gpa.dupe(u8, sid orelse "");
        }
        const copy = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(copy);
        try self.lines.append(self.gpa, copy);
        self.ready.broadcast(self.io);
    }

    fn pump(self: *Inbox) void {
        while (true) {
            // Not takeDelimiter: a prompt with an attachment outgrows the stdin
            // buffer, and its StreamTooLong used to end the session here.
            switch (stdin_line.take(self.reader, self.gpa, stdin_line.max_bytes) catch break) {
                .eof => break,
                .too_long => std.debug.print("acp: dropped an input record over {d} bytes\n", .{stdin_line.max_bytes}),
                .line => |line| {
                    defer self.gpa.free(line);
                    self.accept(line) catch break;
                },
            }
        }
        self.mutex.lockUncancelable(self.io);
        self.eof = true;
        if (self.permission) |bridge| bridge.cancel();
        self.ready.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn tickPump(self: *Inbox) void {
        const accord = @import("presence_accord.zig");
        while (true) {
            var n: u32 = 0;
            while (n < 4) : (n += 1) {
                if (accord.takePing()) break;
                self.io.sleep(.fromMilliseconds(50), .awake) catch return;
                if (self.eof) return;
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.eof) break;
            if (self.active) continue;
            self.tick = true;
            self.ready.broadcast(self.io);
        }
    }
};

test "ACP cancel interrupts active turn and does not cancel its successor" {
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    defer Agent.esc_cancel.store(false, .release);
    try inbox.accept("{\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\"}}");
    Agent.esc_cancel.store(false, .release);
    inbox.begin();
    try inbox.accept("{\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"other\"}}");
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
    try inbox.accept("{\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}");
    try std.testing.expect(Agent.esc_cancel.load(.acquire));
    inbox.end();
    Agent.esc_cancel.store(false, .release);
    try inbox.accept("{\"method\":\"session/cancel\"}");
    inbox.begin();
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
}

test "session/answer fills the ask mailbox without queueing a line" {
    acp_ask.attach(std.testing.io, std.testing.allocator);
    defer acp_ask.detach();
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    try inbox.accept("{\"method\":\"session/answer\",\"params\":{\"text\":\"pill\",\"cancelled\":false}}");
    try std.testing.expectEqual(@as(usize, 0), inbox.lines.items.len);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try acp_ask.wait(arena_state.allocator());
    try std.testing.expectEqualStrings("pill", got.text);
}

test "session/answer ignores an empty non-cancelled reply" {
    acp_ask.attach(std.testing.io, std.testing.allocator);
    defer acp_ask.detach();
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    try inbox.accept("{\"method\":\"session/answer\",\"params\":{\"text\":\"\",\"cancelled\":false}}");
    try std.testing.expect(acp_ask.reply("kept", false));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try acp_ask.wait(arena_state.allocator());
    try std.testing.expectEqualStrings("kept", got.text);
}

test "ACP cancellation before turn setup survives the reset" {
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    defer Agent.esc_cancel.store(false, .release);
    try inbox.accept("{\"method\":\"session/prompt\"}");
    try inbox.accept("{\"method\":\"session/cancel\"}");
    Agent.esc_cancel.store(false, .release);
    inbox.begin();
    try std.testing.expect(Agent.esc_cancel.load(.acquire));
}

test "#1007 wait prefers a queued line over a poll tick" {
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    inbox.tick = true;
    try inbox.accept("{\"method\":\"session/prompt\"}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ev = (try inbox.wait(arena.allocator())) orelse return error.ExpectedLine;
    try std.testing.expect(ev == .line);
}

test "#1007 wait returns a tick when idle" {
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    inbox.tick = true;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ev = (try inbox.wait(arena.allocator())) orelse return error.ExpectedTick;
    try std.testing.expect(ev == .tick);
}

test "session config selection during a turn queues an ordinary request without steering" {
    Agent.esc_cancel.store(false, .release);
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    defer Agent.esc_cancel.store(false, .release);
    try inbox.accept("{\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\"}}");
    inbox.begin();
    try inbox.accept("{\"id\":2,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"s\",\"configId\":\"thought_level\",\"value\":\"high\"}}");
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = (try inbox.wait(arena.allocator())) orelse return error.ExpectedLine;
    try std.testing.expect(std.mem.indexOf(u8, first.line, "session/prompt") != null);
    inbox.end();
    const second = (try inbox.wait(arena.allocator())) orelse return error.ExpectedLine;
    try std.testing.expect(std.mem.indexOf(u8, second.line, "session/set_config_option") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.line, "session/prompt") == null);
}
