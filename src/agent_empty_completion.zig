//! Degenerate-completion policy for Agent.runTurn.
//!
//! 1. Empty / whitespace-only completions (no tool calls) used to end the
//!    turn silently. Rewind and re-ask, bounded.
//! 2. Lean `-p` text-only first completions (DeepSeek flash SWE): the model
//!    describes a patch and stops. That is not done — bounce once with a
//!    user note (ADR 0052). Do not steal Pi's four-tool catalog (ADR 0024 / 0047).
//!
//! Split from agent.zig (600-line goal); wired only in runTurn.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const no_local_tools = @import("no_local_tools.zig");
const messages = @import("messages.zig");

/// Retries allowed per turn for consecutive degenerate completions.
pub const max_consecutive: u8 = 2;

/// True when `final_text` is a degenerate completion worth one more ask.
/// `retries` = attempts already spent on this turn. Whitespace-only text is
/// still degenerate: no real final answer is pure whitespace.
pub fn shouldRetry(final_text: []const u8, retries: u8) bool {
    if (retries >= max_consecutive) return false;
    return std.mem.trim(u8, final_text, " \t\r\n").len == 0;
}

/// Lean `-p` described a fix and never called a tool. One bounce.
pub const bounce_note = "You described a change but did not call any tool. Inspect and edit the files with read_file / edit_file / write_file; do not claim the tree is already updated.";

pub fn shouldBounce(unattended: bool, lean: bool, text_only: bool, review: bool, sub: bool, tool_calls: u64, model_calls: u64, final_text: []const u8) bool {
    if (!unattended or !lean or text_only or review or sub) return false;
    if (tool_calls != 0 or model_calls != 1) return false;
    return std.mem.trim(u8, final_text, " \t\r\n").len > 0;
}

/// Handle a degenerate completion inside runTurn. Returns true when the
/// caller should `continue` the loop.
pub fn handle(self: *Agent, final_text: []const u8, hist_len: usize) !bool {
    if (shouldRetry(final_text, self.empty_completion_retries)) {
        self.empty_completion_retries += 1;
        self.closeCodexWs();
        self.messages.shrinkRetainingCapacity(@min(hist_len, self.messages.items.len));
        try self.say("[model returned an empty completion — retrying ({d}/{d})]\n", .{ self.empty_completion_retries, max_consecutive });
        return true;
    }
    if (!shouldBounce(main_mod.unattended, no_local_tools.lean, self.text_only, self.review_mode, self.sub, self.tool_calls_this_turn, self.model_calls_this_turn, final_text))
        return false;
    try self.messages.append(try messages.userNote(self.arena, self.provider.kind, bounce_note));
    try self.say("[described a change with no tool call — asking once more]\n", .{});
    if (self.tracer) |tr| tr.note("fake_done", "lean -p text-only; bounced");
    return true;
}

/// Plain finals bypass attempt_completion's gate (#745). Keep the allowance
/// on the runTurn stack: tool progress and compaction must not reset it.
pub const PendingWork = struct {
    nudged: bool = false,

    pub const note = "Open-work reconciliation: your plain final reply would end root execution, but the current checklist is unfinished. " ++
        "If the user still wants this task done, continue actionable independent work now; collect required background results with agent_output/bash_output and wait_ms>0 when needed, rather than polling or promising future work. " ++
        "One blocked branch does not block unrelated work. Respect a user pause/cancel, status-only question, or change of task; do not treat this reminder as permission to resume unwanted work. " ++
        "If stopping is appropriate, explain the actual blocker or status and say root execution is stopping. Never imply the root keeps working after a final reply. " ++
        "Update the checklist only to reflect real progress; do not mark unfinished work completed to bypass this check.";

    fn open(self: *const Agent) usize {
        if (self.sub or self.review_mode or self.text_only or self.completed != null or main_mod.plan_mode) return 0;
        if (self.goal) |g| if (g.status == .paused or g.status == .blocked) return 0;
        const goals = @import("goal_state.zig");
        return goals.openCount(self.todos.items, goals.currentEpoch(self.goal));
    }

    fn canRequest(self: *const Agent) bool {
        if (self.run_budget) |b| if (!b.canAfford(1)) return false;
        if (main_mod.max_tool_calls) |max| if (self.tool_calls_this_turn >= max) return false;
        const cap = @import("turn_chrome.zig").max_turn_model_calls;
        return cap == 0 or self.model_calls_this_turn < cap;
    }

    /// Null continues the same turn. A final stop is explicit even when the
    /// provider ignores the reminder or the remaining budget cannot buy it.
    pub fn finish(state: *PendingWork, self: *Agent, text: []const u8) !?[]const u8 {
        if (!self.sub and Agent.esc_cancel.load(.acquire)) return error.Interrupted;
        const count = open(self);
        if (count == 0) return text;
        if (!state.nudged and canRequest(self)) {
            state.nudged = true;
            const goals = @import("goal_state.zig");
            const body = try std.fmt.allocPrint(self.arena, "{s}\n\n{s}", .{ note, goals.renderTodos(self, goals.currentEpoch(self.goal)) });
            try self.messages.append(try @import("named_work.zig").userNudge(self.arena, self.provider.kind, body));
            if (self.tracer) |tr| tr.note("pending_work", "plain final reconciled; one retry granted");
            return null;
        }
        const footer = try std.fmt.allocPrint(self.arena, "\n\n[Root execution has stopped with {d} open checklist items; background jobs may still run.]", .{count});
        if (self.tracer) |tr| tr.note("pending_work", "plain final stopped with open work; retry or budget exhausted");
        // The answer may already have streamed, so surface the new suffix too.
        if (self.streamed_text) {
            if (main_mod.json_mode) self.emit(.{ .type = "text", .text = footer }) else try self.say("{s}\n", .{footer});
        }
        return try std.fmt.allocPrint(self.arena, "{s}{s}", .{ text, footer });
    }
};

fn pendingFixture(arena: std.mem.Allocator) Agent {
    var self: Agent = undefined;
    self.arena = arena;
    self.sub = false;
    self.review_mode = false;
    self.text_only = false;
    self.completed = null;
    self.goal = null;
    self.todos = .empty;
    self.messages = .init(arena);
    self.provider.kind = .openai;
    self.run_budget = null;
    self.tool_calls_this_turn = 3; // unlike the zero-tool guards, tools ran
    self.model_calls_this_turn = 4;
    self.tracer = null;
    self.streamed_text = false;
    return self;
}

test "#745 plain final retries once after tools, then explicitly stops without completing work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var self = pendingFixture(arena.allocator());
    try self.todos.append(self.arena, .{ .content = "finish", .status = "in_progress" });
    var state: PendingWork = .{};
    try std.testing.expect((try state.finish(&self, "I will keep working")) == null);
    try std.testing.expectEqual(@as(usize, 1), self.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, messages.latestUserText(self.messages.items), "finish") != null);
    self.tool_calls_this_turn += 1; // tool progress must not refill the allowance
    const final = (try state.finish(&self, "I will keep working")).?;
    try std.testing.expect(std.mem.indexOf(u8, final, "Root execution has stopped with 1 open checklist items") != null);
    try std.testing.expectEqualStrings("in_progress", self.todos.items[0].status);
    try std.testing.expect(self.completed == null);
    self.todos.items[0].status = "completed";
    try std.testing.expectEqualStrings("done", (try state.finish(&self, "done")).?);
}

test "#745 only live current work gates root finals, never explicit completion or paused goals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var self = pendingFixture(arena.allocator());
    self.goal = .{ .objective = "current", .epoch = 2 };
    try self.todos.append(self.arena, .{ .content = "parked", .status = "pending", .epoch = 1 });
    try self.todos.append(self.arena, .{ .content = "retired", .status = "pending", .epoch = 2, .retired = true });
    try std.testing.expectEqual(@as(usize, 0), PendingWork.open(&self));
    try self.todos.append(self.arena, .{ .content = "current", .status = "pending", .epoch = 2 });
    try std.testing.expectEqual(@as(usize, 1), PendingWork.open(&self));
    for ([_]@import("agent.zig").GoalStatus{ .paused, .blocked }) |status| {
        self.goal.?.status = status;
        try std.testing.expectEqual(@as(usize, 0), PendingWork.open(&self));
    }
    self.goal.?.status = .active;
    for ([_]*bool{ &self.sub, &self.review_mode, &self.text_only }) |flag| {
        flag.* = true;
        try std.testing.expectEqual(@as(usize, 0), PendingWork.open(&self));
        flag.* = false;
    }
    self.completed = "explicitly accepted";
    try std.testing.expectEqual(@as(usize, 0), PendingWork.open(&self));
}

test "#745 cancellation and exhausted budgets do not buy a reconciliation request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var self = pendingFixture(arena.allocator());
    try self.todos.append(self.arena, .{ .content = "finish", .status = "pending" });
    var budget: @import("run_budget.zig").RunBudget = .{ .max_model_calls = 1 };
    budget.model_calls.store(1, .release);
    self.run_budget = &budget;
    var state: PendingWork = .{};
    try std.testing.expect((try state.finish(&self, "budget spent")) != null);
    try std.testing.expectEqual(@as(usize, 0), self.messages.items.len);
    Agent.esc_cancel.store(true, .release);
    defer Agent.esc_cancel.store(false, .release);
    try std.testing.expectError(error.Interrupted, state.finish(&self, "cancelled"));
}

test "#745 reconciliation supports every wire without coercing status requests into action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]@import("provider.zig").Provider.Kind{ .openai, .anthropic, .responses }) |kind| {
        var self = pendingFixture(arena.allocator());
        self.provider.kind = kind;
        try self.todos.append(self.arena, .{ .content = "finish", .status = "pending" });
        var state: PendingWork = .{};
        try std.testing.expect((try state.finish(&self, "status")) == null);
        const body = messages.latestUserText(self.messages.items);
        try std.testing.expect(std.mem.indexOf(u8, body, "status-only question") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "wait_ms>0") != null);
        if (kind == .responses) try std.testing.expectEqualStrings("message", self.messages.items[0].object.get("type").?.string);
    }
}

test "retry empty completions up to the cap" {
    try std.testing.expect(shouldRetry("", 0));
    try std.testing.expect(shouldRetry("", 1));
    try std.testing.expect(!shouldRetry("", max_consecutive));
    try std.testing.expect(!shouldRetry("", max_consecutive + 1));
}

test "whitespace-only completions are degenerate, real text never is" {
    try std.testing.expect(shouldRetry(" \r\n\t", 0));
    try std.testing.expect(!shouldRetry("done", 0));
    try std.testing.expect(!shouldRetry("<|eos|>", 0));
}

test "lean -p text-only first completion bounces once" {
    try std.testing.expect(shouldBounce(true, true, false, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, false, 0, 2, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, false, 1, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(false, true, false, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, false, false, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, true, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, true, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, true, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, false, 0, 1, "   "));
}

test "bounce note names the file tools" {
    try std.testing.expect(std.mem.indexOf(u8, bounce_note, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, bounce_note, "write_file") != null);
}
