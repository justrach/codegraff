//! Job-owned request/response mailbox. Payloads never borrow a turn arena.
const std = @import("std");
pub const Decision = enum { allow_once, deny };
pub const Request = struct {
    id: u64,
    bytes: [2048]u8 = undefined,
    len: usize = 0,
    pub fn description(self: *const Request) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Mailbox = struct {
    lock: std.atomic.Value(bool) = .init(false),
    serial: u64 = 0,
    pending: ?Request = null,
    answer: ?Decision = null,
    fn acquire(self: *Mailbox) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn release(self: *Mailbox) void {
        self.lock.store(false, .release);
    }
    pub fn begin(self: *Mailbox, description: []const u8) ?u64 {
        self.acquire();
        defer self.release();
        if (self.pending != null or description.len > 2048) return null;
        self.serial +%= 1;
        var req: Request = .{ .id = self.serial };
        req.len = @min(description.len, req.bytes.len);
        while (req.len < description.len and req.len > 0 and description[req.len] & 0xc0 == 0x80) req.len -= 1;
        for (description[0..req.len], 0..) |c, i| req.bytes[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
        self.pending = req;
        self.answer = null;
        return req.id;
    }
    pub fn peek(self: *Mailbox) ?Request {
        self.acquire();
        defer self.release();
        if (self.answer != null) return null;
        return self.pending;
    }
    pub fn respond(self: *Mailbox, id: u64, decision: Decision) bool {
        self.acquire();
        defer self.release();
        const req = self.pending orelse return false;
        if (req.id != id or self.answer != null) return false;
        self.answer = decision;
        return true;
    }
    pub fn poll(self: *Mailbox, id: u64) ?Decision {
        self.acquire();
        defer self.release();
        const req = self.pending orelse return .deny;
        if (req.id != id) return .deny;
        return self.answer;
    }
    pub fn retire(self: *Mailbox, id: u64) void {
        self.acquire();
        defer self.release();
        if (self.pending) |req| if (req.id == id) {
            self.pending = null;
            self.answer = null;
        };
    }
};

test "permission replies are once-only and stale request IDs cannot approve the next tool" {
    var box: Mailbox = .{};
    const first = box.begin("first") orelse unreachable;
    try std.testing.expect(box.begin("overlap") == null);
    try std.testing.expect(box.respond(first, .deny));
    try std.testing.expect(!box.respond(first, .allow_once));
    box.retire(first);
    const second = box.begin("second") orelse unreachable;
    try std.testing.expect(!box.respond(first, .allow_once));
    box.retire(first);
    try std.testing.expect(box.poll(second) == null);
    try std.testing.expect(box.respond(second, .allow_once));
    try std.testing.expectEqual(Decision.allow_once, box.poll(second).?);
}

test "permission simulator renders request and accepts only explicit unpasted decisions" {
    const engine = @import("engine.zig");
    var term: @import("sim.zig").Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    var job: engine.Job = .{ .gpa = std.testing.allocator, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
    term.model.pending = &job;
    defer term.model.pending = null;
    const id = job.events.permission.begin("run: write a file") orelse unreachable;
    const screen = try term.screen();
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "Permission: run: write a file") != null);
    _ = term.feed("\x1b[200~y\x1b[201~");
    try std.testing.expect(job.events.permission.poll(id) == null);
    _ = term.typeText("y");
    try std.testing.expectEqual(Decision.allow_once, job.events.permission.poll(id).?);
    job.events.permission.retire(id);
    const denied = job.events.permission.begin("second") orelse unreachable;
    _ = term.typeText("n");
    try std.testing.expectEqual(Decision.deny, job.events.permission.poll(denied).?);
}

test "permission simulator Escape cancels and oversized descriptions fail closed" {
    const engine = @import("engine.zig");
    const Callback = struct {
        var cancelled = false;
        fn cancel(_: ?*anyopaque) void {
            cancelled = true;
        }
    };
    const previous = engine.g_cancel_fn;
    defer engine.g_cancel_fn = previous;
    engine.g_cancel_fn = Callback.cancel;
    Callback.cancelled = false;
    var term: @import("sim.zig").Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    var job: engine.Job = .{ .gpa = std.testing.allocator, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
    term.model.pending = &job;
    defer term.model.pending = null;
    try std.testing.expect(job.events.permission.begin(&@as([2049]u8, @splat('x'))) == null);
    const id = job.events.permission.begin("command") orelse unreachable;
    _ = @import("keys.zig").handle(&term.model, .escape);
    try std.testing.expect(Callback.cancelled);
    try std.testing.expectEqual(Decision.deny, job.events.permission.poll(id).?);
}
