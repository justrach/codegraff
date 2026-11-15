const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");
const Dispatch = engine.Dispatch;
const ConfigOption = engine.ConfigOption;
const ConfigValue = engine.ConfigValue;
const handleLine = engine.handleLine;
const stripSgr = engine.stripSgr;

fn echoTurn(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

test "in-process handleLine speaks the same initialize / new / prompt envelopes" {
    engine.implementation_version = "embed-test";
    engine.cancel_flag.store(false, .release);
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [16384]u8 = undefined; // session/new advertises the whole command catalog
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0xabc };

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":9}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"name\":\"graff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "embed-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"authMethods\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "graff-login") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"type\":\"terminal\"") != null);

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expectEqualStrings("acp-abc-1", d.session_id.?);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "available_commands_update") != null);

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":3,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"ping\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"text\":\"echo:ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"stopReason\":\"end_turn\"") != null);
}

test "subagent draft updates require explicit client capability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    var dispatch: Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    try handleLine(&dispatch, arena.allocator(), &out, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientCapabilities\":{}}}");
    try std.testing.expect(!dispatch.subagents);
    out = .fixed(&buf);
    try handleLine(&dispatch, arena.allocator(), &out, "{\"id\":2,\"method\":\"initialize\",\"params\":{\"clientCapabilities\":{\"subagents\":{}}}}");
    try std.testing.expect(dispatch.subagents);
    out = .fixed(&buf);
    try handleLine(&dispatch, arena.allocator(), &out, "{\"id\":3,\"method\":\"initialize\",\"params\":{\"clientCapabilities\":{\"subagents\":null}}}");
    try std.testing.expect(!dispatch.subagents);
}

test "background child extension negotiates independently of draft sessions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    var dispatch: Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    try handleLine(&dispatch, arena.allocator(), &out, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientCapabilities\":{\"_meta\":{\"graff/backgroundSubagents\":true}}}}");
    try std.testing.expect(dispatch.background_subagents);
    try std.testing.expect(!dispatch.subagents);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"graff/backgroundSubagents\":true") != null);
    out = .fixed(&buf);
    try handleLine(&dispatch, arena.allocator(), &out, "{\"id\":2,\"method\":\"initialize\",\"params\":{\"clientCapabilities\":{\"_meta\":{\"graff/backgroundSubagents\":false}}}}");
    try std.testing.expect(!dispatch.background_subagents);
}

test "session/new: embeds send no root cwd; a relative client cwd is rejected" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [32768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0x11 };
    try handleLine(&d, state.allocator(), &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"sessionId\":\"acp-11-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"cwd\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "graff/worktree") == null);
    w = .fixed(&buf);
    var live: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0x12, .workspace = .{ .gpa = std.testing.allocator, .io = std.testing.io } };
    try handleLine(&live, state.allocator(), &w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/new\",\"params\":{\"cwd\":\"relative/dir\"}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Session cwd must be an absolute path") != null);
    try std.testing.expect(live.session_id == null);
}

test "in-process embed can still create a second session" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [32768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0x22 };
    try handleLine(&d, a, &w, "{\"id\":1,\"method\":\"session/new\"}");
    try std.testing.expectEqualStrings("acp-22-1", d.session_id.?);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expectEqualStrings("acp-22-2", d.session_id.?);
}

test "ACP effort config validates sessions and values and notifies slash changes" {
    const Fixture = struct {
        level: []const u8 = "medium",
        narrow: bool = false,
        calls: usize = 0,
        fn config(ctx: *anyopaque, _: Allocator) anyerror!?ConfigOption {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const broad = &[_]ConfigValue{ .{ .value = "low", .name = "Low" }, .{ .value = "medium", .name = "Medium" }, .{ .value = "high", .name = "High" } };
            const narrow = &[_]ConfigValue{ .{ .value = "low", .name = "Low" }, .{ .value = "medium", .name = "Medium" } };
            return .{ .currentValue = self.level, .options = if (self.narrow) narrow else broad };
        }
        fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (if (self.narrow) &[_][]const u8{ "low", "medium" } else &[_][]const u8{ "low", "medium", "high" }) |allowed| {
                if (std.mem.eql(u8, value, allowed)) {
                    self.level = allowed;
                    return true;
                }
            }
            return false;
        }
        fn slash(ctx: *anyopaque, _: Allocator, text: []const u8) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, text, "/effort low")) {
                self.level = "low";
                return "effort changed";
            }
            if (std.mem.eql(u8, text, "/model narrow")) {
                self.narrow = true;
                return "model changed";
            }
            return null;
        }
        fn turn(ctx: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return "done";
        }
    };
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var fixture: Fixture = .{};
    var d: Dispatch = .{ .turn = Fixture.turn, .ctx = &fixture, .seed = 1, .config = Fixture.config, .set_config = Fixture.set, .slash = Fixture.slash };
    var buf: [32768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":1,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":\"high\"}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Unknown session ID") != null);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":2,\"method\":\"session/new\"}");
    const setup = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.sliceTo(w.buffered(), '\n'), .{});
    const option = setup.object.get("result").?.object.get("configOptions").?.array.items[0].object;
    try std.testing.expectEqualStrings("thought_level", option.get("category").?.string);
    try std.testing.expectEqualStrings("medium", option.get("currentValue").?.string);
    try std.testing.expectEqual(@as(usize, 3), option.get("options").?.array.items.len);
    for ([_][]const u8{
        "{\"id\":3,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"wrong\",\"configId\":\"thought_level\",\"value\":\"high\"}}",
        "{\"id\":4,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"other\",\"value\":\"high\"}}",
        "{\"id\":5,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":\"ultra\"}}",
        "{\"id\":6,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":true}}",
    }) |request| {
        w = .fixed(&buf);
        try handleLine(&d, a, &w, request);
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"code\":-32602") != null);
        try std.testing.expectEqualStrings("medium", fixture.level);
    }
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":7,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":\"high\"}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"currentValue\":\"high\"") != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":8,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/effort low\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "config_option_update") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"currentValue\":\"low\"") != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":9,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/model narrow\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "config_option_update") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"value\":\"high\"") == null);
}

test "authenticate names the out-of-band terminal login" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    try handleLine(&d, state.allocator(), &w, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"authenticate\",\"params\":{\"methodId\":\"graff-login\"}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "graff login") != null);
}

test "stripSgr drops CSI sequences" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("ok", try stripSgr(state.allocator(), "\x1b[2mok\x1b[0m"));
}

test "ACP failure carries its reason without claiming completion and the next prompt still works" {
    const Fixture = struct {
        fn fail(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            return error.ApiError;
        }
        fn message(_: *anyopaque, _: anyerror) []const u8 {
            return "Connection closed after tool results";
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var dispatch: Dispatch = .{ .turn = Fixture.fail, .ctx = undefined, .error_message = Fixture.message };
    const request = "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"check\"}]}}";
    try handleLine(&dispatch, arena.allocator(), &writer, request);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Connection closed after tool results") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "stopReason") == null);
    writer = .fixed(&buf);
    dispatch.turn = echoTurn;
    try handleLine(&dispatch, arena.allocator(), &writer, request);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "end_turn") != null);
}
