//! Conservative per-turn scope hints. These never grant permissions, erase
//! goals, hide tools, or override the user's current request.
const std = @import("std");
const Agent = @import("agent.zig").Agent;

pub const Intent = enum { general, informational };

// Both branches live in the stable prefix. Turn counters and inferred labels
// must not rewrite it on every model request and invalidate history caching.
pub const guidance =
    \\
    \\Task scope: first distinguish an informational request from a request to
    \\change or execute something. A request to summarize, explain, or map a
    \\codebase is complete when you have enough evidence to answer accurately.
    \\It does not authorize edits or require coding-work completion checks.
    \\For a summary, start with one broad map and a small set of targeted reads
    \\covering purpose, entry points, architecture, and important constraints.
    \\For repetitive files, inspect a representative sample and qualify what
    \\you inferred. Do not read an entire directory to prove that every file
    \\matches a pattern already established by the sample.
    \\Answer once those are clear; do not exhaustively read every source/test
    \\file, create a todo, delegate, run build/test/lint/review commands, or make
    \\a separate citation pass just because the repository contains many files.
    \\Run a check only when requested or needed to resolve a specific factual
    \\inconsistency relevant to the answer. Use evidence from existing reads.
    \\For mixed requests, preserve every requested change and verification step.
    \\For changes, retain read-before-edit, root-cause fixes, and verification
    \\in the project's own environment. A summary alone does not finish a fix.
;

fn oneOf(word: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(word, choice)) return true;
    return false;
}

/// Only unambiguous informational verbs opt out of edit-oriented retries.
/// Mixed/unknown requests retain the general policy. This is a scope hint,
/// not a natural-language permission boundary or an enforced tool allowlist.
pub fn classify(text: []const u8) Intent {
    var informational = false;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n,;:!?()[]{}\"`");
    while (words.next()) |raw| {
        const word = std.mem.trim(u8, raw, ".");
        if (oneOf(word, &.{ "fix", "edit", "implement", "add", "remove", "delete", "rename", "refactor", "write", "create", "update", "patch", "build", "test", "lint", "run", "merge", "push", "deploy", "commit" })) return .general;
        if (oneOf(word, &.{ "summarize", "summarise", "summary", "explain", "describe", "overview", "map", "research", "investigate", "lookup" })) informational = true;
        if (std.ascii.eqlIgnoreCase(word, "read-only")) informational = true;
    }
    return if (informational) .informational else .general;
}

pub fn current(self: *const Agent) Intent {
    return classify(@import("messages.zig").latestUserText(self.messages.items));
}

pub const read_nudge = "You named a source file but have not inspected it. Read the named path if its contents are needed, then answer the informational request. Do not edit it merely to satisfy a completion check.";

pub const checkpoint = "Summary scope checkpoint: review the map and targeted evidence already gathered in this turn. A broad batch of reads also counts as exploration; do not follow it with a shell loop reading every remaining file. For repeated scaffolding, explain the sampled pattern and its limits. Can you now explain the repository's purpose, architecture, and important constraints? If so, answer concisely now. Otherwise read only the specific missing evidence. Do not start implementation, a test suite, or a separate citation pass solely to finish a summary. Respect any newer user request that changes the scope.";

pub const State = struct {
    nudged: bool = false,
    review_progress: @import("review.zig").Progress = .{},

    pub fn begin(self: *Agent) State {
        if (self.tracer) |tr| tr.note("task_intent", @tagName(current(self)));
        return .{};
    }

    pub fn beforeRequest(state: *State, self: *Agent) !void {
        try state.review_progress.beforeRequest(self);
        if (state.nudged or self.sub or current(self) != .informational) return;
        if (self.model_calls_this_turn < 4 and self.tool_calls_this_turn < 6) return;
        var note = try @import("named_work.zig").userNudge(self.arena, self.provider.kind, checkpoint);
        try note.object.put(self.arena, @import("session_wake.zig").origin_key, .{ .string = "notification" });
        try self.messages.append(note);
        state.nudged = true;
        if (self.tracer) |tr| tr.note("summary_checkpoint", "bounded exploration reminder; no forced stop");
    }
};

test "informational intent recognizes summaries and keeps mixed execution requests general" {
    for ([_][]const u8{
        "go through the codebase and summarize what it does at /tmp/repo",
        "Explain src/parser.zig",
        "Give me an OVERVIEW of this application.",
        "Summarise the tests and architecture",
        "Describe the deployment flow",
        "Read-only research about public projects",
        "Investigate how this application uses citations",
    }) |text| try std.testing.expectEqual(Intent.informational, classify(text));
    for ([_][]const u8{
        "Fix src/parser.zig and summarize the change", "Explain and then refactor the parser",
        "Run tests and describe the results",          "Implement the plan",
        "go on",                                       "hello",
        "Summarize the codebase; then add logging",    "Map the project and build it",
    }) |text| try std.testing.expectEqual(Intent.general, classify(text));
}

test "informational hints do not match words inside paths or longer words" {
    try std.testing.expectEqual(Intent.general, classify("Open summary.py"));
    try std.testing.expectEqual(Intent.general, classify("the mapper is broken"));
    try std.testing.expectEqual(Intent.informational, classify("Explain /tmp/fix/parser.zig"));
}

test "summary checkpoint is once, preserves the human request, and respects a newer change request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const messages = @import("messages.zig");
    var agent: Agent = undefined;
    agent.arena = a;
    agent.messages = .init(a);
    agent.sub = false;
    agent.review_mode = false;
    agent.tracer = null;
    agent.provider.kind = .openai;
    agent.model_calls_this_turn = 3;
    agent.tool_calls_this_turn = 0;
    try agent.messages.append(try messages.textMessage(a, "user", "Summarize the codebase"));
    var state = State.begin(&agent);
    try state.beforeRequest(&agent);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    agent.model_calls_this_turn = 4;
    try state.beforeRequest(&agent);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expect(@import("session_wake.zig").isNotice(agent.messages.items[1]));
    try std.testing.expectEqualStrings("Summarize the codebase", messages.latestUserText(agent.messages.items));
    try state.beforeRequest(&agent);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try agent.messages.append(try messages.textMessage(a, "user", "Now fix the parser"));
    state = State.begin(&agent);
    try state.beforeRequest(&agent);
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqual(Intent.general, current(&agent));
    try agent.messages.append(try messages.textMessage(a, "user", "Summarize the codebase"));
    state = State.begin(&agent);
    agent.model_calls_this_turn = 1;
    agent.tool_calls_this_turn = 6;
    try state.beforeRequest(&agent);
    try std.testing.expect(state.nudged);
    try std.testing.expectEqual(@as(usize, 5), agent.messages.items.len);
}
