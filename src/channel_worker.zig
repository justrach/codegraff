//! Host-managed channel workers (#558). JSONL over stdin/stdout: inbound
//! `{"type":"message","text":"..."}` wakes the session; outbound
//! `{"type":"send","text":"..."}` is the outbox. Discord/Slack fronts come
//! later; this is the protocol + wake seam.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const session_wake = @import("session_wake.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

pub const inbound_type = "message";
pub const outbound_type = "send";

const cap: usize = 16;
var mu: Io.Mutex = .init;
var ring: [cap][]u8 = undefined;
var count: usize = 0;
var gpa_hold: ?Allocator = null;

pub fn parseInbound(arena: Allocator, line: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(Value, arena, std.mem.trim(u8, line, " \t\r\n"), .{}) catch return null;
    if (v != .object) return null;
    const ty = if (v.object.get("type")) |x| (if (x == .string) x.string else "") else "";
    if (!std.mem.eql(u8, ty, inbound_type)) return null;
    const text = if (v.object.get("text")) |x| (if (x == .string) x.string else "") else "";
    return if (text.len == 0) null else text;
}

pub fn formatOutbound(arena: Allocator, text: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{ .type = outbound_type, .text = text });
    try aw.writer.writeByte('\n');
    return aw.writer.buffered();
}

/// Queue an inbound worker line (host thread). `gpa` owns the copy.
pub fn record(io: Io, gpa: Allocator, text: []const u8) void {
    const owned = gpa.dupe(u8, text) catch return;
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    gpa_hold = gpa;
    if (count == cap) {
        gpa.free(ring[0]);
        std.mem.copyForwards([]u8, ring[0 .. cap - 1], ring[1..cap]);
        count = cap - 1;
    }
    ring[count] = owned;
    count += 1;
}

pub fn takeAll(io: Io, arena: Allocator) []const []const u8 {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (count == 0) return &.{};
    const out = arena.alloc([]const u8, count) catch return &.{};
    var i: usize = 0;
    while (i < count) : (i += 1) {
        out[i] = arena.dupe(u8, ring[i]) catch "";
        if (gpa_hold) |g| g.free(ring[i]);
    }
    count = 0;
    return out;
}

pub fn deliver(root: *Agent) void {
    if (root.sub) return;
    const lines = takeAll(root.io, root.arena);
    for (lines) |text| {
        const wake = std.fmt.allocPrint(root.arena, "[adapter] {s}", .{text}) catch continue;
        session_wake.inject(root, wake);
    }
}

/// `/adapter send <text>` posts to the outbox (tests + a later live worker).
pub fn slashCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const rest = std.mem.trim(u8, line["/adapter".len..], " \t");
    if (std.mem.startsWith(u8, rest, "send ") or std.mem.startsWith(u8, rest, "send\t")) {
        const text = std.mem.trim(u8, rest["send".len..], " \t");
        if (text.len == 0) {
            try out.writeAll("usage: /adapter send <text>\n");
            try out.flush();
            return true;
        }
        const wire = try formatOutbound(arena, text);
        try out.writeAll(wire);
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, rest, "inbox")) {
        const lines = takeAll(root.io, arena);
        if (lines.len == 0) try out.writeAll("(adapter inbox empty)\n") else {
            for (lines) |t| try out.print("{s}\n", .{t});
        }
        try out.flush();
        return true;
    }
    try out.writeAll("usage: /adapter send <text> | /adapter inbox\n");
    try out.flush();
    return true;
}

test "parseInbound accepts message lines and drops the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hi", parseInbound(a, "{\"type\":\"message\",\"text\":\"hi\"}").?);
    try std.testing.expect(parseInbound(a, "{\"type\":\"send\",\"text\":\"hi\"}") == null);
    try std.testing.expect(parseInbound(a, "not-json") == null);
}

test "formatOutbound is a send line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const wire = try formatOutbound(arena.allocator(), "pong");
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"type\":\"send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "pong") != null);
    try std.testing.expect(std.mem.endsWith(u8, wire, "\n"));
}

/// Idle TUI auto-turn: drain the inbox into a buffer without an Agent.
pub fn takeWake(io: Io, buf: []u8) ?[]const u8 {
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const lines = takeAll(io, fba.allocator());
    if (lines.len == 0) return null;
    var used: usize = 0;
    for (lines) |text| {
        const piece = if (used == 0)
            std.fmt.bufPrint(buf[used..], "[adapter] {s}", .{text}) catch break
        else
            std.fmt.bufPrint(buf[used..], "\n[adapter] {s}", .{text}) catch break;
        used += piece.len;
    }
    return if (used == 0) null else buf[0..used];
}

test "slashCommand send is a send line; inbox drains takeWake" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = takeAll(io, arena.allocator());
    var root: Agent = undefined;
    root.io = io;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expect(try slashCommand(&root, arena.allocator(), "/adapter send pong", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "\"type\":\"send\"") != null);
    record(io, gpa, "hello");
    var buf: [128]u8 = undefined;
    const wake = takeWake(io, &buf) orelse return error.Empty;
    try std.testing.expectEqualStrings("[adapter] hello", wake);
    try std.testing.expect(takeWake(io, &buf) == null);
}

test "record then takeAll drains once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = takeAll(io, arena.allocator());
    record(io, gpa, "one");
    record(io, gpa, "two");
    const got = takeAll(io, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("one", got[0]);
    try std.testing.expectEqual(@as(usize, 0), takeAll(io, arena.allocator()).len);
}
