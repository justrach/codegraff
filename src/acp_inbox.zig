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

pub const SteerFn = *const fn (ctx: *anyopaque, arena: std.mem.Allocator, out: *Io.Writer, output_lock: *Io.Mutex, req: proto.Request, text: []const u8) bool;

/// Steering carries text only: images and embedded resources must remain in
/// the ordinary queued prompt so their payload is not silently dropped.
fn plainPrompt(prompt: ?std.json.Value) bool {
    const p = prompt orelse return false;
    if (p == .string) return p.string.len > 0;
    if (p != .array or p.array.items.len == 0) return false;
    for (p.array.items) |block| {
        if (block != .object) return false;
        const t = block.object.get("type") orelse return false;
        if (t != .string or !std.mem.eql(u8, t.string, "text")) return false;
    }
    return true;
}

pub const Inbox = struct {
    permission: ?*@import("acp_permission.zig").Bridge = null,
    steer_fn: ?SteerFn = null,
    steer_ctx: ?*anyopaque = null,
    out: ?*Io.Writer = null,
    output_lock: ?*Io.Mutex = null,
    gpa: std.mem.Allocator,
    io: Io,
    reader: *Io.Reader,
    mutex: Io.Mutex = .init,
    ready: Io.Condition = .init,
    lines: std.ArrayList([]u8) = .empty,
    eof: bool = false,
    session_id: ?[]u8 = null,
    cancelled: bool = false,
    /// Who the pending cancel came from (#1611).
    cancel_kind: cancel_source.Source = .acp_cancel,
    active: bool = false,
    tick: bool = false,
    future: ?Io.Future(void) = null,
    tick_future: ?Io.Future(void) = null,

    pub const Event = union(enum) {
        line: []const u8,
        tick,
    };

    pub fn setSteer(self: *Inbox, func: ?SteerFn, ctx: ?*anyopaque, out: ?*Io.Writer, output_lock: ?*Io.Mutex) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.steer_fn = func;
        self.steer_ctx = ctx;
        self.out = out;
        self.output_lock = output_lock;
    }

    pub fn clearSteer(self: *Inbox) void {
        self.setSteer(null, null, null, null);
    }

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
        if (self.cancelled) cancel_source.cancel(self.cancel_kind);
    }

    pub fn end(self: *Inbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active = false;
        self.cancelled = false;
        if (self.session_id) |sid| self.gpa.free(sid);
        self.session_id = null;
    }

    /// A plain-text prompt arriving during a live OpenAI-model turn goes
    /// straight into that turn's steer queue. The callback answers the ACP
    /// request; a false result falls back to the ordinary next-turn queue.
    fn trySteer(self: *Inbox, arena: std.mem.Allocator, req: proto.Request) bool {
        self.mutex.lockUncancelable(self.io);
        const active = self.active;
        const func = self.steer_fn;
        const ctx = self.steer_ctx;
        const out = self.out;
        const output_lock = self.output_lock;
        self.mutex.unlock(self.io);
        if (!active or func == null or ctx == null or out == null or output_lock == null) return false;
        const params = req.params orelse return false;
        if (params != .object) return false;
        const prompt = params.object.get("prompt");
        if (!plainPrompt(prompt)) return false;
        const text = proto.flattenPrompt(arena, prompt) catch return false;
        const line = std.mem.trimStart(u8, text, " \t\r\n");
        if (line.len == 0) return false;
        if (line[0] == '/' and @import("acp_command_intent.zig").selected(req.params)) return false;
        // Room posts need the dispatcher's agent framing, never raw human steering.
        if (params.object.get("_meta")) |meta| {
            if (meta == .object and meta.object.contains("harness/room")) return false;
        }
        return func.?(ctx.?, arena, out.?, output_lock.?, req, text);
    }

    fn tryLiveAgents(self: *Inbox, arena: std.mem.Allocator, req: proto.Request) bool {
        self.mutex.lockUncancelable(self.io);
        const active = self.active;
        const out = self.out;
        const output_lock = self.output_lock;
        self.mutex.unlock(self.io);
        if (!active or out == null or output_lock == null) return false;
        output_lock.?.lockUncancelable(self.io);
        defer output_lock.?.unlock(self.io);
        const handled = @import("acp_agents.zig").handle(arena, self.io, "", out.?, req) catch return false;
        if (!handled) return false;
        out.?.flush() catch return false;
        return true;
    }

    fn isDirectQueueMethod(method: []const u8) bool {
        return std.mem.eql(u8, method, "initialize") or
            std.mem.eql(u8, method, "session/new") or
            std.mem.eql(u8, method, "session/load") or
            std.mem.eql(u8, method, "session/resume") or
            std.mem.eql(u8, method, "session/set_config_option") or
            std.mem.eql(u8, method, "graff/models") or
            std.mem.eql(u8, method, "graff/changes") or
            std.mem.eql(u8, method, "session/fork");
    }

    fn accept(self: *Inbox, line: []const u8) !void {
        const fast_method = @import("acp_handshake_log.zig").methodOf(line);
        if (fast_method) |m| {
            if (isDirectQueueMethod(m)) {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const copy = try self.gpa.dupe(u8, line);
                errdefer self.gpa.free(copy);
                try self.lines.append(self.gpa, copy);
                self.ready.broadcast(self.io);
                return;
            }
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const parsed_val: std.json.Value = if (trimmed.len == 0)
            .null
        else
            std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), trimmed, .{ .allocate = .alloc_always }) catch .null;
        if (fast_method == null) {
            if (@import("acp_elicit.zig").accept(parsed_val)) return;
            if (self.permission) |bridge| if (bridge.accept(parsed_val)) return;
        }
        const req = proto.requestFromValue(parsed_val);
        if (req) |r| {
            if ((std.mem.eql(u8, r.method, "session/prompt") or std.mem.eql(u8, r.method, "_session/steering")) and self.trySteer(arena.allocator(), r)) return;
            if (std.mem.eql(u8, r.method, "graff/agents") and self.tryLiveAgents(arena.allocator(), r)) return;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (req) |r| {
            const sid: ?[]const u8 = blk: {
                const params = r.params orelse break :blk null;
                if (params != .object) break :blk null;
                const value = params.object.get("sessionId") orelse break :blk null;
                break :blk if (value == .string) value.string else null;
            };
            // v2 session/close cancels like session/cancel, then still queues
            // so dispatch answers it once the turn has unwound.
            const closing = std.mem.eql(u8, r.method, "session/close");
            if ((std.mem.eql(u8, r.method, "session/cancel") and r.id == null) or closing) {
                if (self.session_id) |current| {
                    if (sid == null or std.mem.eql(u8, sid.?, current)) {
                        self.cancelled = true;
                        self.cancel_kind = cancel_source.fromAcp(r.params);
                        if (self.active) cancel_source.cancel(self.cancel_kind);
                        acp_ask.cancelIfWaiting();
                        if (self.permission) |bridge| bridge.cancel();
                    }
                }
                if (!closing) return;
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
            if (std.mem.eql(u8, r.method, "session/prompt")) {
                // #1522: a prompt queued behind a live turn is a follow-up, so
                // a blocking job wait yields to it (the job keeps running).
                if (self.active) @import("job_wait.zig").noteFollowup();
                if (self.session_id == null) self.session_id = try self.gpa.dupe(u8, sid orelse "");
            }
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

test "plainPrompt admits text only, leaving image/resource payloads queued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = std.json.parseFromSliceLeaky;
    try std.testing.expect(plainPrompt(try parse(std.json.Value, a, "\"hello\"", .{})));
    try std.testing.expect(plainPrompt(try parse(std.json.Value, a, "[{\"type\":\"text\",\"text\":\"hi\"}]", .{})));
    try std.testing.expect(!plainPrompt(try parse(std.json.Value, a, "[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"image\"}]", .{})));
    try std.testing.expect(!plainPrompt(try parse(std.json.Value, a, "[{\"type\":\"resource\",\"resource\":{}}]", .{})));
    try std.testing.expect(!plainPrompt(null));
}

test "an active plain prompt steers now instead of queueing" {
    const Capture = struct {
        text: ?[]u8 = null,
        fn steer(ctx: *anyopaque, _: std.mem.Allocator, _: *Io.Writer, _: *Io.Mutex, _: proto.Request, text: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.text) |old| std.testing.allocator.free(old);
            self.text = std.testing.allocator.dupe(u8, text) catch return false;
            return true;
        }
    };
    var cap: Capture = .{};
    defer if (cap.text) |text| std.testing.allocator.free(text);
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var lock: Io.Mutex = .init;
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    inbox.steer_fn = Capture.steer;
    inbox.steer_ctx = &cap;
    inbox.out = &aw.writer;
    inbox.output_lock = &lock;
    inbox.begin();
    try inbox.accept("{\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[{\"type\":\"text\",\"text\":\"also run tests\"}]}}");
    try std.testing.expectEqualStrings("also run tests", cap.text.?);
    try std.testing.expectEqual(@as(usize, 0), inbox.lines.items.len);

    // Harness's explicit steering extension reaches the same live path.
    try inbox.accept("{\"id\":4,\"method\":\"_session/steering\",\"params\":{\"sessionId\":\"s\",\"prompt\":\"change direction\"}}");
    try std.testing.expectEqualStrings("change direction", cap.text.?);
    try std.testing.expectEqual(@as(usize, 0), inbox.lines.items.len);
    // Literal slash prose can steer, but selected/legacy commands, attachments
    // and room posts need ordinary dispatch and must never become raw steering.
    try inbox.accept("{\"id\":5,\"method\":\"session/prompt\",\"params\":{\"prompt\":\"/this is prose\",\"_meta\":{\"harness/command\":false}}}");
    try std.testing.expectEqualStrings("/this is prose", cap.text.?);
    for ([_][]const u8{
        "{\"prompt\":\"  /compact\",\"_meta\":{\"harness/command\":true}}",
        "{\"prompt\":\"/compact\"}",
        "{\"prompt\":[{\"type\":\"image\",\"data\":\"x\"}]}",
        "{\"prompt\":\"agent post\",\"_meta\":{\"harness/room\":{}}}",
    }) |params| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const request = try std.fmt.allocPrint(arena_state.allocator(), "{{\"method\":\"session/prompt\",\"params\":{s}}}", .{params});
        const req = proto.parseRequest(arena_state.allocator(), request).?;
        try std.testing.expect(!inbox.trySteer(arena_state.allocator(), req));
    }
    try std.testing.expectEqualStrings("/this is prose", cap.text.?);

    // Undelivered fallback still honors the ordinary queue when the callback declines.
    if (cap.text) |text| std.testing.allocator.free(text);
    cap.text = null;
    inbox.steer_fn = null;
    try inbox.accept("{\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[{\"type\":\"text\",\"text\":\"queued\"}]}}");
    try std.testing.expectEqual(@as(usize, 1), inbox.lines.items.len);
}

test "#1522 a prompt queued behind a live turn is a follow-up; the turn's own prompt is not" {
    const job_wait = @import("job_wait.zig");
    job_wait.followup_pending.store(false, .release);
    defer job_wait.followup_pending.store(false, .release);
    Agent.esc_cancel.store(false, .release);
    defer Agent.esc_cancel.store(false, .release);
    var reader: Io.Reader = .fixed("");
    var inbox: Inbox = .{ .gpa = std.testing.allocator, .io = std.testing.io, .reader = &reader };
    defer inbox.deinit();
    try inbox.accept("{\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\"}}");
    try std.testing.expect(!job_wait.followup_pending.load(.acquire));
    inbox.begin();
    try inbox.accept("{\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\"}}");
    try std.testing.expect(job_wait.followup_pending.load(.acquire));
    // A follow-up yields waits; it never cancels the running turn.
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
}
