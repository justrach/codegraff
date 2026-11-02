//! Lean `-p` bounce cases, split from agent_empty_completion.zig (600-line goal).

const std = @import("std");
const main_mod = @import("main.zig");
const no_local_tools = @import("no_local_tools.zig");
const messages = @import("messages.zig");
const ec = @import("agent_empty_completion.zig");

const LeanRun = struct {
    unattended: bool,
    lean: bool,
    enabled: bool,

    fn begin() LeanRun {
        const saved: LeanRun = .{ .unattended = main_mod.unattended, .lean = no_local_tools.lean, .enabled = no_local_tools.enabled };
        main_mod.unattended = true;
        no_local_tools.lean = true;
        no_local_tools.enabled = false;
        return saved;
    }

    fn end(saved: LeanRun) void {
        main_mod.unattended = saved.unattended;
        no_local_tools.lean = saved.lean;
        no_local_tools.enabled = saved.enabled;
    }
};

test "#1518 lean bounce skips questions and a spent model-call budget" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const saved = LeanRun.begin();
    defer saved.end();
    var budget: @import("run_budget.zig").RunBudget = .{ .max_model_calls = 1 };
    budget.model_calls.store(1, .release);
    const cases = .{
        .{ "What does parse() return for an empty string?", false, false },
        .{ "Fix the off-by-one in fib.py", true, false },
        .{ "Fix the off-by-one in fib.py", false, true },
    };
    inline for (cases) |case| {
        var self = ec.pendingFixture(state.allocator());
        self.empty_completion_retries = 0;
        self.call_kind = .title; // suppress fixture notices without initializing a writer
        self.tool_calls_this_turn = 0;
        self.model_calls_this_turn = 1;
        if (case[1]) self.run_budget = &budget;
        try self.messages.append(try messages.textMessage(self.arena, "user", case[0]));
        const before = self.messages.items.len;
        try std.testing.expectEqual(case[2], try ec.handle(&self, "It returns an empty list.", before));
    }
}

test "#1786 an answer built on the provider's own searches is not bounced as a described change" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const saved = LeanRun.begin();
    defer saved.end();
    // "build" makes this read as an action request; the searches did the work.
    const prompt = "Search posts from the people who build the app and report what they said, with links.";
    const answer = "Three posts: ...";
    for ([_]?[]const u8{ "{\"type\":\"x_search_call\",\"status\":\"completed\"}", null }) |search| {
        var self = ec.pendingFixture(state.allocator());
        self.empty_completion_retries = 0;
        self.call_kind = .title;
        self.tool_calls_this_turn = 0;
        self.model_calls_this_turn = 1;
        try self.messages.append(try messages.textMessage(self.arena, "user", prompt));
        const before = self.messages.items.len;
        if (search) |raw| try self.messages.append(try std.json.parseFromSliceLeaky(std.json.Value, self.arena, raw, .{}));
        try self.messages.append(try messages.textMessage(self.arena, "assistant", answer));
        const after = self.messages.items.len;
        // With a hosted search the answer stands; with none, the bounce still fires.
        try std.testing.expectEqual(search == null, try ec.handle(&self, answer, before));
        try std.testing.expectEqual(after + @intFromBool(search == null), self.messages.items.len);
    }
}
