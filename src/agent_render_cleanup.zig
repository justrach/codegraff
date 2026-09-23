//! Release render storage when a root or temporary frontend agent is retired.
const std = @import("std");
const Agent = @import("agent.zig").Agent;

pub fn deinit(agent: *Agent) void {
    @import("agent_render.zig").deinitMarkdown(agent);
    agent.thinking_text.deinit(agent.gpa);
}

test "retired agent releases reasoning and markdown render storage" {
    const alloc = std.testing.allocator;
    const main = @import("main.zig");
    const sink_mod = @import("engine_sink.zig");
    const tick = @import("tick_gate.zig");
    const saved_color = main.use_color;
    const saved_open = main.g_thinking_open;
    const saved_hosted = sink_mod.hosted_frontend;
    const saved_gate = tick.g_gate;
    defer {
        main.use_color = saved_color;
        main.g_thinking_open = saved_open;
        sink_mod.hosted_frontend = saved_hosted;
        tick.g_gate = saved_gate;
    }
    main.use_color = true;
    sink_mod.hosted_frontend = false;
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    var agent: Agent = .{
        .gpa = alloc,
        .arena = alloc,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &output.writer,
        .show_thinking = true,
    };
    defer deinit(&agent);
    const sink = sink_mod.tuiSink(&agent);
    sink.emit(undefined, .{ .reasoning_delta = .{ .text = "Reasoning retained for fold and unfold." } });
    try std.testing.expect(agent.thinking_text.capacity > 0);
    sink.emit(undefined, .{ .text_delta = .{ .text = "A **rendered** answer.\n" } });
    sink.emit(undefined, .stream_finished);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "answer") != null);
    // std.testing.allocator proves the owner's teardown frees retained storage;
    // stream_finished alone deliberately retains it for fold/unfold support.
    try std.testing.expect(agent.thinking_text.capacity > 0);
}
