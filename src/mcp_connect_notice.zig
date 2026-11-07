//! What a background MCP connect tells the session (ADR 0230). Handshakes no
//! longer hold up the start. The registry queues connection receipts under
//! its lock; the root request drains them through its sink only when startup
//! diagnostics are enabled. Normal sessions stay quiet; `/mcp` still exposes
//! connection state without waiting for a handshake.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const EngineSink = @import("engine_sink.zig").EngineSink;

/// Notices for the next root request, read under the registry lock.
pub const Joined = struct {
    names: [8][]const u8 = undefined,
    tools: [8]?usize = undefined, // null: did not connect
    n: usize = 0,
    /// The first request went out while servers were still connecting.
    still_connecting: bool = false,

    /// Record the finished, not yet merged starts. Caller holds reg.mutex.
    pub fn collect(self: *Joined, reg: *const mcp.Registry) void {
        for (reg.pending_starts, 0..) |*task, i| {
            if (self.n == self.names.len) return;
            if (task.ready == null or !task.finished() or i >= reg.pending_names.len) continue;
            self.names[self.n] = reg.pending_names[i];
            self.tools[self.n] = null;
            self.n += 1;
        }
    }

    /// After the merge: which of them is a live server now, with its tools.
    pub fn resolve(self: *Joined, reg: *mcp.Registry) void {
        for (self.names[0..self.n], 0..) |name, k| {
            for (reg.servers, 0..) |server, i| if (std.mem.eql(u8, server.name, name)) {
                self.tools[k] = reg.toolCount(i);
                break;
            };
        }
    }

    fn emitTo(self: *const Joined, sink: EngineSink, io: Io) void {
        if (self.still_connecting) notice(sink, io, "MCP still connecting — native tools this turn");
        for (self.names[0..self.n], self.tools[0..self.n]) |name, tools| {
            var buf: [192]u8 = undefined;
            notice(sink, io, (if (tools) |count|
                std.fmt.bufPrint(&buf, "mcp: {s} connected ({d} tool(s))", .{ name, count })
            else
                std.fmt.bufPrint(&buf, "mcp: {s} did not connect", .{name})) catch continue);
        }
    }
};

fn notice(sink: EngineSink, io: Io, text: []const u8) void {
    sink.emit(io, .{ .session_notice = .{ .text = text, .tone = .dim } });
}

/// Emit and clear the queued notices. Called by the root agent's request.
pub fn drain(reg: *mcp.Registry, sink: EngineSink, io: Io) void {
    reg.mutex.lockUncancelable(reg.io);
    const queued = reg.connect_notices;
    reg.connect_notices = .{};
    reg.mutex.unlock(reg.io);
    if (reg.show_diagnostics) queued.emitTo(sink, io);
}

/// Servers whose start is still running, for `/mcp`. Call after `joinReady`
/// has merged the finished ones.
pub fn connecting(reg: *mcp.Registry, arena: Allocator) []const []const u8 {
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    var names: std.ArrayList([]const u8) = .empty;
    for (reg.pending_starts, 0..) |task, i| {
        if (task.ready == null or i >= reg.pending_names.len or reg.pending_names[i].len == 0) continue;
        names.append(arena, reg.pending_names[i]) catch break;
    }
    return names.items;
}

test "a finished start is named once it merges; an unfinished one stays connecting" {
    const io = std.testing.io;
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    defer reg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const boot = @import("mcp_boot.zig");
    const done = try reg.gpa.create(std.atomic.Value(bool));
    done.* = .init(true);
    const busy = try reg.gpa.create(std.atomic.Value(bool));
    busy.* = .init(false);
    reg.pending_starts = try reg.gpa.alloc(boot.PendingStart, 2);
    @memset(reg.pending_starts, .{});
    reg.pending_starts[0].ready = done;
    reg.pending_starts[1].ready = busy;
    reg.pending_names = try reg.arena().dupe([]const u8, &.{ "fails", "slow" });

    var joined: Joined = .{};
    joined.collect(&reg);
    try std.testing.expectEqual(@as(usize, 1), joined.n);
    try std.testing.expectEqualStrings("fails", joined.names[0]);
    _ = boot.joinReady(&reg);
    joined.resolve(&reg);
    try std.testing.expect(joined.tools[0] == null); // its start produced no server
    const still = connecting(&reg, arena);
    try std.testing.expectEqual(@as(usize, 1), still.len);
    try std.testing.expectEqualStrings("slow", still[0]);
    busy.store(true, .release);
    _ = boot.joinPending(&reg);
}

test "background MCP notices require diagnostics and drain only once" {
    const Capture = struct {
        count: usize = 0,
        failed: bool = false,
        fn emit(ctx: *anyopaque, event: @import("engine_sink.zig").Stamped) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event.event) {
                .session_notice => |n| {
                    self.count += 1;
                    if (std.mem.indexOf(u8, n.text, "did not connect") != null) self.failed = true;
                },
                else => {},
            }
        }
        const vt: @import("engine_sink.zig").VTable = .{ .emit = emit, .durable = false };
    };
    for ([_]bool{ false, true }) |debug| {
        var reg = mcp.Registry.empty(std.testing.allocator, std.testing.io);
        defer reg.deinit();
        reg.show_diagnostics = debug;
        reg.connect_notices.still_connecting = true;
        reg.connect_notices.n = 2;
        reg.connect_notices.names[0] = "ready";
        reg.connect_notices.tools[0] = 3;
        reg.connect_notices.names[1] = "unavailable";
        reg.connect_notices.tools[1] = null;
        var capture: Capture = .{};
        const sink: EngineSink = .{ .ctx = &capture, .vt = &Capture.vt };
        drain(&reg, sink, std.testing.io);
        try std.testing.expectEqual(@as(usize, if (debug) 3 else 0), capture.count);
        try std.testing.expectEqual(debug, capture.failed);
        drain(&reg, sink, std.testing.io);
        try std.testing.expectEqual(@as(usize, if (debug) 3 else 0), capture.count);
    }
}
