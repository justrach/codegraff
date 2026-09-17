//! Own ACP stdin while dispatch is busy; cancellation never waits behind a turn (#809).
const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const proto = @import("acp_protocol.zig");
const cancel_source = @import("cancel_source.zig");

pub const Inbox = struct {
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
                    }
                }
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
            const line = (self.reader.takeDelimiter('\n') catch break) orelse break;
            self.accept(line) catch break;
        }
        self.mutex.lockUncancelable(self.io);
        self.eof = true;
        self.ready.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn tickPump(self: *Inbox) void {
        while (true) {
            self.io.sleep(.fromMilliseconds(200), .awake) catch break;
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
