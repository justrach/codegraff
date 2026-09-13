//! Stream-termination fixtures kept out of the transport implementation.

const std = @import("std");
const Kind = @import("provider.zig").Provider.Kind;

pub fn reasoningBoundaries() !void {
    const a = std.testing.allocator;
    const tui = @import("tui");
    const tui_sink = @import("tui_sink.zig");
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = std.testing.io };
    defer client.deinit();
    var queue: tui.EventQueue = .{};
    queue.attach(a);
    defer queue.deinit();
    var buf: [2048]u8 = undefined;
    var stream: @import("repl.zig").StreamBuf = .{ .buf = &buf };
    var bridge: tui_sink.Bridge = .{ .queue = &queue, .stream = &stream, .show_thinking = true };
    var agent: @import("agent.zig").Agent = .{
        .gpa = a,
        .arena = arena_state.allocator(),
        .io = std.testing.io,
        .client = &client,
        .provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 0 },
        .messages = std.json.Array.init(arena_state.allocator()),
        .sink = tui_sink.forBridge(&bridge),
        .sub = false,
        .label = "test",
        .out = null,
    };
    // Also exercise the classic REPL's actual "▼ Thinking" writer, not just
    // the fullscreen frontend's live buffer.
    const engine_sink = @import("engine_sink.zig");
    const main = @import("main.zig");
    const tick_gate = @import("tick_gate.zig");
    const saved_color = main.use_color;
    const saved_hosted = engine_sink.hosted_frontend;
    const saved_open = main.g_thinking_open;
    const saved_gate = tick_gate.g_gate;
    defer {
        main.use_color = saved_color;
        engine_sink.hosted_frontend = saved_hosted;
        main.g_thinking_open = saved_open;
        tick_gate.g_gate = saved_gate;
    }
    main.use_color = true;
    engine_sink.hosted_frontend = false;
    var rendered: std.Io.Writer.Allocating = .init(a);
    defer rendered.deinit();
    var plain_agent = agent;
    plain_agent.out = &rendered.writer;
    plain_agent.sink = engine_sink.tuiSink(&plain_agent);
    plain_agent.show_thinking = true;
    defer plain_agent.thinking_text.deinit(a);
    const agents = [_]*@import("agent.zig").Agent{ &agent, &plain_agent };
    const dispatch = struct {
        fn send(receivers: []const *@import("agent.zig").Agent, line: []const u8) void {
            for (receivers) |receiver| @import("agent_stream.zig").printDelta(receiver, line);
        }
    }.send;
    // Two parts in one item, then a new item, then a new response. Split
    // inside emphasis as well as words: transport chunks are not paragraphs.
    const headings = [_][]const u8{ "First", "Second", "Third", "Fourth" };
    for (headings, 0..) |heading, i| {
        if (i == 3) dispatch(&agents, "data: {\"type\":\"response.created\"}");
        if (i != 1) dispatch(&agents, "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\"}}");
        dispatch(&agents, "data: {\"type\":\"response.reasoning_summary_part.added\",\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}");
        for ([_][]const u8{ "*", "*", heading, " heading", "**" }) |chunk| {
            const line = try std.fmt.allocPrint(a, "data: {{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"{s}\"}}", .{chunk});
            defer a.free(line);
            dispatch(&agents, line);
        }
        dispatch(&agents, "data: {\"type\":\"response.reasoning_summary_text.done\",\"text\":\"synthetic completed summary\"}");
        dispatch(&agents, "data: {\"type\":\"response.reasoning_summary_part.done\",\"part\":{\"type\":\"summary_text\",\"text\":\"synthetic completed summary\"}}");
        if (i != 0) dispatch(&agents, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"encrypted_content\":\"synthetic opaque value\"}}");
        if (i >= 2) dispatch(&agents, "data: {\"type\":\"response.completed\"}");
    }
    dispatch(&agents, "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"synthetic private text\"}");
    dispatch(&agents, "data: {\"type\":\"response.reasoning_summary_text.done\",\"text\":\"\"}");
    const snap = stream.snapshot(a) orelse return error.NoStream;
    defer a.free(snap);
    try std.testing.expectEqualStrings("**First heading**\n\n**Second heading**\n\n**Third heading**\n\n**Fourth heading**\n\n", snap);
    try std.testing.expectEqualStrings(snap, plain_agent.thinking_text.items);
    try std.testing.expect(std.mem.indexOf(u8, rendered.written(), "▼ Thinking") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered.written(), snap));

    var term: tui.sim.Term = undefined;
    term.init(a, 80, 24);
    defer term.deinit();
    const Job = std.meta.Child(std.meta.Child(@TypeOf(term.model.pending)));
    var job: Job = .{
        .gpa = a,
        .history = &.{},
        .params = .{},
        .stream = .{ .buf = &buf },
        .threaded = false,
    };
    job.stream.appendBytes(snap);
    try term.model.push(.pending, "");
    term.model.pending = &job;
    defer term.model.pending = null;
    const visible = try term.screen();
    defer a.free(visible);
    var lines = std.mem.splitScalar(u8, visible, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " heading") != null) {
            try std.testing.expect(seen < headings.len);
            try std.testing.expect(std.mem.indexOf(u8, line, headings[seen]) != null);
            try std.testing.expect(std.mem.count(u8, line, " heading") == 1);
            try std.testing.expect(std.mem.indexOf(u8, line, "**") == null);
            seen += 1;
        }
    }
    try std.testing.expectEqual(headings.len, seen);
}

pub fn streamEnd(is_stream_end: anytype) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // OpenAI/Responses [DONE] sentinel; content merely containing it must not end the stream.
    try std.testing.expect(is_stream_end(arena, Kind.openai, "data: [DONE]"));
    try std.testing.expect(!is_stream_end(arena, Kind.openai, "data: {\"choices\":[{\"delta\":{\"content\":\"[DONE]\"}}]}"));
    // Anthropic event and data payload terminate; a delta with the word does not.
    try std.testing.expect(is_stream_end(arena, Kind.anthropic, "event: message_stop"));
    try std.testing.expect(is_stream_end(arena, Kind.anthropic, "data: {\"type\":\"message_stop\"}"));
    try std.testing.expect(!is_stream_end(arena, Kind.anthropic, "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"message_stop\"}}"));
    // Responses: the event: name is not the end — usage is on the data line.
    try std.testing.expect(!is_stream_end(arena, Kind.responses, "event: response.completed"));
    try std.testing.expect(is_stream_end(arena, Kind.responses, "data: {\"type\":\"response.completed\"}"));
    try std.testing.expect(is_stream_end(arena, Kind.responses, "data: {\"type\":\"response.incomplete\"}"));
    try std.testing.expect(!is_stream_end(arena, Kind.responses, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}"));
    // OpenAI null finish reasons and reasoning deltas remain mid-stream.
    try std.testing.expect(!is_stream_end(arena, Kind.openai, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}"));
    try std.testing.expect(!is_stream_end(arena, Kind.openai, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"));
}

pub fn openaiCompletion(openai_complete: anytype) !void {
    try std.testing.expect(openai_complete("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"));
    try std.testing.expect(openai_complete("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}"));
    try std.testing.expect(!openai_complete("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}"));
    try std.testing.expect(!openai_complete("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"));
    // Escaped content must not false-match a finish_reason field.
    try std.testing.expect(!openai_complete("data: {\"choices\":[{\"delta\":{\"content\":\"\\\"finish_reason\\\":\\\"x\"}}]}"));
}
