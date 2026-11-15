const std = @import("std");
const Value = std.json.Value;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const tools_mod = @import("tools.zig");
const ToolCall = tools_mod.ToolCall;
const tool_call_args = @import("tool_call_args.zig");
const agent_tools = @import("agent_tools.zig");

const clock_sleep_max_ms = agent_tools.clock_sleep_max_ms;
const parseClockSleepMs = agent_tools.parseClockSleepMs;
const clockSleepSuccessText = agent_tools.clockSleepSuccessText;
const clockSleepInterruptedText = agent_tools.clockSleepInterruptedText;
const handleMeta = agent_tools.handleMeta;
const rejectToolCall = agent_tools.rejectToolCall;

test "parseClockSleepMs: valid ms passes through, missing/negative/non-integer reject, over-cap clamps (#225)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const valid = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":200}", .{}) catch unreachable;
    const parsed = try parseClockSleepMs(valid);
    try std.testing.expectEqual(@as(i64, 200), parsed.ms);
    try std.testing.expect(!parsed.clamped);

    const zero = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":0}", .{}) catch unreachable;
    try std.testing.expectEqual(@as(i64, 0), (try parseClockSleepMs(zero)).ms);

    const missing = std.json.parseFromSliceLeaky(Value, a, "{}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(missing));

    const negative = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":-1}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(negative));

    const string_ms = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":\"soon\"}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(string_ms));

    const float_ms = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":200.5}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(float_ms));

    const over_cap = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":99999999999}", .{}) catch unreachable;
    const clamped = try parseClockSleepMs(over_cap);
    try std.testing.expectEqual(clock_sleep_max_ms, clamped.ms);
    try std.testing.expect(clamped.clamped);
}

test "clockSleepSuccessText/clockSleepInterruptedText: exact result strings (#225 acceptance)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("slept 200 ms", try clockSleepSuccessText(a, 200, false));
    try std.testing.expectEqualStrings(
        "clock_sleep: requested ms exceeded the 12h cap, clamped to 43200000 ms; slept 43200000 ms",
        try clockSleepSuccessText(a, clock_sleep_max_ms, true),
    );
    try std.testing.expectEqualStrings("sleep interrupted after 150 ms by user input", try clockSleepInterruptedText(a, 150));
}

test "handleMeta clock_sleep: ms=0 completes for real end-to-end, bad ms rejects without touching Io" {
    @import("native_fold.zig").markLoaded("clock_sleep");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = a,
        .arena = a,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    const zero_call: ToolCall = .{ .id = "1", .name = "clock_sleep", .input = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":0}", .{}) catch unreachable };
    const zero_result = try handleMeta(&agent, zero_call);
    try std.testing.expectEqualStrings("slept 0 ms", zero_result.text);
    try std.testing.expect(!zero_result.is_error);

    inline for (.{ "{}", "{\"ms\":-1}", "{\"ms\":\"soon\"}", "{\"ms\":200.5}" }) |bad_json| {
        const bad_call: ToolCall = .{ .id = "1", .name = "clock_sleep", .input = std.json.parseFromSliceLeaky(Value, a, bad_json, .{}) catch unreachable };
        const bad_result = try handleMeta(&agent, bad_call);
        try std.testing.expect(bad_result.is_error);
        try std.testing.expectEqualStrings("clock_sleep: ms must be a non-negative integer", bad_result.text);
    }
}

test "clock_sleep counts against --max-tool-calls and --dedupe-tool-calls like any other call (#225 rails, no bypass)" {
    const saved_max = main_mod.max_tool_calls;
    const saved_dedupe = main_mod.dedupe_tool_calls;
    defer {
        main_mod.max_tool_calls = saved_max;
        main_mod.dedupe_tool_calls = saved_dedupe;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = a,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    const call: ToolCall = .{ .id = "1", .name = "clock_sleep", .input = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":0}", .{}) catch unreachable };

    main_mod.max_tool_calls = 1;
    main_mod.dedupe_tool_calls = false;
    try std.testing.expect((try rejectToolCall(&agent, call)) == null);
    const budget_denied = try rejectToolCall(&agent, call);
    try std.testing.expect(budget_denied != null);
    try std.testing.expect(budget_denied.?.is_error);
    try std.testing.expect(std.mem.indexOf(u8, budget_denied.?.text, "budget") != null);

    agent.tool_calls_this_turn = 0;
    main_mod.max_tool_calls = null;
    main_mod.dedupe_tool_calls = true;
    try std.testing.expect((try rejectToolCall(&agent, call)) == null);
    const dupe_denied = try rejectToolCall(&agent, call);
    try std.testing.expect(dupe_denied != null);
    try std.testing.expect(dupe_denied.?.is_error);
    try std.testing.expect(std.mem.indexOf(u8, dupe_denied.?.text, "duplicate") != null);
}

test "rejectToolCall: truncated arguments are a local error, not an executed call (#752)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = a,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    const call: ToolCall = .{
        .id = "c1",
        .name = "bash",
        .input = .{ .object = .empty },
        .args_ok = false,
    };
    const denied = (try rejectToolCall(&agent, call)).?;
    try std.testing.expect(denied.is_error);
    try std.testing.expectEqualStrings(tool_call_args.invalid_exec_message, denied.text);
    try std.testing.expectEqual(@as(u64, 0), agent.tool_calls_this_turn);
}
