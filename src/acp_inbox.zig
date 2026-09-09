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
    future: ?Io.Future(void) = null,

    pub fn start(self: *Inbox) void {
        self.future = self.io.async(pump, .{self});
    }

    pub fn deinit(self: *Inbox) void {
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
