//! Stdin line inbox for live ACP (#791).
//!
//! `session/cancel` is applied as soon as the line is read, without waiting
//! for `session/prompt` to return. Zig 0.17 has no `std.Thread.Mutex`; the
//! inbox uses an atomic lock and a short sleep.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");

pub fn isCancelLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "session/cancel") != null and
        std.mem.indexOf(u8, line, "\"method\"") != null;
}

pub fn applyCancel() void {
    engine.cancel_flag.store(true, .release);
    if (engine.on_cancel) |hook| hook();
}

pub const Inbox = struct {
    lock_bit: std.atomic.Value(u8) = .init(0),
    lines: std.ArrayList([]u8) = .empty,
    closed: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Inbox) void {
        while (self.lock_bit.cmpxchgWeak(0, 1, .acquire, .monotonic) != null)
            std.Thread.yield() catch {};
    }

    fn unlock(self: *Inbox) void {
        self.lock_bit.store(0, .release);
    }

    pub fn push(self: *Inbox, gpa: Allocator, line: []const u8) void {
        const copy = gpa.dupe(u8, line) catch return;
        self.lock();
        defer self.unlock();
        self.lines.append(gpa, copy) catch {
            gpa.free(copy);
        };
    }

    pub fn close(self: *Inbox) void {
        self.closed.store(true, .release);
    }

    pub fn pop(self: *Inbox, gpa: Allocator) ?[]u8 {
        _ = gpa;
        while (true) {
            self.lock();
            if (self.lines.items.len > 0) {
                const line = self.lines.orderedRemove(0);
                self.unlock();
                return line;
            }
            const done = self.closed.load(.acquire);
            self.unlock();
            if (done) return null;
            std.Thread.yield() catch {};
        }
    }
};

test "#791: cancel lines are recognized before prompt dispatch" {
    try std.testing.expect(isCancelLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/cancel\"}"));
    try std.testing.expect(!isCancelLine("{\"method\":\"session/prompt\"}"));
    applyCancel();
    try std.testing.expect(engine.cancel_flag.load(.acquire));
    engine.cancel_flag.store(false, .release);
}
