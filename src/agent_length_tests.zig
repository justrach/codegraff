//! Offline regression coverage for shared REPL/ACP output-limit recovery.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const Kind = @import("provider.zig").Provider.Kind;
const length = @import("agent_length.zig");
const messages = @import("messages.zig");

fn parse(allocator: std.mem.Allocator, raw: []const u8) !std.json.ObjectMap {
    return (try std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{ .allocate = .alloc_always })).object;
}

fn fixture(allocator: std.mem.Allocator, writer: *std.Io.Writer, kind: Kind) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = allocator,
        .io = undefined,
        .client = undefined,
        .provider = .{ .id = "test", .kind = kind, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 100_000 },
        .messages = .init(allocator),
        .sub = false,
        .label = "test",
        .out = writer,
    };
}

const chat_partial = "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"role\":\"assistant\",\"content\":\"partial document\"}}]}";
const chat_done = "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"saved the document\"}}]}";

test "length continuation preserves chat partial history and marks its internal file-writing note" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var agent = fixture(arena.allocator(), &writer, .openai);
    var state: length.State = .{};
    try agent.messages.append(try messages.textMessage(agent.arena, "user", "Write the document"));
    try std.testing.expect((try state.step(&agent, try parse(agent.arena, chat_partial))) == null);
    try std.testing.expectEqual(@as(u8, 1), state.continuations);
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqualStrings("partial document", agent.messages.items[1].object.get("content").?.string);
    try std.testing.expect(@import("session_wake.zig").isNotice(agent.messages.items[2]));
    const serialized = try std.json.Stringify.valueAlloc(agent.arena, agent.messages.items[2], .{});
    try std.testing.expect(std.mem.indexOf(u8, serialized, "incrementally to files") != null);
    try std.testing.expectEqualStrings("Write the document", messages.latestUserText(agent.messages.items));
    try std.testing.expectEqualStrings("saved the document", (try state.step(&agent, try parse(agent.arena, chat_done))).?);
    try std.testing.expectEqual(@as(u8, 1), state.continuations);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "[stopped: length]") == null);
}

test "length continuation handles Anthropic max_tokens and Responses max_output_tokens, not refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const cases = [_]struct { kind: Kind, raw: []const u8 }{
        .{ .kind = .anthropic, .raw = "{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"text\",\"text\":\"partial document\"}]}" },
        .{ .kind = .responses, .raw = "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial document\"}]}]}" },
    };
    for (cases) |case| {
        var agent = fixture(arena.allocator(), &writer, case.kind);
        var state: length.State = .{};
        try std.testing.expect((try state.step(&agent, try parse(agent.arena, case.raw))) == null);
        try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
        try std.testing.expectEqual(@as(u8, 1), state.continuations);
    }
    try std.testing.expect(!length.limited(.responses, try parse(arena.allocator(), "{\"incomplete\":true,\"incomplete_details\":{\"reason\":\"content_filter\"}}")));
    try std.testing.expect(!length.limited(.responses, try parse(arena.allocator(), "{\"incomplete\":true}")));
    try std.testing.expect(!length.limited(.anthropic, try parse(arena.allocator(), "{\"stop_reason\":\"refusal\"}")));
    try std.testing.expect(!length.limited(.openai, try parse(arena.allocator(), "{\"choices\":[{\"finish_reason\":\"content_filter\"}]}")));
}

test "length continuation allowance stays bounded across tool progress and resets only on a new turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var agent = fixture(arena.allocator(), &writer, .openai);
    const root = try parse(agent.arena, chat_partial);
    var state: length.State = .{};
    for (0..length.max_continuations) |_| {
        // null is the step result after a tool batch. Progress cannot refill
        // the allowance and these length stops must be counted too.
        try std.testing.expect((try state.afterStep(&agent, root, null)) == null);
        agent.tool_calls_this_turn += 1;
        _ = try state.afterStep(&agent, try parse(agent.arena, chat_done), null);
    }
    const count = agent.messages.items.len;
    try std.testing.expectError(error.OutputLengthExceeded, state.afterStep(&agent, root, "partial"));
    try std.testing.expectEqual(count, agent.messages.items.len);
    try std.testing.expectEqualStrings(length.exhausted_message, agent.last_api_error.?);
    var next_turn: length.State = .{};
    try std.testing.expect((try next_turn.afterStep(&agent, root, "new partial")) == null);
    try std.testing.expectEqual(@as(u8, 1), next_turn.continuations);
}

test "length continuation excludes empty chat replies from the next request without rewinding prior work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    for ([_][]const u8{ "deepseek", "codegraff" }) |provider| {
        for ([_][]const u8{ "null", "\"\"", "\"  \\n\"" }) |content| {
            var agent = fixture(arena.allocator(), &writer, .openai);
            agent.io = std.testing.io;
            agent.provider.id = provider;
            agent.provider.model = "deepseek-flash";
            var state: length.State = .{};
            try agent.messages.append(try messages.textMessage(agent.arena, "user", "Write the document"));
            const prior = try parse(agent.arena, "{\"role\":\"assistant\",\"content\":\"partial document\",\"reasoning_content\":\"prior useful reasoning\"}");
            try agent.messages.append(.{ .object = prior });
            const raw = try std.fmt.allocPrint(agent.arena, "{{\"choices\":[{{\"finish_reason\":\"length\",\"message\":{{\"role\":\"assistant\",\"content\":{s},\"reasoning_content\":\"unfinished thought\",\"tool_calls\":[]}}}}]}}", .{content});
            const root = try parse(agent.arena, raw);
            // Even the last allowed reply must not poison saved/resumed history.
            for (0..length.max_continuations) |_| try std.testing.expect((try state.step(&agent, root)) == null);
            try std.testing.expectError(error.OutputLengthExceeded, state.step(&agent, root));
            try std.testing.expectEqual(@as(usize, 2 + length.max_continuations), agent.messages.items.len);
            try std.testing.expectEqual(length.max_continuations, state.continuations);
            try std.testing.expectEqual(@as(u8, 0), agent.empty_completion_retries);
            const body = try agent.buildBody(null, false, false, false);
            defer std.testing.allocator.free(body);
            try std.testing.expect(std.mem.indexOf(u8, body, "unfinished thought") == null);
            try std.testing.expect(std.mem.indexOf(u8, body, "prior useful reasoning") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "Think briefly") != null);
            const request = try parse(agent.arena, body);
            var assistants: usize = 0;
            for (request.get("messages").?.array.items) |message| {
                if (!std.mem.eql(u8, message.object.get("role").?.string, "assistant")) continue;
                assistants += 1;
                try std.testing.expectEqualStrings("partial document", message.object.get("content").?.string);
            }
            try std.testing.expectEqual(@as(usize, 1), assistants);
            try std.testing.expectEqualStrings("saved the document", (try state.step(&agent, try parse(agent.arena, chat_done))).?);
        }
    }
}

test "length continuation respects run budgets and both engine cancellation flags without granting another call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var agent = fixture(arena.allocator(), &writer, .openai);
    const root = try parse(agent.arena, chat_partial);
    var state: length.State = .{};
    const acp = @import("acp_engine.zig");
    const previous_esc = Agent.esc_cancel.swap(true, .acq_rel);
    defer Agent.esc_cancel.store(previous_esc, .release);
    try std.testing.expectError(error.Interrupted, state.afterStep(&agent, root, "partial"));
    Agent.esc_cancel.store(false, .release);
    const previous_acp = acp.cancel_flag.swap(true, .acq_rel);
    defer acp.cancel_flag.store(previous_acp, .release);
    try std.testing.expectError(error.Interrupted, state.afterStep(&agent, root, "partial"));
    acp.cancel_flag.store(false, .release);
    var budget: @import("run_budget.zig").RunBudget = .{ .max_model_calls = 1 };
    budget.model_calls.store(1, .release);
    agent.run_budget = &budget;
    try std.testing.expectError(error.RunBudgetExhausted, state.afterStep(&agent, root, "partial"));
    budget.model_calls.store(0, .release);
    agent.depth = 1;
    try std.testing.expectError(error.RunBudgetExhausted, state.afterStep(&agent, root, "partial"));
    agent.depth = 0;
    budget.tool_exhausted.store(true, .release);
    try std.testing.expectError(error.ToolBudgetExhausted, state.afterStep(&agent, root, "partial"));
    try std.testing.expectEqual(@as(usize, 0), agent.messages.items.len);
    try std.testing.expectEqual(@as(u8, 0), state.continuations);
}

test "length continuation cut safeguards reject empty or truncated raw tool args but retain completed object calls" {
    const gpa = std.testing.allocator;
    try std.testing.expect(length.callCut(gpa, true, .empty, ""));
    try std.testing.expect(length.callCut(gpa, true, .empty, "{\"path\":\"unfinished"));
    try std.testing.expect(length.callCut(gpa, true, .empty, "[]"));
    try std.testing.expect(!length.callCut(gpa, true, .empty, "{}"));
    try std.testing.expect(!length.callCut(gpa, true, .empty, "{\"path\":\"complete\"}"));
    try std.testing.expect(!length.callCut(gpa, false, .empty, ""));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const incomplete = try parse(arena.allocator(), "{\"status\":\"incomplete\"}");
    try std.testing.expect(length.callCut(gpa, false, incomplete, "{}"));
}

test "length continuation never dispatches truncated tool calls and leaves replayable error pairs on every wire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const cases = [_]struct { kind: Kind, raw: []const u8 }{
        .{ .kind = .openai, .raw = "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"keep tool reasoning\",\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]}}]}" },
        .{ .kind = .responses, .raw = "{\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"read_file\",\"arguments\":\"\"}]}" },
        .{ .kind = .anthropic, .raw = "{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"read_file\"}]}" },
    };
    for (cases) |case| {
        var agent = fixture(arena.allocator(), &writer, case.kind);
        agent.sub = true;
        var state: length.State = .{};
        try std.testing.expect((try state.step(&agent, try parse(agent.arena, case.raw))) == null);
        try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
        const result = try std.json.Stringify.valueAlloc(agent.arena, agent.messages.items[1], .{});
        try std.testing.expect(std.mem.indexOf(u8, result, "truncated: the response ended") != null);
        const history = try std.json.Stringify.valueAlloc(agent.arena, agent.messages.items[0], .{});
        try std.testing.expect(std.mem.indexOf(u8, history, "graff_invalid_input") == null);
        if (case.kind == .openai) {
            const body = try agent.buildBody(null, false, false, false);
            defer std.testing.allocator.free(body);
            try std.testing.expect(std.mem.indexOf(u8, body, "keep tool reasoning") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c\"") != null);
        }
        try std.testing.expectEqual(@as(u8, 1), state.continuations);
    }
}

test "length continuation Responses terminal metadata survives scratch teardown and resets on a completed terminal" {
    var result = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    var terminal: length.ResponsesTerminal = .{};
    const response = try parse(scratch.allocator(), "{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}");
    try terminal.record(result.allocator(), response);
    scratch.deinit();
    var assembled: std.json.ObjectMap = .empty;
    try terminal.apply(result.allocator(), &assembled);
    try std.testing.expect(length.limited(.responses, assembled));
    try terminal.record(result.allocator(), .empty);
    var completed: std.json.ObjectMap = .empty;
    try terminal.apply(result.allocator(), &completed);
    try std.testing.expect(!length.limited(.responses, completed));
}
