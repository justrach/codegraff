//! One hardware-approved arm can become one connection's grant.
const std = @import("std");

pub const hello = "{\"jsonrpc\":\"2.0\",\"method\":\"nanocua/turnScope\",\"id\":\"turn-scope\"}";
pub const ack = "{\"jsonrpc\":\"2.0\",\"id\":\"turn-scope\",\"result\":{}}\n";

pub const Token = struct {
    live: std.atomic.Value(bool) = .init(true),
    refs: usize = 1, // owned and released only on the main thread

    pub fn release(t: *Token, a: std.mem.Allocator) void {
        t.refs -= 1;
        if (t.refs == 0) a.destroy(t);
    }
};

pub const Grants = struct {
    armed: bool = false,
    connections: std.AutoHashMapUnmanaged(u64, *Token) = .empty,

    pub fn claim(g: *Grants, a: std.mem.Allocator, conn: u64) ?*Token {
        if (g.connections.get(conn)) |token| {
            token.refs += 1;
            return token;
        }
        if (!g.armed) return null;
        const token = a.create(Token) catch return null;
        g.connections.put(a, conn, token) catch {
            a.destroy(token);
            return null;
        };
        token.* = .{ .refs = 2 };
        g.armed = false;
        return token;
    }

    pub fn close(g: *Grants, a: std.mem.Allocator, conn: u64) void {
        const removed = g.connections.fetchRemove(conn) orelse return;
        removed.value.live.store(false, .release);
        removed.value.release(a);
    }

    pub fn revoke(g: *Grants, a: std.mem.Allocator) void {
        g.armed = false;
        var values = g.connections.valueIterator();
        while (values.next()) |token| {
            token.*.live.store(false, .release);
            token.*.release(a);
        }
        g.connections.clearRetainingCapacity();
    }
};
