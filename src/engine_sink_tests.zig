//! The tests for engine_sink.zig, split into a sibling so the boundary itself
//! keeps room to grow (#429; the same `*_tests.zig` shape providers.zig and
//! imagegen.zig already use). They drive the real sinks through the real
//! dispatch, so nothing here is a mock of the thing under test.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const deinitMarkdown = @import("agent_render.zig").deinitMarkdown;

const engine_events = @import("engine_events.zig");
const EngineEvent = engine_events.EngineEvent;
const protocol_seq = @import("protocol_seq.zig");
const repl = @import("repl.zig");
const engine_sink = @import("engine_sink.zig");
const EngineSink = engine_sink.EngineSink;
const VTable = engine_sink.VTable;
const Stamped = engine_sink.Stamped;
const jsonSink = engine_sink.jsonSink;
const tuiSink = engine_sink.tuiSink;
const writerSink = engine_sink.writerSink;

test "dispatch preserves emission order and stamps at the boundary" {
    // emit(undefined, ...) is sound only while json_mode is false (no lock
    // taken): pin it so a leaky earlier test can never turn this into UB.
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var rec: std.ArrayList(Stamped) = .empty;
    defer rec.deinit(std.testing.allocator);
    const vt: VTable = .{ .emit = recordEmit, .durable = true };
    const s: EngineSink = .{ .ctx = &rec, .vt = &vt };
    s.emit(undefined, .stream_begin);
    s.emit(undefined, .{ .reasoning_delta = .{ .text = "think" } });
    s.emit(undefined, .{ .text_delta = .{ .text = "hi" } });
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = true } });
    s.emit(undefined, .stream_finished);
    try std.testing.expectEqual(@as(usize, 5), rec.items.len);
    const want_tags: [5]std.meta.Tag(EngineEvent) = .{
        .stream_begin, .reasoning_delta, .text_delta, .stream_complete, .stream_finished,
    };
    for (want_tags, rec.items) |tag, got| try std.testing.expectEqual(tag, std.meta.activeTag(got.event));
    // Durable deltas reserved fresh ids; pulses ride at the last reserved
    // position — the wire's numbering shows no gap for them.
    const want_seq: [5]u64 = .{ 0, 1, 2, 2, 2 };
    for (want_seq, rec.items) |seq, got| try std.testing.expectEqual(seq, got.cursor.sequence);
    for (rec.items) |got| try std.testing.expectEqual(engine_events.generation(), got.cursor.generation);
}

test "a presentation sink never reserves sequence ids" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var rec: std.ArrayList(Stamped) = .empty;
    defer rec.deinit(std.testing.allocator);
    const vt: VTable = .{ .emit = recordEmit, .durable = false };
    const s: EngineSink = .{ .ctx = &rec, .vt = &vt };
    s.emit(undefined, .{ .text_delta = .{ .text = "hi" } });
    try std.testing.expectEqual(@as(u64, 0), rec.items[0].cursor.sequence);
    try std.testing.expectEqual(@as(u64, 0), protocol_seq.current());
}

/// The Agent shape every sink test renders through: allocator-backed, rooted
/// (not a subagent), writing into the caller's buffer.
fn testAgent(w: *Io.Writer) Agent {
    @import("line_repl_disclosure.zig").reset(std.testing.io);
    return .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = w,
    };
}

fn recordEmit(ctx: *anyopaque, ev: Stamped) void {
    const rec: *std.ArrayList(Stamped) = @ptrCast(@alignCast(ctx));
    rec.append(std.testing.allocator, ev) catch @panic("OOM");
}

test "JsonSink writes today's wire lines byte-for-byte" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const s = jsonSink(&a);
    s.emit(undefined, .{ .reasoning_delta = .{ .text = "why" } });
    s.emit(undefined, .{ .text_delta = .{ .text = "hi\n" } });
    s.emit(undefined, .stream_begin); // pulses have no wire shape
    // End-of-stream flushes the held render tail (old-path parity); with
    // clean md state that adds no bytes and emits no wire line.
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = true } });
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"type\":\"reasoning\",\"text\":\"why\"}\n{\"seq\":2,\"type\":\"text\",\"text\":\"hi\\n\"}\n",
        aw.writer.buffered(),
    );
}

test "TuiSink streams tool-arg prose raw and never ends the answer line (slice 1b)" {
    const saved_color = main_mod.use_color; // pin the no-color branch
    main_mod.use_color = false;
    defer main_mod.use_color = saved_color;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const s = tuiSink(&a);
    s.emit(undefined, .{ .tool_arg_delta = .{ .text = "answer " } });
    s.emit(undefined, .{ .tool_arg_delta = .{ .text = "prose" } });
    // Exactly the bytes, flushed per delta, no separators added — the old
    // inline emitArgText no-color branch.
    try std.testing.expectEqualStrings("answer prose", aw.writer.buffered());
}

test "TuiSink transport-abort notices only when the turn is ending (ADR 0021)" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const s = tuiSink(&a);
    const cases = [_]struct { ev: engine_events.TransportAbort, want: []const u8 }{
        .{ .ev = .{ .reason = .stalled, .turn_ending = false }, .want = "" },
        .{ .ev = .{ .reason = .stalled, .turn_ending = true }, .want = "\n⚠ stream stalled — ending turn\n" },
        .{ .ev = .{ .reason = .dropped, .turn_ending = false }, .want = "" },
        .{ .ev = .{ .reason = .dropped, .turn_ending = true }, .want = "\n⚠ connection dropped — response ended early\n" },
        // A deliberate interrupt was never announced at the transport layer.
        .{ .ev = .{ .reason = .interrupted, .turn_ending = true }, .want = "" },
    };
    for (cases) |c| {
        aw.clearRetainingCapacity();
        s.emit(undefined, .{ .transport_aborted = c.ev });
        try std.testing.expectEqualStrings(c.want, aw.writer.buffered());
    }
}

test "stall reconnect is not announced on the transcript (ADR 0021)" {
    const src = @embedFile("agent_request.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "[{s} — reconnecting") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "reconnecting{s}") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tr.note(\"stream_retry\"") != null);
}

test "JsonSink stays silent for moments the wire never carried (slice 1b)" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const s = jsonSink(&a);
    s.emit(undefined, .{ .tool_arg_delta = .{ .text = "prose" } });
    s.emit(undefined, .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = true } });
    s.emit(undefined, .{ .transport_aborted = .{ .reason = .dropped, .turn_ending = false } });
    // No wire line AND no sequence id burned: both stay pulses, so the
    // wire's gap-free numbering is untouched by them (#330).
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    try std.testing.expectEqual(@as(u64, 0), protocol_seq.current());
}

test "JsonSink writes the tool bracket byte-for-byte, in wire order (slice 1c)" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const s = jsonSink(&a);

    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"path\":\"fixture.txt\"}", .{});
    const call: engine_events.ToolInvocation = .{ .name = "read_file", .input = input };
    const done: engine_events.ToolOutcome = .{ .name = "read_file", .text = "hi", .is_error = false, .ms = 7 };
    s.emit(undefined, .{ .tool_call_announced = call });
    s.emit(undefined, .{ .tool_call_started = call });
    s.emit(undefined, .{ .tool_result = done });
    s.emit(undefined, .{ .tool_call_finished = done });
    s.emit(undefined, .{ .tool_rejected = .{ .name = "bash", .input = input, .reason = "budget", .message = "no" } });
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"type\":\"tool_call\",\"name\":\"read_file\",\"input\":{\"path\":\"fixture.txt\"}}\n" ++
            "{\"seq\":2,\"type\":\"tool_call_started\",\"name\":\"read_file\",\"input\":{\"path\":\"fixture.txt\"}}\n" ++
            "{\"seq\":3,\"type\":\"tool_result\",\"name\":\"read_file\",\"is_error\":false,\"text\":\"hi\"}\n" ++
            "{\"seq\":4,\"type\":\"tool_call_finished\",\"name\":\"read_file\",\"is_error\":false,\"ms\":7}\n" ++
            "{\"seq\":5,\"type\":\"tool_rejected\",\"name\":\"bash\",\"reason\":\"budget\",\"input\":{\"path\":\"fixture.txt\"},\"message\":\"no\"}\n",
        aw.writer.buffered(),
    );
}

test "JsonSink drops ask_user's bracket and a meta result without burning ids (slice 1c)" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const s = jsonSink(&a);

    const ask: engine_events.ToolInvocation = .{ .name = "ask_user", .input = .null, .ask_user = true };
    s.emit(undefined, .{ .tool_call_announced = ask }); // the wire's `ask_user` event carries this moment
    s.emit(undefined, .{ .tool_call_started = ask });
    s.emit(undefined, .{ .tool_result = .{ .name = "todo_write", .text = "todos", .is_error = false, .meta = true } });
    s.emit(undefined, .{ .parallel_batch_started = .{ .count = 2 } }); // TUI-only notices
    s.emit(undefined, .completion_deferred);
    s.emit(undefined, .{ .completion_text = .{ .text = "done" } });
    // No line AND no id spent: the wire's numbering stays gap-free (#330).
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    try std.testing.expectEqual(@as(u64, 0), protocol_seq.current());

    // ask_user's own RESULT is on the wire, though — the typed reply is it.
    s.emit(undefined, .{ .tool_result = .{ .name = "ask_user", .text = "yes", .is_error = false, .meta = true, .ask_user = true } });
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"type\":\"tool_result\",\"name\":\"ask_user\",\"is_error\":false,\"text\":\"yes\"}\n",
        aw.writer.buffered(),
    );
}

test "a frontendless agent's wire sink burns no ids for the lines it cannot write (#330)" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    a.out = null; // a pool-thread subagent, or the ACP root: nowhere to write
    const s = jsonSink(&a);
    try std.testing.expect(!s.vt.durable); // the guarantee is structural, not per-call-site

    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"path\":\"f\"}", .{});
    const call: engine_events.ToolInvocation = .{ .name = "read_file", .input = input };
    const done: engine_events.ToolOutcome = .{ .name = "read_file", .text = "hi", .is_error = false };
    s.emit(undefined, .{ .tool_call_announced = call });
    s.emit(undefined, .{ .tool_call_started = call });
    s.emit(undefined, .{ .tool_result = done });
    s.emit(undefined, .{ .tool_call_finished = done });
    s.emit(undefined, .{ .tool_rejected = .{ .name = "bash", .input = input, .reason = "budget", .message = "no" } });
    s.emit(undefined, .{ .text_delta = .{ .text = "hi" } });
    // Every one of those would have been a wire line for a rooted agent. With
    // no writer there is no line, so there must be no id either: a supervisor
    // reads a gap as lost data.
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    try std.testing.expectEqual(@as(u64, 0), protocol_seq.current());
}

test "TuiSink shows tool one-liners with args and a result preview (slice 1c)" {
    const saved_color = main_mod.use_color;
    main_mod.use_color = false;
    defer main_mod.use_color = saved_color;
    const saved_json = main_mod.json_mode; // sayText's root gate reads it
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    const saved_debug = repl.g_debug;
    repl.g_debug = false;
    defer repl.g_debug = saved_debug;
    const ansi = @import("ansi.zig");
    const saved_style = ansi.style;
    ansi.style = .{}; // assert the text, not the palette
    defer ansi.style = saved_style;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const s = tuiSink(&a);

    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"path\":\"fixture.txt\"}", .{});
    const call: engine_events.ToolInvocation = .{ .name = "read_file", .input = input };
    const done: engine_events.ToolOutcome = .{ .name = "read_file", .text = "line one\nline two\n", .is_error = false };
    s.emit(undefined, .{ .tool_call_announced = call });
    s.emit(undefined, .{ .tool_result = done });
    try std.testing.expectEqualStrings("  ✓ read  fixture.txt  2 lines  ↵ raw\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    s.emit(undefined, .{ .tool_call_announced = call });
    s.emit(undefined, .{ .tool_call_started = call }); // silent: the ✓ line is the record
    s.emit(undefined, .{ .tool_result = done });
    s.emit(undefined, .{ .tool_call_finished = done }); // silent
    s.emit(undefined, .{ .tool_rejected = .{ .name = "bash", .input = input, .reason = "budget", .message = "no" } }); // silent
    try std.testing.expectEqualStrings("  ✓ read  fixture.txt  2 lines  ↵ raw\n", aw.writer.buffered());
}

test "TuiSink renders a plain text delta exactly as the no-color TTY did" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    defer deinitMarkdown(&a);
    const s = tuiSink(&a);
    s.emit(undefined, .{ .text_delta = .{ .text = "plain\n" } });
    try std.testing.expectEqualStrings("plain\n", aw.writer.buffered());
    // Normal end after streamed text: the separating newline, as before.
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = true } });
    try std.testing.expectEqualStrings("plain\n\n", aw.writer.buffered());
}

const UrlSettlement = enum { newline, stream_complete };
const UrlDeltaCase = struct {
    chunks: []const []const u8,
    want_line: []const u8,
};

const url_delta_cases = [_]UrlDeltaCase{
    // Direct wrappers: their punctuation remains visible but outside the URL.
    .{ .chunks = &.{ "*", "https://exam", "ple.com/a", "*." }, .want_line = "https://example.com/a.\n" },
    .{ .chunks = &.{ "*", "*https://example.com", "/b*", "*," }, .want_line = "https://example.com/b,\n" },
    .{ .chunks = &.{ "_https", "://example.com/c_", ";" }, .want_line = "https://example.com/c;\n" },
    .{ .chunks = &.{ "_", "_https://example.com/d", "_", "_:" }, .want_line = "https://example.com/d:\n" },
    .{ .chunks = &.{ "~", "~https://example.com/e~", "~!" }, .want_line = "https://example.com/e!\n" },
    .{ .chunks = &.{ "`https://", "example.com/f", "`?" }, .want_line = "https://example.com/f?\n" },

    // Without an opener, legal marker tails and interiors belong to the URL.
    .{ .chunks = &.{ "https://example.com/gl", "ob/**", " next" }, .want_line = "https://example.com/glob/** next\n" },
    .{ .chunks = &.{ "https://example.com/path/", "__" }, .want_line = "https://example.com/path/__\n" },
    .{ .chunks = &.{ "https://example.com/path/~", "~" }, .want_line = "https://example.com/path/~~\n" },
    .{ .chunks = &.{ "https://example.com/search?", "q=*" }, .want_line = "https://example.com/search?q=*\n" },
    .{ .chunks = &.{ "https://docs.python.org/3/reference/", "datamodel.html#object.__init__" }, .want_line = "https://docs.python.org/3/reference/datamodel.html#object.__init__\n" },
    .{ .chunks = &.{ "https://example.com/a*", "*b" }, .want_line = "https://example.com/a**b\n" },
};

fn expectUrlDeltaCase(settlement: UrlSettlement, c: UrlDeltaCase) !void {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    defer deinitMarkdown(&a);
    const s = tuiSink(&a);

    for (c.chunks) |chunk| s.emit(undefined, .{ .text_delta = .{ .text = chunk } });
    switch (settlement) {
        .newline => s.emit(undefined, .{ .text_delta = .{ .text = "\n" } }),
        .stream_complete => s.emit(undefined, .{ .stream_complete = .{ .streamed_text = false } }),
    }
    const want = switch (settlement) {
        .newline => c.want_line,
        .stream_complete => c.want_line[0 .. c.want_line.len - 1],
    };
    try std.testing.expectEqualStrings(want, aw.writer.buffered());
}

test "TuiSink settles no-color URL markers outside visible targets (#729)" {
    const saved_color = main_mod.use_color;
    main_mod.use_color = false;
    defer main_mod.use_color = saved_color;
    const ansi = @import("ansi.zig");
    const saved_style = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved_style;

    for (url_delta_cases) |c| {
        try expectUrlDeltaCase(.newline, c);
        try expectUrlDeltaCase(.stream_complete, c);
    }
}

const swap: engine_events.ProviderFallback = .{
    .from_provider = "codex",
    .from_model = "gpt-5.5",
    .to_provider = "anthropic",
    .to_model = "claude-sonnet-5",
    .to_context = 200_000,
    .context_note = "context kept",
};

test "slice 2: the lifecycle sink draws through a plain writer and reserves nothing" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    const ansi = @import("ansi.zig");
    const saved_style = ansi.style;
    ansi.style = .{}; // assert the text, not the palette
    defer ansi.style = saved_style;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const s = writerSink(&aw.writer);
    s.emit(undefined, .{ .session_notice = .{ .text = "loaded 3 saved approval(s)", .tone = .dim } });
    s.emit(undefined, .{ .session_saved = .{ .name = "session-9", .ext = ".session.json" } });
    s.emit(undefined, .{ .provider_fallback = swap });
    try std.testing.expectEqualStrings(
        "loaded 3 saved approval(s)\n" ++
            "↩ session saved → session-9.session.json\n" ++
            "⚠ gpt-5.5 via codex is unavailable; trying claude-sonnet-5 via anthropic for this session (context kept) — saved default kept\n",
        aw.writer.buffered(),
    );
    // Presentation, all of it: the wire's numbering is untouched even though
    // the failover IS a durable event on the sink that owns the wire (#330).
    try std.testing.expectEqual(@as(u64, 0), protocol_seq.current());
}

test "slice 2: JsonSink writes the failover as today's `model` line, not the terminal's" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    jsonSink(&a).emit(undefined, .{ .provider_fallback = swap });
    // The literal a --json client has always received, `note` and all — the
    // wire's note, not the payload's context_note.
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"type\":\"model\",\"ok\":true,\"provider\":\"anthropic\",\"model\":\"claude-sonnet-5\"," ++
            "\"context\":200000,\"note\":\"automatic session fallback; saved model preference kept\"}\n",
        aw.writer.buffered(),
    );
    // A lifecycle pulse still has no wire shape and still burns no id.
    aw.clearRetainingCapacity();
    jsonSink(&a).emit(undefined, .{ .session_banner = .{ .cwd = "/repo", .trace_path = "t" } });
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    try std.testing.expectEqual(@as(u64, 1), protocol_seq.current());
}

test "slice 2: forSession picks the wire in --json and the caller's writer otherwise" {
    const saved_json = main_mod.json_mode;
    defer main_mod.json_mode = saved_json;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    main_mod.json_mode = true;
    try std.testing.expect(engine_sink.forSession(&a, null).vt.durable); // the wire, which reserves ids
    main_mod.json_mode = false;
    try std.testing.expect(!engine_sink.forSession(&a, &aw.writer).vt.durable); // the terminal, which does not
    // An injected sink still wins, as it does for forAgent.
    const vt: VTable = .{ .emit = recordEmit, .durable = true };
    var rec: std.ArrayList(Stamped) = .empty;
    defer rec.deinit(std.testing.allocator);
    a.sink = .{ .ctx = &rec, .vt = &vt };
    try std.testing.expectEqual(@as(*const VTable, &vt), engine_sink.forSession(&a, null).vt);
}

test "hosted frontend announces read path and result preview" {
    const saved = engine_sink.hosted_frontend;
    engine_sink.hosted_frontend = true;
    defer engine_sink.hosted_frontend = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const sink = tuiSink(&a);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"path\":\"src/foo.zig\"}", .{});
    sink.emit(undefined, .{ .tool_call_announced = .{ .name = "read_file", .input = input } });
    sink.emit(undefined, .{ .tool_result = .{ .name = "read_file", .text = "const std = @import(\"std\");\nmore", .is_error = false } });
    const got = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "⚙ read src/foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "✓ read | const std") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "read_file") == null);
}
