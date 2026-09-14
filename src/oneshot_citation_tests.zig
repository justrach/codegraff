//! #874: real hosted fallback and unattended printDelta dispatch boundaries.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main = @import("main.zig");
const sinks = @import("engine_sink.zig");
const Event = @import("engine_events.zig").EngineEvent;
const Kind = @import("provider.zig").Provider.Kind;
const a = std.testing.allocator;

// Restore every process-global touched here, including the stdout writer.
const Globals = struct {
    hosted: bool,
    unattended: bool,
    json: bool,
    out: ?*std.Io.Writer,

    fn capture() Globals {
        return .{ .hosted = sinks.hosted_frontend, .unattended = main.unattended, .json = main.json_mode, .out = main.g_out };
    }

    fn restore(self: Globals) void {
        sinks.hosted_frontend = self.hosted;
        main.unattended = self.unattended;
        main.json_mode = self.json;
        main.g_out = self.out;
    }
};

fn agent(arena: std.mem.Allocator, client: *std.http.Client) Agent {
    return .{
        .gpa = a,
        .arena = arena,
        .io = std.testing.io,
        .client = client,
        .provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 0 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
}

const boundaries = [_]Event{
    .stream_begin,
    .{ .stream_complete = .{ .streamed_text = true } },
    .{ .stream_aborted = .interrupted },
    .{ .stream_aborted = .stalled },
    .{ .stream_aborted = .dropped },
    .stream_finished,
    .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = true } },
};

test "hosted fallback citation dispatch isolates text and arguments and preserves source bytes" {
    const saved = Globals.capture();
    defer saved.restore();
    sinks.hosted_frontend = true;
    main.json_mode = false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = std.testing.io };
    defer client.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var root = agent(arena.allocator(), &client);
    root.out = &output.writer;
    const sink = sinks.forAgent(&root); // No injected sink: hosted fallback itself.
    const raw = try a.dupe(u8, "A\u{e200}cite\u{e202}hidden\u{e201}B");
    defer a.free(raw);
    const expected_raw = "A\u{e200}cite\u{e202}hidden\u{e201}B";
    // Exercise every UTF-8 byte boundary and interleave a second channel while
    // the answer channel holds a partial opener or hidden payload.
    for (0..raw.len + 1) |split| {
        sink.emit(root.io, .stream_begin);
        const start = output.written().len;
        const first: Event = .{ .text_delta = .{ .text = raw[0..split] } };
        sink.emit(root.io, first);
        sink.emit(root.io, .{ .tool_arg_delta = .{ .text = "X\u{e200}cite\u{e202}arg-hidden" } });
        sink.emit(root.io, .{ .text_delta = .{ .text = raw[split..] } });
        sink.emit(root.io, .{ .tool_arg_delta = .{ .text = "\u{e201}Y" } });
        const expected = if (split == 0) "XABY" else if (split == raw.len) "ABXY" else "AXBY";
        try std.testing.expectEqualStrings(expected, output.written()[start..]);
        try std.testing.expectEqualStrings(expected_raw, raw);
        try std.testing.expectEqualStrings(raw[0..split], first.text_delta.text);
    }
    // Arbitrary tool stdout is not model prose and must remain byte-exact.
    const start = output.written().len;
    sink.emit(root.io, .{ .tool_output_delta = .{ .name = "bash", .text = raw } });
    try std.testing.expectEqualStrings(raw, output.written()[start..]);
    // The argument producer captures the original bytes before sink dispatch.
    sink.emit(root.io, .stream_begin);
    const arg_start = output.written().len;
    @import("agent_argstream.zig").emitArgText(&root, .attempt_completion, raw);
    try std.testing.expectEqualStrings("AB", output.written()[arg_start..]);
    try std.testing.expectEqualStrings(raw, root.partial_text.items);
}

test "hosted fallback lifecycle drops unfinished markers and resets both prose channels" {
    const saved = Globals.capture();
    defer saved.restore();
    sinks.hosted_frontend = true;
    main.json_mode = false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = std.testing.io };
    defer client.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var root = agent(arena.allocator(), &client);
    root.out = &output.writer;
    const sink = sinks.forAgent(&root);
    for (boundaries) |boundary| {
        for ([_][]const u8{ "\xee", "\xee\x88", "\u{e200}cite\u{e202}unfinished" }) |held| {
            sink.emit(root.io, .stream_begin);
            const start = output.written().len;
            sink.emit(root.io, .{ .text_delta = .{ .text = held } });
            sink.emit(root.io, .{ .tool_arg_delta = .{ .text = held } });
            sink.emit(root.io, boundary);
            sink.emit(root.io, .{ .text_delta = .{ .text = "answer" } });
            sink.emit(root.io, .{ .tool_arg_delta = .{ .text = "args" } });
            try std.testing.expectEqualStrings("answerargs", output.written()[start..]);
        }
    }
}

fn delta(root: *Agent, text: []const u8) !void {
    // Stringify the chunk: split UTF-8 bytes must travel through JSON escapes,
    // so this helper is used only with complete UTF-8 strings.
    const encoded = try std.json.Stringify.valueAlloc(a, text, .{});
    defer a.free(encoded);
    const line = switch (root.provider.kind) {
        .responses => try std.fmt.allocPrint(a, "data: {{\"type\":\"response.output_text.delta\",\"delta\":{s}}}", .{encoded}),
        .openai => try std.fmt.allocPrint(a, "data: {{\"choices\":[{{\"delta\":{{\"content\":{s}}}}}]}}", .{encoded}),
        .anthropic => try std.fmt.allocPrint(a, "data: {{\"type\":\"content_block_delta\",\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}", .{encoded}),
        .interactions => try std.fmt.allocPrint(a, "data: {{\"delta\":{{\"type\":\"text\",\"text\":{s}}}}}", .{encoded}),
    };
    defer a.free(line);
    const original = try a.dupe(u8, line);
    defer a.free(original);
    root.printDelta(line);
    try std.testing.expectEqualStrings(original, line);
}

test "unattended no_ui printDelta filters live prose across provider envelopes without touching raw capture" {
    const saved = Globals.capture();
    defer saved.restore();
    main.unattended = true;
    main.json_mode = false;
    // Both settings must work: tuiEmit resets before its hosted early return,
    // even though Agent.out is null and printDelta writes main.g_out directly.
    for ([_]bool{ false, true }) |hosted| {
        sinks.hosted_frontend = hosted;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var client: std.http.Client = .{ .allocator = a, .io = std.testing.io };
        defer client.deinit();
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        main.g_out = &output.writer;
        var root = agent(arena.allocator(), &client);
        const raw_capture = "captured\u{e200}cite\u{e202}raw-source\u{e201}";
        try root.partial_text.appendSlice(arena.allocator(), raw_capture);
        for ([_]Kind{ .responses, .openai, .anthropic, .interactions }) |kind| {
            root.provider.kind = kind;
            sinks.forAgent(&root).emit(root.io, .stream_begin);
            const start = output.written().len;
            for ([_][]const u8{ "before", "\u{e200}", "cite", "\u{e202}source", "\u{e201}", "after" }) |chunk| try delta(&root, chunk);
            try std.testing.expectEqualStrings("beforeafter", output.written()[start..]);
            try std.testing.expect(root.streamed_text);
            // printDelta's direct-output branch does not populate partial_text;
            // any existing capture must stay raw, not be rewritten by painting.
            try std.testing.expectEqualStrings(raw_capture, root.partial_text.items);
        }
        for (boundaries) |boundary| {
            const start = output.written().len;
            try delta(&root, "\u{e200}cite\u{e202}unfinished");
            sinks.forAgent(&root).emit(root.io, boundary);
            try delta(&root, "fresh");
            try std.testing.expectEqualStrings("fresh", output.written()[start..]);
        }
        // Unattended JSON must not accidentally send terminal text to stdout.
        main.json_mode = true;
        const start = output.written().len;
        try delta(&root, "not terminal output");
        try std.testing.expectEqual(start, output.written().len);
        main.json_mode = false;
        main.g_out = saved.out;
    }
}
