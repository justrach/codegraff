//! acp_engine.zig's prompt/meter ordering tests (split for the 600-line cap).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");
const Dispatch = engine.Dispatch;
const Meter = engine.Meter;
const handleLine = engine.handleLine;

fn echoTurn(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

test "explicit command intent keeps literal slash prompts out of command dispatch in v1 and v2" {
    const v2 = @import("acp_v2.zig");
    defer v2.resetForTest();
    const Fixture = struct {
        fn slash(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]const u8 {
            return "command executed";
        }
    };
    for ([_]bool{ false, true }) |draft| {
        v2.resetForTest();
        var state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer state.deinit();
        const a = state.allocator();
        var out: Io.Writer.Allocating = .init(a);
        var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .slash = Fixture.slash };
        if (draft) {
            v2.gate = true;
            try handleLine(&d, a, &out.writer, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":2,\"capabilities\":{},\"info\":{\"name\":\"test\",\"version\":\"1\"}}}");
        }
        out.clearRetainingCapacity();
        try handleLine(&d, a, &out.writer, "{\"id\":2,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/ widgets are prose\"}],\"_meta\":{\"harness/command\":false}}}");
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "echo:/ widgets are prose") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "command executed") == null);
        out.clearRetainingCapacity();
        try handleLine(&d, a, &out.writer, "{\"id\":3,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/help\"}],\"_meta\":{\"harness/command\":true}}}");
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "command executed") != null);
        out.clearRetainingCapacity();
        try handleLine(&d, a, &out.writer, "{\"id\":4,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/help\"}]}}");
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "command executed") != null);
    }
}

test "slash commands refresh occupancy before their terminal response" {
    const Fixture = struct {
        fn slash(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]const u8 {
            return "compacted";
        }
        fn meter(_: *anyopaque) Meter {
            return .{ .used = 20, .window = 100 };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var dispatch: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .slash = Fixture.slash, .meter = Fixture.meter };
    try handleLine(&dispatch, arena.allocator(), &writer, "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/compact\"}]}}");
    const output = writer.buffered();
    const meter_pos = std.mem.indexOf(u8, output, "\"usage_update\",\"used\":20,\"size\":100") orelse return error.MissingMeter;
    const end_pos = std.mem.indexOf(u8, output, "stopReason") orelse return error.MissingResponse;
    try std.testing.expect(meter_pos < end_pos);
}

test "live context occupancy precedes the terminal prompt reply" {
    const was_cancelled = engine.cancel_flag.swap(false, .acq_rel);
    defer engine.cancel_flag.store(was_cancelled, .release);
    const extra = engine.extra_cancelled;
    engine.extra_cancelled = null;
    defer engine.extra_cancelled = extra;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [16384]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const meter = struct {
        fn read(_: *anyopaque) Meter {
            return .{ .used = 123, .window = 1000 };
        }
    }.read;
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .meter = meter };
    try handleLine(&d, a, &w, "{\"id\":1,\"method\":\"session/new\"}");
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":2,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}");
    const output = w.buffered();
    const occupancy = std.mem.indexOf(u8, output, "\"usage_update\",\"used\":123,\"size\":1000") orelse return error.MissingMeter;
    const terminal = std.mem.indexOf(u8, output, "\"stopReason\":\"end_turn\"") orelse return error.MissingTerminalReply;
    try std.testing.expect(occupancy < terminal);
}

test "interrupted ACP prompt preserves cancellation provenance in its terminal response" {
    const Fixture = struct {
        fn turn(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            return error.Interrupted;
        }
        fn cancelled(_: *anyopaque) ?engine.Cancellation {
            return .{ .source = "none", .message = "harness cancelled the turn" };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var dispatch: Dispatch = .{ .turn = Fixture.turn, .ctx = undefined, .cancel_info = Fixture.cancelled };
    try handleLine(&dispatch, arena.allocator(), &writer, "{\"id\":7,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"continue\"}]}}");
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stopReason\":\"cancelled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"graff/cancelSource\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "harness cancelled the turn") != null);
}

test "failed slash command returns an ACP error instead of killing the worker loop" {
    const Fixture = struct {
        fn slash(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]const u8 {
            return error.ApiError;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var dispatch: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .slash = Fixture.slash };
    try handleLine(&dispatch, arena.allocator(), &writer, "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/compact\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ApiError") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "end_turn") == null);
}
