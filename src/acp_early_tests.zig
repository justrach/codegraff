//! Tests for acp_early.zig: the early `initialize` answer against the late
//! dispatch path, the shared stdin buffer, and the pre-auth path.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const early = @import("acp_early.zig");
const engine = @import("acp_engine.zig");
const v2 = @import("acp_v2.zig");

/// Everything handling `initialize` writes: the dispatch fields and the
/// process latches (v2 wire + message-id seed, T3, elicitation, compaction).
pub const Latches = struct {
    subagents: bool,
    background_subagents: bool,
    v2: bool,
    v2_seed: [24]u8,
    t3: bool,
    elicit: @TypeOf(@import("acp_elicit.zig").mode),
    compaction: bool,

    pub fn of(d: *const engine.Dispatch) Latches {
        var mint_buf: [48]u8 = undefined;
        const id = v2.mint(&mint_buf, "x"); // msg_x_<seed>_<n>; the counter is not a latch
        var it = std.mem.splitScalar(u8, id, '_');
        _ = it.next();
        _ = it.next();
        var seed: [24]u8 = @splat(0);
        const s = it.next() orelse "";
        @memcpy(seed[0..@min(s.len, seed.len)], s[0..@min(s.len, seed.len)]);
        return .{
            .subagents = d.subagents,
            .background_subagents = d.background_subagents,
            .v2 = v2.on(),
            .v2_seed = seed,
            .t3 = @import("acp_t3.zig").active(),
            .elicit = @import("acp_elicit.zig").mode,
            .compaction = @import("acp_compaction.zig").enabled(),
        };
    }
};

fn noTurn(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
    return "";
}

fn noLoad(_: *anyopaque, _: Allocator, _: *Io.Writer, _: @import("acp_protocol.zig").Request) anyerror!void {}

/// Reset every latch to the boot value so cells do not leak into each other.
pub fn resetLatches() void {
    v2.negotiate(null, 0);
    @import("acp_t3.zig").note(null);
    @import("acp_elicit.zig").configure(null);
    @import("acp_compaction.zig").noteInitialize(null);
}

pub const Outcome = struct { bytes: []const u8, latches: Latches };

/// The late path: the live loop dispatches the line on a dispatch seeded `seed`.
pub fn late(arena: Allocator, line: []const u8, can_load: bool, seed: u64) !Outcome {
    resetLatches();
    var aw: Io.Writer.Allocating = .init(arena);
    var d: engine.Dispatch = .{ .turn = noTurn, .ctx = undefined, .seed = seed, .load_session = if (can_load) noLoad else null };
    engine.implementation_version = @import("build_options").version;
    try engine.handleLine(&d, arena, &aw.writer, line);
    return .{ .bytes = aw.writer.buffered(), .latches = .of(&d) };
}

/// The early path: a boundary check answers from the shared reader, then the
/// loop-start replay dispatches the kept line on the live dispatch, output discarded.
pub fn earlyThenReplay(arena: Allocator, line: []const u8, can_load: bool, seed: u64) !Outcome {
    resetLatches();
    const input = try std.mem.concat(arena, u8, &.{ line, "\n" });
    var in: Io.Reader = .fixed(input);
    var aw: Io.Writer.Allocating = .init(arena);
    var e: early.Early = .{ .gpa = testing.allocator, .in = &in, .out = &aw.writer, .acp = true, .can_load = can_load };
    if (!e.boundary()) return error.NotAnsweredEarly;
    try testing.expectEqual(@as(usize, 0), in.bufferedLen());
    var d: engine.Dispatch = .{ .turn = noTurn, .ctx = undefined, .seed = seed, .load_session = if (can_load) noLoad else null };
    const replay = e.loopStart() orelse return error.NoReplay;
    var sink_buf: [64]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    try engine.handleLine(&d, arena, &sink.writer, replay);
    try testing.expect(e.loopStart() == null); // handed exactly once; frees it
    return .{ .bytes = aw.writer.buffered(), .latches = .of(&d) };
}

test "acp_early: early answer is byte-identical to the late one and leaves the same state" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    defer resetLatches();
    const saved = v2.gate;
    defer v2.gate = saved;
    for ([_]?bool{ false, true }) |gate| {
        v2.gate = gate;
        for ([_][]const u8{
            "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{}}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":2,\"clientInfo\":{\"name\":\"t3-code\"},\"clientCapabilities\":{\"subagents\":{},\"_meta\":{\"graff/backgroundSubagents\":true},\"elicitation\":{\"form\":{}},\"session\":{\"compaction\":true}}}}",
            "{\"id\":3,\"method\":\"initialize\"}",
        }) |line| for ([_]bool{ false, true }) |can_load| {
            const l = try late(a, line, can_load, 0x5eed);
            const e = try earlyThenReplay(a, line, can_load, 0x5eed);
            try testing.expectEqualStrings(l.bytes, e.bytes);
            try testing.expectEqual(l.latches, e.latches);
        };
    }
}

test "acp_early: a non-initialize first line is left untouched for the loop" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{}}\n{\"id\":2,\"method\":\"initialize\"}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{}}\n", // a notification is not answered
        "not json\n",
        "\n{\"id\":1,\"method\":\"initialize\"}\n",
    }) |input| {
        var in: Io.Reader = .fixed(input);
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var e: early.Early = .{ .gpa = testing.allocator, .in = &in, .out = &aw.writer, .acp = true };
        try testing.expect(!e.boundary());
        try testing.expect(!e.boundary()); // passed: never looks again
        try testing.expectEqual(early.State.passed, e.state);
        try testing.expectEqualStrings(input, in.buffered());
        try testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
        try testing.expect(e.loopStart() == null);
    }
}

test "acp_early: a first line that fills the buffer, or a dirty stdout, is declined" {
    var big: [64]u8 = @splat('x');
    var in: Io.Reader = .fixed(&big); // no newline anywhere in a full buffer
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var e: early.Early = .{ .gpa = testing.allocator, .in = &in, .out = &aw.writer, .acp = true };
    try testing.expect(!e.boundary());
    try testing.expectEqual(early.State.booting, e.state);
    try testing.expectEqual(big.len, in.bufferedLen());

    var in2: Io.Reader = .fixed("{\"id\":1,\"method\":\"initialize\"}\n");
    try aw.writer.writeAll("junk");
    var dirty: early.Early = .{ .gpa = testing.allocator, .in = &in2, .out = &aw.writer, .acp = true };
    try testing.expect(!dirty.boundary());
    try testing.expectEqual(early.State.passed, dirty.state);
    try testing.expectEqualStrings("junk", aw.writer.buffered());
}

fn pipePair() ![2]std.posix.fd_t {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SkipZigTest;
    return fds;
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    if (std.c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.ShortWrite;
}

test "acp_early: a partial first line is not consumed and boot does not wait for the rest" {
    resetLatches();
    defer resetLatches();
    const fds = try pipePair();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var buf: [4096]u8 = undefined;
    var reader = (Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } }).reader(testing.io, &buf);
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var e: early.Early = .{ .gpa = testing.allocator, .in = &reader.interface, .out = &aw.writer, .acp = true, .fd = fds[0] };
    try testing.expect(!e.boundary()); // nothing written yet: returns at once
    try testing.expectEqual(early.State.booting, e.state);
    try writeFd(fds[1], "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initia");
    try testing.expect(!e.boundary());
    try testing.expectEqual(early.State.booting, e.state);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initia", reader.interface.buffered());
    try testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
    try writeFd(fds[1], "lize\"}\n{\"id\":2,\"method\":\"session/new\"}\n{\"id\":3,");
    try testing.expect(e.boundary());
    try testing.expectEqual(early.State.answered, e.state);
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "\"id\":1,\"result\"") != null);
    // The bytes after the answered line stay in the one shared buffer, in order.
    try testing.expectEqualStrings("{\"id\":2,\"method\":\"session/new\"}\n{\"id\":3,", reader.interface.buffered());
    const answered = aw.writer.buffered().len;
    try testing.expect(!e.boundary()); // exactly once
    try testing.expectEqual(answered, aw.writer.buffered().len);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", e.loopStart().?);
    try testing.expect(e.loopStart() == null);
    try testing.expectEqual(answered, aw.writer.buffered().len);
}

test "acp_early: outside ACP the first check declines without reading stdin" {
    const fds = try pipePair();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try writeFd(fds[1], "{\"id\":1,\"method\":\"initialize\"}\n");
    var buf: [256]u8 = undefined;
    var reader = (Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } }).reader(testing.io, &buf);
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var e: early.Early = .{ .gpa = testing.allocator, .in = &reader.interface, .out = &aw.writer, .acp = false, .fd = fds[0] };
    try testing.expect(!e.boundary());
    try testing.expectEqual(early.State.passed, e.state);
    try testing.expectEqual(@as(usize, 0), reader.interface.bufferedLen());
    try testing.expect(e.loopStart() == null);
}

test "acp_early: live_can_load is what acp_session_load.configure installs" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var root: @import("agent.zig").Agent = .{
        .gpa = testing.allocator,
        .arena = a,
        .io = testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "m", .context = 1 },
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "test",
        .out = null,
    };
    var live: @import("acp_live_turn.zig").LiveTurn = .{ .root = &root, .keys = undefined, .out = undefined };
    var d: engine.Dispatch = .{ .turn = noTurn, .ctx = &live };
    @import("acp_session_load.zig").configure(&d, &live);
    try testing.expectEqual(early.live_can_load, d.load_session != null);
}

test "acp_early: the pre-auth path still answers initialize like the engine with can_load false" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    defer resetLatches();
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}";
    resetLatches();
    var pre: Io.Writer.Allocating = .init(a);
    try engine.handlePreAuthLine(a, &pre.writer, line);
    var direct: Io.Writer.Allocating = .init(a);
    resetLatches();
    try testing.expect(early.respond(a, &direct.writer, line, false));
    try testing.expectEqualStrings(pre.writer.buffered(), direct.writer.buffered());
    var gated: Io.Writer.Allocating = .init(a);
    try engine.handlePreAuthLine(a, &gated.writer, "{\"id\":2,\"method\":\"session/new\"}");
    try testing.expect(std.mem.indexOf(u8, gated.writer.buffered(), "\"error\"") != null);
}

test "acp_early: step answers only a booting initialize, takes it only once sent, replays only a taken one" {
    const lines = [_]early.Line{ .none, .incomplete, .initialize, .other };
    for (std.enums.values(early.State)) |s| {
        for ([_]bool{ false, true }) |acp| for (lines) |l| {
            const r = early.step(s, .{ .boundary = .{ .acp = acp, .line = l } });
            try testing.expectEqual(s == .booting and acp and l == .initialize, r.action == .answer);
            try testing.expect(r.action != .replay and r.action != .take);
        };
        for ([_]bool{ false, true }) |ok| {
            const r = early.step(s, .{ .sent = ok });
            try testing.expectEqual(s == .answering and ok, r.action == .take);
            if (s == .answering and !ok) try testing.expectEqual(early.State.passed, r.next);
        }
        const r = early.step(s, .loop_start);
        try testing.expectEqual(early.State.loop, r.next);
        try testing.expectEqual(s == .answered, r.action == .replay);
    }
}

const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}";

test "acp_early: an allocation failure anywhere in the early answer leaves the request for the loop" {
    defer resetLatches();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        resetLatches();
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var in: Io.Reader = .fixed(init_line ++ "\n");
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var e: early.Early = .{ .gpa = failing.allocator(), .in = &in, .out = &aw.writer, .acp = true };
        if (e.boundary()) {
            // Answered: one complete framed response, and only then consumed.
            const out = aw.writer.buffered();
            try testing.expect(std.mem.indexOf(u8, out, "\"id\":1,\"result\"") != null);
            try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
            try testing.expect(std.mem.endsWith(u8, out, "\n"));
            try testing.expectEqual(@as(usize, 0), in.bufferedLen());
            try testing.expectEqualStrings(init_line, e.loopStart().?);
            try testing.expect(e.loopStart() == null);
            if (!failing.has_induced_failure) break;
        } else {
            // Not answered: nothing written, the line still where the loop reads.
            try testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
            try testing.expectEqualStrings(init_line ++ "\n", in.buffered());
            try testing.expect(e.loopStart() == null);
        }
    }
}

/// A transport that accepts `budget` bytes in total, then fails every write:
/// budget 0 is a closed pipe, a small budget a write that dies mid-line.
const Short = struct {
    budget: usize,
    sink: [4096]u8 = undefined,
    len: usize = 0,
    buf: [64]u8 = undefined,
    writer: Io.Writer,

    fn init(self: *Short, budget: usize) void {
        self.* = .{ .budget = budget, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.buf } };
    }

    fn sent(self: *const Short) []const u8 {
        return self.sink[0..self.len];
    }

    fn send(self: *Short, bytes: []const u8) Io.Writer.Error!void {
        const take = @min(bytes.len, self.budget);
        @memcpy(self.sink[self.len..][0..take], bytes[0..take]);
        self.len += take;
        self.budget -= take;
        if (take < bytes.len) return error.WriteFailed;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Short = @alignCast(@fieldParentPtr("writer", w));
        try self.send(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.send(part);
            n += part.len;
        }
        for (0..splat) |_| try self.send(data[data.len - 1]);
        return n + data[data.len - 1].len * splat;
    }
};

/// The late path on `w`: the loop dispatches the line, then flushes the wire.
fn lateOn(w: *Io.Writer, line: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: engine.Dispatch = .{ .turn = noTurn, .ctx = undefined, .load_session = noLoad };
    engine.implementation_version = @import("build_options").version;
    engine.handleLine(&d, arena.allocator(), w, line) catch return false;
    w.flush() catch return false;
    return true;
}

test "acp_early: a failed or short write of the early answer fails exactly as the late path" {
    defer resetLatches();
    for ([_]usize{ 0, 1, 100 }) |budget| {
        resetLatches();
        var early_out: Short = undefined;
        early_out.init(budget);
        var in: Io.Reader = .fixed(init_line ++ "\n");
        var e: early.Early = .{ .gpa = testing.allocator, .in = &in, .out = &early_out.writer, .acp = true };
        try testing.expect(!e.boundary()); // not claimed as answered
        try testing.expectEqual(early.State.passed, e.state);
        try testing.expectEqual(@as(usize, 0), early_out.writer.buffered().len); // no unframed bytes left behind
        try testing.expectEqualStrings(init_line ++ "\n", in.buffered()); // the loop still reads it
        try testing.expect(e.loopStart() == null);
        // The loop then dispatches it on the same broken transport ...
        try testing.expect(!lateOn(&early_out.writer, init_line));
        // ... and the client has seen exactly what the late path alone shows.
        resetLatches();
        var late_out: Short = undefined;
        late_out.init(budget);
        try testing.expect(!lateOn(&late_out.writer, init_line));
        try testing.expectEqualStrings(late_out.sent(), early_out.sent());
    }
}
