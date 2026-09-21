//! #1007: idle ACP roots start a turn on parked peer mail, same latch as TUI/REPL.
//! No `session/prompt` request id — the client did not send one. Mid-turn
//! preemption stays out of scope (#430): this only runs between prompts.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");
const proto = @import("acp_protocol.zig");
const idle_wake = @import("idle_wake_sources.zig");
const peer_idle = @import("peer_idle.zig");
const peer_inbox = @import("peer_inbox.zig");

pub fn maybeWake(d: *engine.Dispatch, arena: Allocator, w: *Io.Writer, io: Io, session_name: []const u8) !void {
    const sid = d.session_id orelse return;
    if (sid.len == 0) return;
    if (peer_idle.isBusy()) return; // in-flight prompt is not preempted (#1136)
    var buf: [512]u8 = undefined;
    const wake = idle_wake.takeIdleWake(io, session_name, &buf) orelse return;
    try promptWake(d, arena, w, wake);
}

pub fn promptWake(d: *engine.Dispatch, arena: Allocator, w: *Io.Writer, wake: []const u8) !void {
    const sid = d.session_id orelse return;
    if (sid.len == 0 or wake.len == 0) return;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{
        .jsonrpc = "2.0",
        .method = "session/prompt",
        .params = .{
            .sessionId = sid,
            .prompt = .{.{ .type = "text", .text = wake }},
        },
    });
    try engine.handleLine(d, arena, w, aw.writer.buffered());
    try proto.writeNotification(w, "session/update", .{
        .sessionId = sid,
        .update = .{
            .sessionUpdate = "gui_turn_end",
            .stopReason = "end_turn",
        },
    });
}

fn echoTurn(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

test "#1007 idle wake without a request id streams the turn and no RPC result" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: engine.Dispatch = .{ .turn = echoTurn, .ctx = undefined, .session_id = "s1" };
    try promptWake(&d, a, &w, "[peer] 1 unread");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "echo:[peer] 1 unread") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gui_turn_end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\"") == null);
}

test "#1136 maybeWake is silent while a root turn is in flight" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: engine.Dispatch = .{ .turn = echoTurn, .ctx = undefined, .session_id = "s1" };
    peer_idle.noteTurnStart();
    try maybeWake(&d, arena.allocator(), &w, std.testing.io, "s1");
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
    peer_idle.noteTurnEnd();
}

test "#1007 maybeWake is silent without a session or mail" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: engine.Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    try maybeWake(&d, arena.allocator(), &w, std.testing.io, "");
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
    d.session_id = "s1";
    try maybeWake(&d, arena.allocator(), &w, std.testing.io, "s1");
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}
