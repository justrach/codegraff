//! #884: task intent for the current user ask.
//!
//! Default coding policy is mutation-complete (plan, fan-out, verify). A
//! summarize/explain/inspect request with no requested change is informational:
//! the harness traces that, skips the lean fake_done bounce, and after a
//! bounded number of model rounds asks whether the model can answer now.
//! Mutation verbs win when both are present.

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const named_work = @import("named_work.zig");
const messages = @import("messages.zig");

pub const Kind = enum { informational, mutation };

pub const checkpoint_after: u64 = 6;

pub const checkpoint_note =
    "Informational turn: you have already inspected the repo for several rounds. " ++
    "If you can write a concise summary of purpose, architecture, and important constraints, do so now. " ++
    "Do not create a todo, fan out, run builds or tests, or do a separate citation pass unless a factual gap remains.";

var g_checkpointed: bool = false;

pub fn resetForTest() void {
    g_checkpointed = false;
}

const informational_needles = [_][]const u8{
    "summarize",
    "summarise",
    "explain ",
    "go through",
    "what does",
    "what is this",
    "overview",
    "inspect ",
    "how does this",
    "how does it work",
    "describe ",
    "map the",
    "map this",
    "a summary",
    "an overview",
    "the summary",
};

const mutation_needles = [_][]const u8{
    "fix ",
    "fix\n",
    "fix the",
    "fix this",
    "implement",
    "refactor",
    "patch ",
    "commit ",
    "add a ",
    "add the ",
    "edit ",
    "change ",
    "delete ",
    "create ",
    "apply ",
    "make it ",
    "run test",
    "run the test",
};

fn containsInsensitive(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlInsensitive(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn eqlInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

fn hasMutation(prompt: []const u8) bool {
    for (mutation_needles) |n| {
        if (containsInsensitive(prompt, n)) return true;
    }
    if (containsInsensitive(prompt, "write a summary") or containsInsensitive(prompt, "write an overview"))
        return false;
    return containsInsensitive(prompt, "write ");
}

fn hasInformational(prompt: []const u8) bool {
    for (informational_needles) |n| {
        if (containsInsensitive(prompt, n)) return true;
    }
    return false;
}

pub fn classify(prompt: []const u8) Kind {
    if (hasMutation(prompt)) return .mutation;
    if (hasInformational(prompt)) return .informational;
    return .mutation;
}

pub fn isInformational(prompt: []const u8) bool {
    return classify(prompt) == .informational;
}

pub fn shouldCheckpoint(informational: bool, model_calls: u64, already: bool, sub: bool) bool {
    if (!informational or already or sub) return false;
    return model_calls >= checkpoint_after;
}

fn promptOf(self: *const Agent) []const u8 {
    if (self.named_work_task.len > 0) return self.named_work_task;
    return messages.latestUserText(self.messages.items);
}

/// First inner-loop request of a root turn: record intent on the trace.
/// Sixth+: one informational checkpoint, then the model may answer.
pub fn onRequest(self: *Agent) !void {
    if (self.sub or self.review_mode or self.text_only) return;
    if (self.model_calls_this_turn == 1) g_checkpointed = false;
    const informational = isInformational(promptOf(self));
    if (self.model_calls_this_turn == 1) {
        if (self.tracer) |tr| tr.note("task_intent", if (informational) "informational" else "mutation");
    }
    if (!shouldCheckpoint(informational, self.model_calls_this_turn, g_checkpointed, self.sub)) return;
    g_checkpointed = true;
    self.closeCodexWs();
    try self.messages.append(try named_work.userNudge(self.arena, self.provider.kind, checkpoint_note));
    if (self.tracer) |tr| tr.note("task_intent", "informational checkpoint");
}

test "#884 summarize/explain/inspect without a change is informational" {
    try std.testing.expect(isInformational("go through the codebase and summarize what it does"));
    try std.testing.expect(isInformational("Explain how the auth flow works"));
    try std.testing.expect(isInformational("write a summary of this repo"));
    try std.testing.expect(isInformational("map the architecture of this project"));
    try std.testing.expect(isInformational("what does this codebase do at a high level"));
    try std.testing.expect(isInformational("inspect the layout and describe the main constraints"));
}

test "#884 mutation verbs win, including summarize-then-fix" {
    try std.testing.expect(!isInformational("summarize the bug then fix the leak"));
    try std.testing.expect(!isInformational("inspect src/foo.zig and fix the failing test"));
    try std.testing.expect(!isInformational("implement the health endpoint"));
    try std.testing.expect(!isInformational("add a test for parser.py"));
    try std.testing.expect(!isInformational("thanks"));
    try std.testing.expect(!isInformational(""));
    try std.testing.expectEqual(Kind.mutation, classify("run tests and report"));
}

test "#884 informational checkpoint fires once at the bound, never for mutation or subagents" {
    try std.testing.expect(!shouldCheckpoint(true, 5, false, false));
    try std.testing.expect(shouldCheckpoint(true, 6, false, false));
    try std.testing.expect(!shouldCheckpoint(true, 6, true, false));
    try std.testing.expect(!shouldCheckpoint(true, 6, false, true));
    try std.testing.expect(!shouldCheckpoint(false, 12, false, false));
}

test "#884 checkpoint note asks to answer now without tests or a citation pass" {
    try std.testing.expect(std.mem.indexOf(u8, checkpoint_note, "Informational turn:") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint_note, "do so now") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint_note, "citation pass") != null);
}
