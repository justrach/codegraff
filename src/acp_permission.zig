//! ACP server-initiated permission RPC, scoped to one live process and turn.
const std = @import("std");
const Io = std.Io;
const permission = @import("engine_permission.zig");
const util = @import("util.zig");
const v2 = @import("acp_v2.zig");
pub const Bridge = struct {
    io: Io,
    out: *Io.Writer,
    output_lock: ?*Io.Mutex = null,
    session: []const u8 = "",
    mutex: Io.Mutex = .init,
    ready: Io.Condition = .init,
    sequence: u64 = 0,
    pending: ?u64 = null,
    decision: ?permission.Decision = null,
    allow_always: bool = false,
    closed: bool = false,

    pub fn handler(self: *Bridge) permission.Handler {
        return .{ .ctx = self, .request = ask };
    }
    pub fn setOutputLock(self: *Bridge, lock: ?*Io.Mutex) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.output_lock = lock;
    }
    pub fn cancel(self: *Bridge) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.decision = .deny;
        self.ready.broadcast(self.io);
    }
    pub fn begin(self: *Bridge, session: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.session = session;
        self.closed = false;
    }
    fn ask(ctx: *anyopaque, io: Io, req: permission.Request) permission.Decision {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed or self.pending != null) return .deny;
        self.sequence += 1;
        self.pending = self.sequence;
        self.decision = null;
        self.allow_always = req.allow_always;
        defer {
            self.pending = null;
            self.decision = null;
        }
        var idbuf: [64]u8 = undefined;
        const id = std.fmt.bufPrint(&idbuf, "graff-permission-{d}", .{self.sequence}) catch return .deny;
        const Option = struct { optionId: []const u8, name: []const u8, kind: []const u8 };
        const options = [_]Option{
            .{ .optionId = "allow_once", .name = "Allow once", .kind = "allow_once" },
            .{ .optionId = "reject_once", .name = "Reject", .kind = "reject_once" },
            .{ .optionId = "allow_always", .name = req.always_label, .kind = "allow_always" },
        };
        {
            // Same order as tool dispatch: bridge state -> shared output.
            // Inbox responses/cancel never acquire the output lock. Release it
            // before waiting so background events remain visible during consent.
            const main = @import("main.zig");
            main.g_gui_mu.lockUncancelable(io);
            defer main.g_gui_mu.unlock(io);
            if (self.output_lock) |lock| lock.lockUncancelable(io);
            defer if (self.output_lock) |lock| lock.unlock(io);
            std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .method = "session/request_permission", .params = .{
                .sessionId = self.session,
                .toolCall = .{ .toolCallId = req.call_id, .title = req.description, .status = "pending" },
                .options = options[0..if (req.allow_always) @as(usize, 3) else 2],
            } }, .{}, self.out) catch return .deny;
            self.out.writeByte('\n') catch return .deny;
            if (v2.on()) v2.writeRequiresAction(self.out, self.session) catch return .deny;
            self.out.flush() catch return .deny;
        }
        while (self.decision == null and !self.closed) self.ready.waitUncancelable(io, &self.mutex);
        if (v2.on() and !self.closed) {
            const main = @import("main.zig");
            main.g_gui_mu.lockUncancelable(io);
            defer main.g_gui_mu.unlock(io);
            if (self.output_lock) |lock| lock.lockUncancelable(io);
            defer if (self.output_lock) |lock| lock.unlock(io);
            v2.writeRunning(self.out, self.session) catch {};
            self.out.flush() catch {};
        }
        return self.decision orelse .deny;
    }
    /// Responses have no method. Only the currently pending server ID can resolve.
    pub fn accept(self: *Bridge, value: std.json.Value) bool {
        if (value != .object or value.object.contains("method")) return false;
        const id = util.strFieldObj(value.object, "id") orelse return false;
        if (!std.mem.startsWith(u8, id, "graff-permission-")) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const seq = std.fmt.parseInt(u64, id[17..], 10) catch return true;
        if (self.closed or self.pending != seq or self.decision != null) return true;
        const result = value.object.get("result") orelse {
            self.decision = .deny;
            self.ready.broadcast(self.io);
            return true;
        };
        const outcome = if (result == .object) result.object.get("outcome") orelse .null else .null;
        var decision: permission.Decision = .deny;
        if (outcome == .object and std.mem.eql(u8, util.strFieldObj(outcome.object, "outcome") orelse "", "selected")) {
            const option = util.strFieldObj(outcome.object, "optionId") orelse "";
            if (std.mem.eql(u8, option, "allow_once")) decision = .allow_once;
            if (self.allow_always and std.mem.eql(u8, option, "allow_always")) decision = .allow_always;
        }
        self.decision = decision;
        self.ready.broadcast(self.io);
        return true;
    }
};

test "ACP permission replies reject stale duplicate and unoffered choices" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var bridge: Bridge = .{ .io = std.testing.io, .out = &out.writer, .pending = 2 };
    for ([_][]const u8{
        "{\"id\":\"graff-permission-1\",\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}}",
        "{\"id\":\"graff-permission-2\",\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_always\"}}}",
    }, 0..) |text, index| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expect(bridge.accept(parsed.value));
        if (index == 0) try std.testing.expect(bridge.decision == null) else try std.testing.expectEqual(permission.Decision.deny, bridge.decision.?);
    }
    bridge.cancel();
    try std.testing.expect(bridge.closed);
}

test "ACP permission waits for shared output lock before any JSON bytes" {
    const Probe = struct {
        writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{}, .end = 0 },
        touched: std.atomic.Value(bool) = .init(false),
        started: std.atomic.Value(bool) = .init(false),
        fn drain(w: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", w));
            self.touched.store(true, .release);
            return error.WriteFailed;
        }
        fn run(self: *@This(), bridge: *Bridge) void {
            self.started.store(true, .release);
            _ = bridge.handler().ask(std.testing.io, .{ .call_id = "call", .tool = "bash", .description = "request" });
        }
    };
    const io = std.testing.io;
    var probe: Probe = .{};
    var bridge: Bridge = .{ .io = io, .out = &probe.writer };
    const main = @import("main.zig");
    main.g_gui_mu.lockUncancelable(io);
    var locked = true;
    defer if (locked) main.g_gui_mu.unlock(io);
    var worker = try io.concurrent(Probe.run, .{ &probe, &bridge });
    while (!probe.started.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    try io.sleep(.fromMilliseconds(25), .awake);
    const wrote_while_locked = probe.touched.load(.acquire);
    main.g_gui_mu.unlock(io);
    locked = false;
    worker.await(io);
    try std.testing.expect(!wrote_while_locked);
    try std.testing.expect(probe.touched.load(.acquire));
    // A failed frame also releases both locks and retires its pending request.
    main.g_gui_mu.lockUncancelable(io);
    main.g_gui_mu.unlock(io);
    bridge.cancel();
    try std.testing.expect(bridge.pending == null);
}
