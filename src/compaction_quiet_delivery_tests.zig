//! A compaction request runs tools-off and its reply is discarded once the
//! compaction item is installed. That reply must never reach a frontend as an
//! answer: not the terminal, not the --json wire, not ACP (#1582).

const std = @import("std");
const Io = std.Io;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const engine_sink = @import("engine_sink.zig");
const deinitMarkdown = @import("agent_render.zig").deinitMarkdown;

const text_line = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"I do not have terminal tools.\"}";
const reasoning_line = "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"maintenance thoughts\"}";

fn wireAgent(w: *Io.Writer) Agent {
    @import("line_repl_disclosure.zig").reset(std.testing.io);
    return .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 0 },
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = w,
    };
}

test "a compaction reply never reaches the --json wire that ACP translates" {
    const saved_json = main_mod.json_mode;
    defer main_mod.json_mode = saved_json;
    main_mod.json_mode = true;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = wireAgent(&aw.writer);
    defer deinitMarkdown(&a);
    a.stream_quiet = true;
    a.compaction_request = true;
    a.printDelta(reasoning_line);
    a.printDelta(text_line);
    try std.testing.expectEqualStrings("", aw.written());
    try std.testing.expect(!a.streamed_text);
    @import("agent_model_loop.zig").emitText(&a, "stopped: model loop");
    try std.testing.expectEqualStrings("", aw.written());

    // The ordinary request after it still streams.
    a.stream_quiet = false;
    a.compaction_request = false;
    a.printDelta(reasoning_line);
    a.printDelta(text_line);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"type\":\"reasoning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "I do not have terminal tools.") != null);
    try std.testing.expect(a.streamed_text);
}

fn record(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const count: *usize = @ptrCast(@alignCast(ctx));
    switch (ev.event) {
        .reasoning_delta, .text_delta => count.* += 1,
        else => {},
    }
}

test "an injected frontend sink sees no compaction prose either" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = wireAgent(&aw.writer);
    defer deinitMarkdown(&a);
    var seen: usize = 0;
    const vt: engine_sink.VTable = .{ .emit = record, .durable = false };
    a.sink = .{ .ctx = &seen, .vt = &vt };
    a.compaction_request = true;
    a.printDelta(reasoning_line);
    a.printDelta(text_line);
    try std.testing.expectEqual(@as(usize, 0), seen);
    a.compaction_request = false;
    a.printDelta(text_line);
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "compaction maintenance neither paints stdout nor leaves a recoverable partial answer (#1582)" {
    const saved = .{ main_mod.json_mode, main_mod.unattended, main_mod.g_out };
    defer {
        main_mod.json_mode, main_mod.unattended, main_mod.g_out = saved;
    }
    main_mod.json_mode = false;
    main_mod.unattended = true;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    main_mod.g_out = &aw.writer;
    var a = wireAgent(&aw.writer);
    defer deinitMarkdown(&a);
    defer a.partial_text.deinit(std.testing.allocator);
    a.out = null;
    a.compaction_request = true;
    var stream: @import("agent_model_loop.zig").Stream = .{};
    try stream.event(&a, text_line["data: ".len..], false);
    a.printDelta(reasoning_line);
    a.printDelta(text_line);
    try std.testing.expectEqualStrings("", a.partial_text.items);
    try std.testing.expectEqualStrings("", aw.written());
    try std.testing.expect(!a.streamed_text);

    a.compaction_request = false;
    const final = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Ordinary answer.\"}";
    try stream.event(&a, final["data: ".len..], false);
    a.printDelta(final);
    try std.testing.expectEqualStrings("Ordinary answer.", a.partial_text.items);
    try std.testing.expectEqualStrings("Ordinary answer.", aw.written());
}

test "in-stream server compaction preserves session tools, effort, and verbosity for encrypted state parity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = a,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-6.1-sol", .context = 500_000 },
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "t",
        .out = null,
        .reasoning = .high,
        .tools_responses = "[{\"type\":\"function\",\"name\":\"shell\",\"parameters\":{\"type\":\"object\"}}]",
        .compaction_request = true,
        .server_compaction_request = true,
    };
    const body = try agent.buildBody(agent.toolsJson(), false, true, true);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"verbosity\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"none\"") != null);
    agent.compaction_request = false;
    agent.server_compaction_request = false;
    const followup = try agent.buildBody(agent.toolsJson(), false, true, true);
    defer a.free(followup);
    try std.testing.expect(std.mem.indexOf(u8, followup, "\"name\":\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, followup, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"compact_threshold\":1000") != null);
}
