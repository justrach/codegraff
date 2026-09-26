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
    const meter_pos = std.mem.indexOf(u8, output, "\"used\":20,\"window\":100") orelse return error.MissingMeter;
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
    const occupancy = std.mem.indexOf(u8, output, "\"gui_context_meter\",\"used\":123,\"window\":1000") orelse return error.MissingMeter;
    const terminal = std.mem.indexOf(u8, output, "\"stopReason\":\"end_turn\"") orelse return error.MissingTerminalReply;
    try std.testing.expect(occupancy < terminal);
}
