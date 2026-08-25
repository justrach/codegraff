//! Enforceable predict -> verify -> repair controller tests.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const agent_tools = @import("agent_tools.zig");
const eval_control = @import("agent_eval_control.zig");
const repl_glue = @import("repl_glue.zig");
const ToolCall = @import("tools.zig").ToolCall;

fn call(arena: std.mem.Allocator, name: []const u8, input: []const u8) !ToolCall {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{});
    return .{ .id = "control-test", .name = name, .input = value };
}

test "attempt_completion is blocked until the latest verifier result is green" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = true,
        .label = "test",
        .out = null,
        .eval_cmd = "verify",
    };
    const completion = try call(arena, "attempt_completion", "{\"result\":\"done\"}");

    const unverified = try agent.handleMeta(completion);
    try std.testing.expect(unverified.is_error);
    try std.testing.expect(agent.completed == null);

    agent.eval_verified = true;
    agent.eval_repair_pending = true;
    const red = try agent.handleMeta(completion);
    try std.testing.expect(red.is_error);
    try std.testing.expect(agent.completed == null);

    agent.eval_repair_pending = false;
    const green = try agent.handleMeta(completion);
    try std.testing.expect(!green.is_error);
    try std.testing.expectEqualStrings("done", agent.completed.?);
}

test "workspace-changing tools stale verification while read-only tools do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "edit_file", "{}")));
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "bash", "{}")));
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "subagent", "{}")));
    try std.testing.expect(!agent_tools.toolInvalidatesEval(try call(arena, "read_file", "{}")));
    try std.testing.expect(!agent_tools.toolInvalidatesEval(try call(arena, "codedb", "{}")));
    try std.testing.expect(!agent_tools.toolInvalidatesEval(try call(arena, "mcp__codedbpro__read", "{}")));
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "mcp__codedbpro__edit", "{}")));
}

test "verify bash does not block same-batch attempt_completion; edit/rlm still do" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bash_done = [_]ToolCall{
        try call(arena, "bash", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(!eval_control.batchBlocksCompletion(&bash_done));
    try std.testing.expect(eval_control.shouldDeferCompletion(&bash_done));
    try std.testing.expectEqual(@as(?usize, 1), eval_control.completionIndex(&bash_done));

    const read_done = [_]ToolCall{
        try call(arena, "codedb", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(eval_control.shouldDeferCompletion(&read_done));

    const edit_done = [_]ToolCall{
        try call(arena, "edit_file", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(eval_control.batchBlocksCompletion(&edit_done));
    try std.testing.expect(!eval_control.shouldDeferCompletion(&edit_done));

    const rlm_done = [_]ToolCall{
        try call(arena, "rlm", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(eval_control.batchBlocksCompletion(&rlm_done));
    try std.testing.expect(!eval_control.shouldDeferCompletion(&rlm_done));

    const only_done = [_]ToolCall{try call(arena, "attempt_completion", "{\"result\":\"done\"}")};
    try std.testing.expect(!eval_control.shouldDeferCompletion(&only_done));
}

test "eval is a solo verifier boundary in a tool batch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = [_]ToolCall{
        try call(arena, "edit_file", "{}"),
        try call(arena, "eval", "{}"),
        try call(arena, "read_file", "{}"),
    };
    try std.testing.expectEqual(@as(?usize, 1), eval_control.evalCallIndex(&calls));
    try std.testing.expectEqualStrings(
        "eval is a verifier boundary and must run alone; this tool was not executed",
        eval_control.verifier_boundary,
    );
    try std.testing.expect(eval_control.shouldStopAfterBatch(&calls, true));
    try std.testing.expect(!eval_control.shouldStopAfterBatch(&calls, false));

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = true,
        .label = "test",
        .out = &output.writer,
    };
    const results = try agent.runTools(&calls);
    try std.testing.expect(results[0].is_error);
    try std.testing.expectEqualStrings(eval_control.verifier_boundary, results[0].text);
    try std.testing.expect(results[1].is_error);
    try std.testing.expect(std.mem.indexOf(u8, results[1].text, "no eval command configured") != null);
    try std.testing.expect(results[2].is_error);
    try std.testing.expectEqualStrings(eval_control.verifier_boundary, results[2].text);
}

test "eval steering carries controller state and local belief memory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const note = try repl_glue.evalSteeringNote(
        arena_state.allocator(),
        "verify",
        90,
        false,
        true,
        true,
        "## CONFIRMED\n- compiler failed",
    );
    try std.testing.expect(std.mem.indexOf(u8, note, "Verifier state: RED") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "prior plan is dropped") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "compiler failed") != null);
}
