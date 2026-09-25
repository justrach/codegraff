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

/// Retry note when the empty reply was all reasoning (#1293): the identical
/// request tends to reason to the output limit again, so ask for brevity.
pub const reasoning_budget_note = "Your previous reply spent its whole output budget reasoning and produced no answer or tool call. Think briefly, then call a tool or answer directly.";

/// True when the rewound reply carried reasoning but no answer: chat
/// `reasoning_content`/`reasoning`, a Responses `reasoning` item, or an
/// Anthropic `thinking` block.
pub fn reasonedWithoutAnswer(rewound: []const std.json.Value) bool {
    for (rewound) |m| {
        if (m != .object) continue;
        const o = m.object;
        for ([_][]const u8{ "reasoning_content", "reasoning" }) |key| if (o.get(key)) |r| {
            if (r == .string and std.mem.trim(u8, r.string, " \t\r\n").len > 0) return true;
        };
        if (o.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "reasoning")) return true;
        if (o.get("content")) |c| if (c == .array) for (c.array.items) |block| {
            if (block == .object) if (block.object.get("type")) |bt| if (bt == .string and std.mem.eql(u8, bt.string, "thinking")) return true;
        };
    }
    return false;
}

test "reasonedWithoutAnswer: chat, Responses and Anthropic reasoning shapes; plain empty replies are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "[{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":\"let me think...\"}]",
        "[{\"type\":\"reasoning\",\"summary\":[]}]",
        "[{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hm\"}]}]",
    }) |raw| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
        try std.testing.expect(reasonedWithoutAnswer(v.array.items));
    }
    const plain = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"role\":\"assistant\",\"content\":\"  \",\"reasoning_content\":\" \"}]", .{});
    try std.testing.expect(!reasonedWithoutAnswer(plain.array.items));
}

/// Lean `-p` described a fix and never called a tool. One bounce.
pub const bounce_note = "If the user requested a change, a description alone is not completion: inspect and edit the files with read_file / edit_file / write_file; do not claim the tree is already updated. If the request is informational, answer it from sufficient evidence without making unrequested changes.";

pub fn shouldBounce(unattended: bool, lean: bool, text_only: bool, review: bool, sub: bool, tool_calls: u64, model_calls: u64, final_text: []const u8) bool {
    if (!unattended or !lean or text_only or review or sub) return false;
    if (tool_calls != 0 or model_calls != 1) return false;
    return std.mem.trim(u8, final_text, " \t\r\n").len > 0;
}

/// Kept on the runTurn stack, never recovered from persisted message history.
/// A later turn or a quoted retry note must not revive an earlier answer.
pub const BounceAnswer = struct {
    first: ?[]const u8 = null,

    pub fn remember(state: *BounceAnswer, text: []const u8) void {
        if (state.first == null and std.mem.trim(u8, text, " \t\r\n").len > 0) state.first = text;
    }

    pub fn retry(state: *BounceAnswer, self: *Agent, text: []const u8, hist_len: usize) !bool {
        if (!try handle(self, text, hist_len)) return false;
        state.remember(text);
        return true;
    }

    pub fn finish(state: BounceAnswer, self: *const Agent, follow_up: []const u8) []const u8 {
        return if (self.tool_calls_this_turn == 0) state.first orelse follow_up else follow_up;
    }
};

test "#1013 an old bounce cannot replace a later turn's answer" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var self = pendingFixture(state.allocator());
    self.tool_calls_this_turn = 0;
    try self.messages.append(try messages.textMessage(self.arena, "user", "Earlier request"));
    try self.messages.append(try messages.textMessage(self.arena, "assistant", "Earlier answer"));
    try self.messages.append(try messages.userNote(self.arena, self.provider.kind, bounce_note));
    try self.messages.append(try messages.textMessage(self.arena, "assistant", "Earlier retry"));
    try self.messages.append(try messages.textMessage(self.arena, "user", "What is two plus two?"));
    const current: BounceAnswer = .{};
    try std.testing.expectEqualStrings("4", current.finish(&self, "4"));
}

test "#1013 bounce follow-up without tools keeps the first answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var self = pendingFixture(arena.allocator());
    self.tool_calls_this_turn = 0;
    var current: BounceAnswer = .{};
    current.remember("First answer");
    current.remember(" \n ");
    try std.testing.expectEqualStrings("First answer", current.finish(&self, "See previous answer"));
    self.tool_calls_this_turn = 2;
    try std.testing.expectEqualStrings("Updated answer", current.finish(&self, "Updated answer"));
}

test "#1013 without a bounce note the follow-up is the answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var self = pendingFixture(arena.allocator());
    self.tool_calls_this_turn = 0;
    var current: BounceAnswer = .{};
    current.remember(" \n ");
    try std.testing.expectEqualStrings("Current answer", current.finish(&self, "Current answer"));
}

/// Handle a degenerate completion inside runTurn. Returns true when the
/// caller should `continue` the loop.
pub fn handle(self: *Agent, final_text: []const u8, hist_len: usize) !bool {
    if (shouldRetry(final_text, self.empty_completion_retries)) {
        const keep = @min(hist_len, self.messages.items.len);
        const reasoned = reasonedWithoutAnswer(self.messages.items[keep..]);
        self.empty_completion_retries += 1;
        self.closeCodexWs();
        self.messages.shrinkRetainingCapacity(keep);
        if (reasoned) {
            try self.messages.append(try messages.userNote(self.arena, self.provider.kind, reasoning_budget_note));
            try self.say("[model reasoned without answering — retrying with a brief-answer note ({d}/{d})]\n", .{ self.empty_completion_retries, max_consecutive });
        } else try self.say("[model returned an empty completion — retrying ({d}/{d})]\n", .{ self.empty_completion_retries, max_consecutive });
        return true;
    }
    if (@import("task_intent.zig").current(self) == .informational) return false;
    if (@import("exact_reply.zig").requested(messages.latestUserText(self.messages.items))) return false;
    if (no_local_tools.enabled) return false;
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
            try self.messages.append(try @import("session_wake.zig").mark(self.arena, try @import("named_work.zig").userNudge(self.arena, self.provider.kind, body)));
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
    try std.testing.expect(@import("session_wake.zig").isNotice(self.messages.items[0]));
    const reminder = try std.json.Stringify.valueAlloc(self.arena, self.messages.items[0], .{});
    try std.testing.expect(std.mem.indexOf(u8, reminder, "finish") != null);
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
        const notice = self.messages.items[self.messages.items.len - 1];
        try std.testing.expect(@import("session_wake.zig").isNotice(notice));
        try std.testing.expectEqualStrings("", messages.latestUserText(self.messages.items));
        const body = try std.json.Stringify.valueAlloc(self.arena, notice, .{});
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

test "completed informational answer is not an edit-oriented fake_done retry" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var self = pendingFixture(state.allocator());
    self.empty_completion_retries = 0;
    const old_unattended = main_mod.unattended;
    const old_lean = no_local_tools.lean;
    main_mod.unattended = true;
    no_local_tools.lean = true;
    defer {
        main_mod.unattended = old_unattended;
        no_local_tools.lean = old_lean;
    }
    self.tool_calls_this_turn = 0;
    self.model_calls_this_turn = 1;
    try self.messages.append(try messages.textMessage(self.arena, "user", "Summarize the architecture"));
    const before = self.messages.items.len;
    try std.testing.expect(!try handle(&self, "The app separates its UI, parser, and storage.", before));
    try std.testing.expectEqual(before, self.messages.items.len);
}

test "no-local-tools lean critique is not an edit-oriented fake_done retry" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var self = pendingFixture(state.allocator());
    self.empty_completion_retries = 0;
    const old_unattended = main_mod.unattended;
    const old_lean = no_local_tools.lean;
    const old_enabled = no_local_tools.enabled;
    main_mod.unattended = true;
    no_local_tools.lean = true;
    no_local_tools.enabled = true;
    defer {
        main_mod.unattended = old_unattended;
        no_local_tools.lean = old_lean;
        no_local_tools.enabled = old_enabled;
    }
    self.tool_calls_this_turn = 0;
    self.model_calls_this_turn = 1;
    try self.messages.append(try messages.textMessage(self.arena, "user", "Critique this design; do not inspect or edit files"));
    const before = self.messages.items.len;
    try std.testing.expect(!try handle(&self, "The design is coherent and needs no local changes.", before));
    try std.testing.expectEqual(before, self.messages.items.len);
}

test "exact reply bypasses only fake done while mixed requests and empty replies still retry" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const old_unattended = main_mod.unattended;
    const old_lean = no_local_tools.lean;
    const old_enabled = no_local_tools.enabled;
    main_mod.unattended = true;
    no_local_tools.lean = true;
    no_local_tools.enabled = false;
    defer {
        main_mod.unattended = old_unattended;
        no_local_tools.lean = old_lean;
        no_local_tools.enabled = old_enabled;
    }
    const cases = .{
        .{ "Reply with exactly: pong", "pong", false },
        .{ "Reply with exactly: \"run tests and deploy\"", "run tests and deploy", false },
        .{ "Reply with exactly: \"pong\"; then edit target.txt", "pong", true },
        .{ "Reply with exactly: pong", " ", true },
    };
    inline for (cases) |case| {
        var self = pendingFixture(state.allocator());
        self.empty_completion_retries = 0;
        self.codex_ws = null;
        self.codex_prev_id = null;
        self.call_kind = .title; // suppress fixture notices without initializing a writer
        self.tool_calls_this_turn = 0;
        self.model_calls_this_turn = 1;
        try self.messages.append(try messages.textMessage(self.arena, "user", case[0]));
        const before = self.messages.items.len;
        try std.testing.expectEqual(case[2], try handle(&self, case[1], before));
        const empty = std.mem.trim(u8, case[1], " \t\r\n").len == 0;
        try std.testing.expectEqual(@as(usize, if (case[2] and !empty) before + 1 else before), self.messages.items.len);
        try std.testing.expectEqual(@as(u8, if (empty) 1 else 0), self.empty_completion_retries);
    }
}
