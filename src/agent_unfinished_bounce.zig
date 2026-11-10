//! Completion-boundary helpers split out of `agent_empty_completion.zig` (600-LOC cap):
//! - `#1882`: graceful fallback summary when the root `#390` final budget-landing call
//!   spends its output tokens in reasoning and returns empty visible text, plus
//!   one-shot `model_landed` completion vs `budget_exhausted` classification.
//! - `#1879`: single-shot unattended (`-p`) bounce when an action turn ran read-only
//!   tools, made zero mutations, and stopped with plain prose admitting unfinished work.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const Kind = @import("provider.zig").Provider.Kind;
const main_mod = @import("main.zig");
const messages = @import("messages.zig");
const no_local_tools = @import("no_local_tools.zig");
const task_intent = @import("task_intent.zig");
const util = @import("util.zig");

pub const landing_empty_prefix = "[budget landing:";
pub const landing_empty_default = "[budget landing: model-call ceiling reached before a final summary was emitted]";

pub const unfinished_action_note =
    "Unfinished-action check: your reply ended the turn in plain text while stating that work or edits remain pending, and no workspace files were modified. " ++
    "If this request requires a code or file change, apply the edit with edit_file / write_file and verify it before concluding; if a concrete blocker prevents the change, state the blocker explicitly.";

/// Extract the last non-empty reasoning string from `turn_msgs`, if any.
pub fn extractReasoningTail(turn_msgs: []const Value) []const u8 {
    var i = turn_msgs.len;
    while (i > 0) {
        i -= 1;
        const m = turn_msgs[i];
        if (m != .object) continue;
        const o = m.object;
        for ([_][]const u8{ "reasoning_content", "reasoning" }) |key| {
            if (o.get(key)) |r| if (r == .string) {
                const t = std.mem.trim(u8, r.string, " \t\r\n");
                if (t.len > 0) return tailUtf8(t, 480);
            };
        }
        if (o.get("content")) |c| if (c == .array) for (c.array.items) |part| {
            if (part == .object) if (part.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "thinking")) {
                if (part.object.get("thinking")) |th| if (th == .string) {
                    const trimmed = std.mem.trim(u8, th.string, " \t\r\n");
                    if (trimmed.len > 0) return tailUtf8(trimmed, 480);
                };
            };
        };
    }
    return "";
}

pub fn extractRootReasoningTail(kind: Kind, root: std.json.ObjectMap) []const u8 {
    switch (kind) {
        .openai => {
            const choices = root.get("choices") orelse return "";
            if (choices != .array or choices.array.items.len == 0 or choices.array.items[0] != .object) return "";
            const msg = choices.array.items[0].object.get("message") orelse return "";
            return extractReasoningTail(&.{msg});
        },
        .anthropic => return extractReasoningTail(&.{.{ .object = root }}),
        .responses => {
            const output = root.get("output") orelse return "";
            return if (output == .array) extractReasoningTail(output.array.items) else "";
        },
        .interactions => return "",
    }
}

fn tailUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var start = s.len - max_bytes;
    while (start < s.len and (s[start] & 0xC0) == 0x80) : (start += 1) {}
    return std.mem.trimStart(u8, s[start..], " \t\r\n");
}

fn isTrailingEmptyAssistantOrReasoning(v: Value) bool {
    if (v != .object) return false;
    if (v.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "reasoning")) return true;
    const role = if (v.object.get("role")) |r| (if (r == .string) r.string else "") else "";
    if (!std.mem.eql(u8, role, "assistant")) return false;
    if (v.object.get("tool_calls")) |tc| if (tc == .array and tc.array.items.len > 0) return false;
    if (v.object.get("content")) |c| switch (c) {
        .string => return std.mem.trim(u8, c.string, " \t\r\n").len == 0,
        .null => return true,
        else => return false,
    };
    return true;
}

/// `#1882`: when the root's `#390` final budget-landing call has zero calls remaining
/// and returned whitespace-only visible text, synthesize a clean fallback summary
/// onto history instead of aborting the whole run with `error.RunBudgetExhausted`.
pub fn settleEmptyLanding(self: *Agent, hist_len: usize, extra_reasoning: []const u8) !?[]const u8 {
    if (self.sub) return null;
    const b = self.run_budget orelse return null;
    if (!b.model_landed.load(.acquire) or b.canAfford(1)) return null;
    const keep = @min(hist_len, self.messages.items.len);
    const from_msgs = extractReasoningTail(self.messages.items[keep..]);
    const snippet = if (from_msgs.len > 0) from_msgs else std.mem.trim(u8, extra_reasoning, " \t\r\n");
    const fallback = if (snippet.len > 0)
        try std.fmt.allocPrint(self.arena, "{s} final call ended in reasoning before visible text] {s}", .{ landing_empty_prefix, tailUtf8(snippet, 480) })
    else
        landing_empty_default;
    while (self.messages.items.len > keep and isTrailingEmptyAssistantOrReasoning(self.messages.items[self.messages.items.len - 1])) {
        _ = self.messages.pop();
    }
    try self.messages.append(try messages.textMessage(self.arena, "assistant", fallback));
    if (self.tracer) |tr| tr.note("budget", "landing call returned empty text; settled with fallback summary (#1882)");
    return fallback;
}

/// True when `answer` explicitly states that requested work is incomplete or budget-blocked.
pub fn admitsUnfinishedWork(answer: []const u8) bool {
    const needles = [_][]const u8{
        "partial work",
        "work remains",
        "still pending",
        "continue with more budget",
        "model-call budget exhausted",
        "exhausted its budget",
        "haven't applied",
        "have not applied",
        "not yet applied",
        "next step is to edit",
        "next step is to apply",
        "i will now edit",
        "i'll now edit",
        "let me now edit",
        "let me now apply",
    };
    for (needles) |needle| {
        if (util.indexOfIgnoreCase(answer, needle) != null) return true;
    }
    return false;
}

/// `#1882`: decide whether a one-shot run whose final admitted call fired `model_landed`
/// actually exhausted its budget mid-work (`true` -> exit 3 `budget_exhausted`) vs used
/// call `N` cleanly to deliver its final completion summary after finishing work (`false`).
pub fn landedBudgetExhausted(root: *const Agent, prompt_text: []const u8, answer: []const u8) bool {
    const b = root.run_budget orelse return false;
    if (!b.model_landed.load(.acquire)) return false;
    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, landing_empty_prefix)) return true;
    if (admitsUnfinishedWork(trimmed)) return true;
    // If call 1 itself withheld tools on an action request before any tool could run
    // (`--max-model-calls 1`), the run never got to act and remains `budget_exhausted`.
    if (root.tools_used.entries.items.len == 0 and task_intent.requestsAction(prompt_text)) return true;
    return false;
}

fn hasWorkspaceMutation(self: *const Agent) bool {
    if (self.snapshots) |snaps| {
        if (snaps.list.items.len > 0) return true;
    }
    for (self.tools_used.entries.items) |e| {
        if (e.err) continue;
        if (std.mem.eql(u8, e.name, "edit_file") or
            std.mem.eql(u8, e.name, "write_file") or
            std.mem.eql(u8, e.name, "apply_patch")) return true;
    }
    return false;
}

/// `#1879`: in unattended `-p` mode, if an action turn ran tools (`tool_calls_this_turn > 0`),
/// performed zero file mutations, and stopped with plain prose admitting unfinished work
/// while model-call budget remains, bounce at most once so the agent applies the fix.
pub fn maybeBounceUnfinishedStop(self: *Agent, final_text: []const u8, bounced_once: *bool) !bool {
    if (bounced_once.*) return false;
    if (!main_mod.unattended or self.sub or self.text_only or self.read_only or self.review_mode) return false;
    if (main_mod.plan_mode or no_local_tools.enabled or self.output_schema != null) return false;
    if (self.tool_calls_this_turn == 0) return false;
    if (hasWorkspaceMutation(self)) return false;
    if (task_intent.current(self) == .informational) return false;
    const user_text = messages.latestUserText(self.messages.items);
    if (!task_intent.requestsAction(user_text)) return false;
    if (!admitsUnfinishedWork(final_text)) return false;
    if (!@import("agent_empty_completion.zig").PendingWork.canRequest(self)) return false;

    bounced_once.* = true;
    try self.messages.append(try messages.userNote(self.arena, self.provider.kind, unfinished_action_note));
    try self.say("[stopped with unfinished-work prose and zero edits — asking once more]\n", .{});
    if (self.tracer) |tr| tr.note("unfinished_stop", "unattended action turn stopped without edits; bounced once (#1879)");
    return true;
}

fn testRootFixture(a: std.mem.Allocator) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "", .context = 100_000 },
        .messages = .init(a),
        .sub = false,
        .label = "test",
        .out = null,
        .call_kind = .title,
    };
}

test "#1882: settleEmptyLanding synthesizes fallback preserving landing note and landedBudgetExhausted classifies clean vs incomplete landings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var self = testRootFixture(a);
    var budget: @import("run_budget.zig").RunBudget = .{ .max_model_calls = 2 };
    budget.model_calls.store(2, .release);
    budget.model_landed.store(true, .release);
    self.run_budget = &budget;

    try self.messages.append(try messages.textMessage(a, "user", "Fix gates.txt and verify."));
    const hist_len = self.messages.items.len;
    try self.messages.append(try messages.userNote(a, self.provider.kind, "[budget landing]"));
    try self.messages.append(try std.json.parseFromSliceLeaky(
        Value,
        a,
        "{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":\"Verified test_no_cycles passes on gates.txt.\"}",
        .{},
    ));

    const fallback = (try settleEmptyLanding(&self, hist_len, "")).?;
    try std.testing.expect(std.mem.startsWith(u8, fallback, landing_empty_prefix));
    try std.testing.expect(std.mem.indexOf(u8, fallback, "Verified test_no_cycles passes on gates.txt.") != null);
    // Landing userNote is preserved and trailing empty assistant was replaced with fallback.
    try std.testing.expectEqual(@as(usize, 3), self.messages.items.len);
    try std.testing.expectEqualStrings(fallback, self.messages.items[2].object.get("content").?.string);
    try std.testing.expect(landedBudgetExhausted(&self, "Fix gates.txt and verify.", fallback));

    // Zero tools used on an action prompt (`--max-model-calls 1`) stays budget_exhausted.
    try std.testing.expect(landedBudgetExhausted(&self, "Write result.txt", "Done."));
    // Partial-work prose stays budget_exhausted even after tools ran.
    self.tools_used.add(self.io, a, "write_file", false);
    try std.testing.expect(landedBudgetExhausted(&self, "Write result.txt", "Partial work remains; continue with more budget."));
    // Tools ran and call N emitted a clean completion answer -> completed (not budget_exhausted).
    try std.testing.expect(!landedBudgetExhausted(&self, "Write result.txt", "Wrote result.txt and verified contents."));
}

test "#1879: maybeBounceUnfinishedStop bounces once on zero-mutation unattended unfinished prose and skips mutated or spent turns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved_unattended = main_mod.unattended;
    const saved_plan = main_mod.plan_mode;
    const saved_nlt = no_local_tools.enabled;
    main_mod.unattended = true;
    main_mod.plan_mode = false;
    no_local_tools.enabled = false;
    defer {
        main_mod.unattended = saved_unattended;
        main_mod.plan_mode = saved_plan;
        no_local_tools.enabled = saved_nlt;
    }

    var self = testRootFixture(a);
    self.tool_calls_this_turn = 4;
    self.tools_used.add(self.io, a, "read_file", false);
    try self.messages.append(try messages.textMessage(a, "user", "Fix the crash in parser.go and run tests."));

    var bounced = false;
    try std.testing.expect(!try maybeBounceUnfinishedStop(&self, "The parser already handles empty inputs cleanly.", &bounced));
    try std.testing.expect(try maybeBounceUnfinishedStop(&self, "I found the bug; the fix is still pending and I will now edit parser.go.", &bounced));
    try std.testing.expect(!try maybeBounceUnfinishedStop(&self, "Still pending.", &bounced));

    var mutated = false;
    self.tools_used.add(self.io, a, "edit_file", false);
    try std.testing.expect(!try maybeBounceUnfinishedStop(&self, "Partial work remains.", &mutated));
}
