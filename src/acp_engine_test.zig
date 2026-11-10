//! acp_engine.zig's prompt/meter ordering tests (split for the 600-line cap).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");
const acp = @import("acp.zig");
const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const Dispatch = engine.Dispatch;
const Meter = engine.Meter;
const handleLine = engine.handleLine;

test "ACP steering extension advertises in both versions and idle calls require a prompt" {
    const v2 = @import("acp_v2.zig");
    defer v2.resetForTest();
    const Fixture = struct {
        fn load(_: *anyopaque, _: Allocator, _: *Io.Writer, _: @import("acp_protocol.zig").Request) anyerror!void {}
        fn turn(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            return error.SteeringMustNotStartATurn;
        }
    };
    for ([_]bool{ false, true }) |draft| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var out: Io.Writer.Allocating = .init(a);
        var d: Dispatch = .{ .turn = Fixture.turn, .ctx = undefined, .load_session = Fixture.load };
        try intentInit(&d, a, &out.writer, draft);
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "\"_meta\":{\"steering\":{\"supported\":true}}") != null);
        d.session_id = "s";
        out.clearRetainingCapacity();
        try handleLine(&d, a, &out.writer, "{\"id\":3,\"method\":\"_session/steering\",\"params\":{\"sessionId\":\"s\",\"prompt\":\"follow-up\"}}");
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "\"outcome\":\"promptRequired\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "session/update") == null);
        out.clearRetainingCapacity();
        try handleLine(&d, a, &out.writer, "{\"id\":4,\"method\":\"_session/steering\",\"params\":{\"sessionId\":\"other\",\"prompt\":\"wrong session\"}}");
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "Unknown session ID") != null);
    }
}

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

test "explicit command intent metadata preserves legacy defaults and rejects malformed flags" {
    const selected = @import("acp_command_intent.zig").selected;
    const Case = struct { json: []const u8, commands: bool };
    const cases = [_]Case{
        .{ .json = "null", .commands = true },
        .{ .json = "[]", .commands = true },
        .{ .json = "false", .commands = true },
        .{ .json = "{}", .commands = true },
        .{ .json = "{\"harness/command\":false}", .commands = true },
        .{ .json = "{\"_meta\":null}", .commands = true },
        .{ .json = "{\"_meta\":false}", .commands = true },
        .{ .json = "{\"_meta\":[]}", .commands = true },
        .{ .json = "{\"_meta\":{}}", .commands = true },
        .{ .json = "{\"_meta\":{\"other\":false}}", .commands = true },
        .{ .json = "{\"_meta\":{\"harness/command\":true}}", .commands = true },
        .{ .json = "{\"_meta\":{\"harness/command\":false}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":null}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":\"true\"}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":\"false\"}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":0}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":1}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":1.5}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":[]}}", .commands = false },
        .{ .json = "{\"_meta\":{\"harness/command\":{}}}", .commands = false },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(selected(null));
    for (cases) |case| {
        const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), case.json, .{});
        try std.testing.expectEqual(case.commands, selected(params));
    }
}

const IntentFixture = struct {
    turns: usize = 0,
    slashes: usize = 0,
    inserted: usize = 0,
    last: []const u8 = "",

    fn turn(ctx: *anyopaque, _: Allocator, text: []const u8) anyerror![]const u8 {
        const self: *IntentFixture = @ptrCast(@alignCast(ctx));
        self.turns += 1;
        self.last = text;
        return "model answered";
    }
    fn slash(ctx: *anyopaque, _: Allocator, text: []const u8) anyerror!?[]const u8 {
        const self: *IntentFixture = @ptrCast(@alignCast(ctx));
        self.slashes += 1;
        if (std.mem.eql(u8, text, "/fail")) return error.ApiError;
        return if (std.mem.startsWith(u8, text, "/")) "command executed" else null;
    }
    fn after(ctx: *anyopaque, _: Allocator, _: []const u8, _: ?std.json.Value) void {
        const self: *IntentFixture = @ptrCast(@alignCast(ctx));
        self.inserted += 1;
    }
};

fn intentInit(d: *Dispatch, a: Allocator, w: *Io.Writer, draft: bool) !void {
    const v2 = @import("acp_v2.zig");
    v2.resetForTest();
    v2.gate = draft;
    try handleLine(d, a, w, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":2,\"capabilities\":{},\"info\":{\"name\":\"test\",\"version\":\"1\"}}}");
    try std.testing.expectEqual(draft, v2.on());
}

fn intentPrompt(d: *Dispatch, a: Allocator, w: *Io.Writer, text: []const u8, suffix: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(a, text, .{});
    const request = try std.fmt.allocPrint(a, "{{\"id\":2,\"method\":\"session/prompt\",\"params\":{{\"prompt\":[{{\"type\":\"text\",\"text\":{s}}}]{s}}}}}", .{ encoded, suffix });
    try handleLine(d, a, w, request);
}

test "explicit command intent resets across prompts including malformed metadata and command failure v1 v2" {
    defer @import("acp_v2.zig").resetForTest();
    const Case = struct { text: []const u8 = "/help", suffix: []const u8, commands: bool };
    const cases = [_]Case{
        .{ .suffix = ",\"_meta\":{\"harness/command\":false}", .commands = false },
        .{ .suffix = "", .commands = true },
        .{ .suffix = ",\"_meta\":{\"harness/command\":null}", .commands = false },
        .{ .suffix = ",\"_meta\":{\"harness/command\":true}", .commands = true },
        .{ .suffix = ",\"_meta\":{\"harness/command\":\"true\"}", .commands = false },
        .{ .suffix = ",\"_meta\":null", .commands = true },
        .{ .suffix = ",\"_meta\":{\"harness/command\":1}", .commands = false },
        .{ .text = "/fail", .suffix = ",\"_meta\":{\"harness/command\":true}", .commands = true },
        .{ .suffix = ",\"_meta\":{\"harness/command\":false}", .commands = false },
        .{ .suffix = ",\"_meta\":{}", .commands = true },
    };
    for ([_]bool{ false, true }) |draft| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var out: Io.Writer.Allocating = .init(a);
        var fixture: IntentFixture = .{};
        var d: Dispatch = .{ .turn = IntentFixture.turn, .slash = IntentFixture.slash, .after_user = IntentFixture.after, .ctx = &fixture };
        try intentInit(&d, a, &out.writer, draft);
        var turns: usize = 0;
        var slashes: usize = 0;
        for (cases) |case| {
            out.clearRetainingCapacity();
            try intentPrompt(&d, a, &out.writer, case.text, case.suffix);
            try std.testing.expectEqual(case.commands, d.commands);
            if (case.commands) slashes += 1 else turns += 1;
            try std.testing.expectEqual(turns, fixture.turns);
            try std.testing.expectEqual(slashes, fixture.slashes);
            try std.testing.expectEqual(turns, fixture.inserted);
            if (!case.commands) try std.testing.expectEqualStrings(case.text, fixture.last);
            const output = out.writer.buffered();
            if (std.mem.eql(u8, case.text, "/fail")) {
                try std.testing.expect(std.mem.indexOf(u8, output, "ApiError") != null);
            } else {
                try std.testing.expect(std.mem.indexOf(u8, output, "end_turn") != null);
                const expected = if (case.commands) "command executed" else "model answered";
                try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
            }
        }
    }
}

test "explicit command intent preserves known commands UTF8 Markdown and whitespace byte for byte v1 v2" {
    defer @import("acp_v2.zig").resetForTest();
    const literals = [_][]const u8{
        "/",                                                      "/help",              "/goal literal objective", "/review literal review", "/issue literal report",
        "/btw literal aside",                                     "/loop literal loop", "/resuem",                 " /help ",                "\t/goal literal\r\n",
        "/help\n**bold** `code` [link](https://example.invalid)",
        "/你好 café e\u{301} 🧪",
        "\n/help\n",                                              "intro\n/help",
    };
    for ([_]bool{ false, true }) |draft| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var out: Io.Writer.Allocating = .init(a);
        var fixture: IntentFixture = .{};
        var d: Dispatch = .{ .turn = IntentFixture.turn, .slash = IntentFixture.slash, .after_user = IntentFixture.after, .ctx = &fixture };
        try intentInit(&d, a, &out.writer, draft);
        for (literals, 0..) |text, i| {
            out.clearRetainingCapacity();
            try intentPrompt(&d, a, &out.writer, text, ",\"_meta\":{\"harness/command\":false}");
            try std.testing.expectEqualStrings(text, fixture.last);
            try std.testing.expectEqual(i + 1, fixture.turns);
            try std.testing.expectEqual(i + 1, fixture.inserted);
            try std.testing.expectEqual(@as(usize, 0), fixture.slashes);
            try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "end_turn") != null);
        }
    }
}

test "explicit command intent cannot bypass agent room framing v1 v2" {
    defer @import("acp_v2.zig").resetForTest();
    for ([_]bool{ false, true }) |draft| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var out: Io.Writer.Allocating = .init(a);
        var fixture: IntentFixture = .{};
        var d: Dispatch = .{ .turn = IntentFixture.turn, .slash = IntentFixture.slash, .ctx = &fixture };
        try intentInit(&d, a, &out.writer, draft);
        for ([_][]const u8{ "false", "true" }) |flag| {
            for ([_][]const u8{ "false", "null", "\"true\"" }) |from_user| {
                const suffix = try std.fmt.allocPrint(a, ",\"_meta\":{{\"harness/command\":{s},\"harness/room\":{{\"room_id\":\"synthetic\",\"from_member\":\"test-agent\",\"from_user\":{s},\"framed\":true}}}}", .{ flag, from_user });
                out.clearRetainingCapacity();
                const before = fixture.turns;
                try intentPrompt(&d, a, &out.writer, "/help", suffix);
                try std.testing.expectEqual(before + 1, fixture.turns);
                try std.testing.expect(std.mem.startsWith(u8, fixture.last, "[room message from test-agent"));
                try std.testing.expect(std.mem.indexOf(u8, fixture.last, "advisory]: /help") != null);
                try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "command executed") == null);
            }
        }
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

test "OpenAI effort menu omits Max and keeps Ultra on the Responses wire" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var root = try @import("agent_request_body_responses.zig").testAgentFor(a, "openai", .responses, "gpt-6-astra");
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    var aw: Io.Writer.Allocating = .init(a);
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = &aw.writer };
    var d: Dispatch = .{ .turn = echoTurn, .ctx = &live, .extra = acp.liveModels };
    const expected = [_][]const u8{ "low", "medium", "high", "xhigh", "ultra" };
    for ([_][]const u8{ "openai", "codex", "codegraff" }) |pid| {
        root.provider.id = pid;
        root.reasoning = .max; // saved Max remains a valid, visible selection
        aw.clearRetainingCapacity();
        try handleLine(&d, a, &aw.writer, "{\"id\":1,\"method\":\"graff/models\"}");
        const result = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.writer.buffered(), .{});
        for (result.object.get("result").?.object.get("models").?.array.items) |row| {
            const fields = row.object;
            try std.testing.expect(fields.get("effortLevels").? == .array);
            try std.testing.expect(fields.get("fastSupported").? == .bool);
        }
        const current = result.object.get("result").?.object.get("current").?.object;
        try std.testing.expectEqualStrings("ultra", current.get("effort").?.string);
        const levels = current.get("effortLevels").?.array.items;
        try std.testing.expectEqual(expected.len, levels.len);
        for (expected, levels) |tag, level| try std.testing.expectEqualStrings(tag, level.string);
        // The last advertised choice must serialize as API max, never ultra.
        root.reasoning = std.meta.stringToEnum(main_mod.ReasoningEffort, levels[levels.len - 1].string).?;
        const body = try root.buildBody(null, false, true, true);
        defer std.testing.allocator.free(body);
        const request = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        try std.testing.expectEqualStrings("max", request.object.get("reasoning").?.object.get("effort").?.string);
        root.reasoning = .xhigh;
        const extra = try root.buildBody(null, false, true, true);
        defer std.testing.allocator.free(extra);
        const extra_request = try std.json.parseFromSliceLeaky(std.json.Value, a, extra, .{});
        try std.testing.expectEqualStrings("xhigh", extra_request.object.get("reasoning").?.object.get("effort").?.string);
    }
}

test "#1814 literal leading slash followed by space is treated as ordinary prompt text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const slash = struct {
        fn run(_: *anyopaque, _: Allocator, text: []const u8) anyerror!?[]const u8 {
            if (@import("command_catalog.zig").match(text) == null and @import("command_catalog.zig").commandWord(text) == null) return null;
            return "unknown command";
        }
    }.run;
    var dispatch: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .slash = slash };
    try handleLine(&dispatch, arena.allocator(), &writer, "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/ widgets are ordinary text\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "echo:/ widgets are ordinary text") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "unknown command") == null);
}
