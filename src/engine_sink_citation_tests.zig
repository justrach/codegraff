//! Citation regressions through the actual Agent-backed sink dispatch (#874).
const std = @import("std");
const Io = std.Io;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const engine_sink = @import("engine_sink.zig");
const EngineEvent = @import("engine_events.zig").EngineEvent;
const EngineSink = engine_sink.EngineSink;
const deinitMarkdown = @import("agent_render.zig").deinitMarkdown;
const protocol_seq = @import("protocol_seq.zig");

const citation = "citeturn0search0turn1search2";
const raw = "left" ++ citation ++ "right\n";
const clean = "leftright\n";
const Channel = enum { answer, reasoning, arg };

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
        .show_thinking = true,
    };
}

fn cleanup(a: *Agent) void {
    engine_sink.tuiSink(a).emit(undefined, .stream_finished);
    deinitMarkdown(a);
    a.thinking_text.deinit(std.testing.allocator);
}

fn delta(s: EngineSink, channel: Channel, text: []const u8) void {
    switch (channel) {
        .answer => s.emit(undefined, .{ .text_delta = .{ .text = text } }),
        .reasoning => s.emit(undefined, .{ .reasoning_delta = .{ .text = text } }),
        .arg => s.emit(undefined, .{ .tool_arg_delta = .{ .text = text } }),
    }
}

fn expectNoCitation(bytes: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, bytes, "") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "turn0search0") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "turn1search2") == null);
}

// Comparing to the same dispatch fed clean prose checks visible bytes without
// depending on the palette or Markdown's terminal styling choices.
fn rendered(channel: Channel, text: []const u8, split: ?usize) ![]u8 {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    defer cleanup(&a);
    const s = engine_sink.tuiSink(&a);
    if (split) |at| {
        delta(s, channel, text[0..at]);
        delta(s, channel, text[at..]);
    } else {
        delta(s, channel, text);
    }
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = channel == .answer } });
    s.emit(undefined, .stream_finished);
    return std.testing.allocator.dupe(u8, aw.written());
}

test "TuiSink citation answer and completion argument filtering survives every byte split" {
    const saved_color = main_mod.use_color;
    defer main_mod.use_color = saved_color;
    for ([_]bool{ false, true }) |color| {
        main_mod.use_color = color;
        for ([_]Channel{ .answer, .arg }) |channel| {
            const expected = try rendered(channel, clean, null);
            defer std.testing.allocator.free(expected);
            for (0..raw.len + 1) |at| {
                const actual = try rendered(channel, raw, at);
                defer std.testing.allocator.free(actual);
                try std.testing.expectEqualStrings(expected, actual);
            }
            var aw: Io.Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            var a = testAgent(&aw.writer);
            defer cleanup(&a);
            const s = engine_sink.tuiSink(&a);
            for (0..raw.len) |at| delta(s, channel, raw[at .. at + 1]);
            s.emit(undefined, .{ .stream_complete = .{ .streamed_text = channel == .answer } });
            s.emit(undefined, .stream_finished);
            try std.testing.expectEqualStrings(expected, aw.written());
        }
    }
}

test "TuiSink reasoning buffer and fold replay exclude citation bytes at every split" {
    const saved_color = main_mod.use_color;
    main_mod.use_color = true;
    defer main_mod.use_color = saved_color;
    for (0..raw.len + 1) |at| {
        var aw: Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        var a = testAgent(&aw.writer);
        defer cleanup(&a);
        const s = engine_sink.tuiSink(&a);
        delta(s, .reasoning, raw[0..at]);
        // Even a partial UTF-8 marker or a partial hidden payload must not
        // reach the buffer that Ctrl-T later replays.
        try std.testing.expect(std.mem.startsWith(u8, clean, a.thinking_text.items));
        if (a.thinking_open) s.emit(undefined, .thinking_fold_toggle);
        delta(s, .reasoning, raw[at..]);
        try std.testing.expectEqualStrings(clean, a.thinking_text.items);
        if (a.thinking_folded) s.emit(undefined, .thinking_fold_toggle);
        try expectNoCitation(aw.written());
        s.emit(undefined, .stream_finished);
        try expectNoCitation(aw.written());
    }
}

test "TuiSink interleaved reasoning answer and argument citations have independent state" {
    const saved_color = main_mod.use_color;
    main_mod.use_color = true;
    defer main_mod.use_color = saved_color;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    defer cleanup(&a);
    const s = engine_sink.tuiSink(&a);
    delta(s, .reasoning, "reason citeturn0");
    delta(s, .answer, "answer ");
    delta(s, .arg, "argument ");
    delta(s, .answer, "citeturn1");
    delta(s, .arg, "citeturn0");
    delta(s, .reasoning, "search0continued\n");
    delta(s, .answer, "search2visible\n");
    delta(s, .arg, "search0result\n");
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = true } });
    s.emit(undefined, .stream_finished);
    try std.testing.expectEqualStrings("reason continued\n", a.thinking_text.items);
    try expectNoCitation(aw.written());
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "result") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "search0") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "search2") == null);
}

test "TuiSink lifecycle dispatch resets incomplete citations in each channel" {
    const saved_color = main_mod.use_color;
    defer main_mod.use_color = saved_color;
    const saved_anim = @import("anim.zig").g_anim_off;
    @import("anim.zig").g_anim_off = true;
    defer @import("anim.zig").g_anim_off = saved_anim;
    const resets = [_]EngineEvent{
        .stream_begin,
        .{ .stream_complete = .{ .streamed_text = false } },
        .{ .stream_aborted = .interrupted },
        .stream_finished,
        .{ .transport_aborted = .{ .reason = .dropped, .turn_ending = false } },
        .{ .transport_aborted = .{ .reason = .interrupted, .turn_ending = true } },
    };
    for ([_]bool{ false, true }) |color| {
        main_mod.use_color = color;
        for ([_]Channel{ .answer, .reasoning, .arg }) |channel| {
            if (!color and channel == .reasoning) continue;
            for (resets) |reset| {
                for ([_][]const u8{ "\xee", "\xee\x88", "citeturn0search0" }) |pending| {
                    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
                    defer aw.deinit();
                    var a = testAgent(&aw.writer);
                    defer cleanup(&a);
                    const s = engine_sink.tuiSink(&a);
                    delta(s, channel, pending);
                    s.emit(undefined, reset);
                    // Reset alone is the boundary: do not insert stream_begin
                    // here, which could mask a missing end/abort reset.
                    delta(s, channel, "fresh\n");
                    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = false } });
                    s.emit(undefined, .stream_finished);
                    try expectNoCitation(aw.written());
                    try std.testing.expect(std.mem.indexOfScalar(u8, aw.written(), 0xee) == null);
                    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "fresh") != null);
                    if (channel == .reasoning)
                        try std.testing.expectEqualStrings("fresh\n", a.thinking_text.items);
                }
            }
        }
    }
}

test "JsonSink preserves raw citation text and reasoning across every byte split" {
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    for ([_]Channel{ .answer, .reasoning }) |channel| {
        for (0..raw.len + 1) |at| {
            var aw: Io.Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            var a = testAgent(&aw.writer);
            const s = engine_sink.jsonSink(&a);
            delta(s, channel, raw[0..at]);
            delta(s, channel, raw[at..]);
            // Build the expected wire through its serializer, not by parsing
            // invalid UTF-8 fragments split inside a marker code point.
            var expected: Io.Writer.Allocating = .init(std.testing.allocator);
            defer expected.deinit();
            const last = protocol_seq.current();
            const kind: []const u8 = if (channel == .answer) "text" else "reasoning";
            try protocol_seq.writeEventStamped(&expected.writer, last - 1, .{ .type = kind, .text = raw[0..at] });
            try expected.writer.writeByte('\n');
            try protocol_seq.writeEventStamped(&expected.writer, last, .{ .type = kind, .text = raw[at..] });
            try expected.writer.writeByte('\n');
            try std.testing.expectEqualStrings(expected.written(), aw.written());
        }
    }
}
