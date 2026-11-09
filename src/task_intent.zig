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
    \\When inspecting or analyzing another chat or session's trajectory, keep the
    \\investigation read-only in this session: never message, wake, steer, or
    \\recruit the inspected chat as a worker unless the user explicitly asks to.
    \\When asked to locate a prior chat or session, report its verified user-facing
    \\title and chat ID (including archived status when applicable) after opening
    \\candidate transcripts as needed; never present an internal engine-session ID
    \\alone as a chat locator or claim a title is unrecoverable when listing
    \\metadata merely had a generic title or unrelated preview.
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
    // "file an issue", "open a GitHub issue", "report it": publishing is work
    // to do, so an explanation that also asks for one stays general (#1581).
    var publish_window: u8 = 0;
    var after_report = false;
    var previous: []const u8 = "";
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n,;:!?()[]{}\"`");
    while (words.next()) |raw| {
        const word = std.mem.trim(u8, raw, ".");
        if (after_report and oneOf(word, &.{ "it", "this", "that", "them" })) return .general;
        if (publish_window > 0) {
            if (oneOf(word, &.{ "issue", "issues", "ticket", "bug", "pr" })) return .general;
            publish_window -= 1;
        }
        after_report = std.ascii.eqlIgnoreCase(word, "report");
        if (oneOf(word, &.{ "file", "open", "raise", "post", "submit", "publish", "report" })) publish_window = 3;
        if (actionWord(word, previous)) return .general;
        if (oneOf(word, &.{ "summarize", "summarise", "summary", "explain", "describe", "overview", "map", "research", "investigate", "lookup" })) informational = true;
        if (std.ascii.eqlIgnoreCase(word, "read-only")) informational = true;
        previous = word;
    }
    return if (informational) .informational else .general;
}

const action_words = [_][]const u8{
    "fix",        "fixing",       "fixes",      "edit",      "editing",    "edited",    "edits",
    "implement",  "implementing", "add",        "adding",    "remove",     "removing",  "delete",
    "deleting",   "rename",       "refactor",   "write",     "writing",    "create",    "creating",
    "created",    "update",       "updating",   "updated",   "updates",    "patch",     "patching",
    "build",      "test",         "lint",       "run",       "merge",      "push",      "deploy",
    "commit",     "change",       "changing",   "changes",   "modify",     "modifying", "modified",
    "make",       "resolve",      "apply",      "applying",  "replace",    "replacing", "rewrite",
    "rewriting",  "generate",     "generating", "generated", "generation", "produce",   "producing",
    "render",     "rendering",    "save",       "saving",    "draft",      "document",  "documenting",
    "append",     "insert",       "install",    "upgrade",   "revert",     "restore",   "regenerate",
    "write_file", "edit_file",    "imagegen",
};

fn actionWord(word: []const u8, previous: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(word, "read-only")) return false;
    // "report format" names a noun, not a requested mutation. Keep formatting
    // actionable at imperative, request, and coordinated-verb boundaries.
    if (std.ascii.eqlIgnoreCase(word, "format"))
        return oneOf(previous, &.{ "", "please", "and", "then", "also", "to", "you", "we" });
    if (oneOf(word, &action_words)) return true;
    if (std.mem.indexOfScalar(u8, word, '-') != null and std.mem.indexOfScalar(u8, word, '/') == null) {
        var parts = std.mem.tokenizeScalar(u8, word, '-');
        while (parts.next()) |part| if (oneOf(part, &action_words)) return true;
    }
    return false;
}

/// True when the request names something to change or execute. A text-only
/// first answer is unfinished only for such a request (#1518); a question
/// with no action verb is answered by its text.
pub fn requestsAction(text: []const u8) bool {
    var previous: []const u8 = "";
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n,;:!?()[]{}\"`");
    while (words.next()) |raw| {
        const word = std.mem.trim(u8, raw, ".");
        if (actionWord(word, previous)) return true;
        previous = word;
    }
    return false;
}

pub fn current(self: *const Agent) Intent {
    return classify(@import("messages.zig").latestUserText(self.messages.items));
}

pub const read_nudge = "You named a source file but have not inspected it. Read the named path if its contents are needed, then answer the informational request. Do not edit it merely to satisfy a completion check.";

/// Internal reminders arrive in the user role, so each one says it is not a
/// new request and points back at the human's own (#1581).
const reminder_prefix = "Internal reminder, not a new user request. ";

pub const checkpoint = reminder_prefix ++ "Summary scope checkpoint: review the map and targeted evidence already gathered in this turn. A broad batch of reads also counts as exploration; do not follow it with a shell loop reading every remaining file. For repeated scaffolding, explain the sampled pattern and its limits. Can you now explain the repository's purpose, architecture, and important constraints? If so, answer concisely now. Otherwise read only the specific missing evidence. Do not start implementation, a test suite, or a separate citation pass solely to finish a summary. Respect any newer user request that changes the scope.";

/// Every other informational request: bound the exploration without
/// replacing the question the user asked with a repository overview.
pub const scope_checkpoint = reminder_prefix ++ "Scope checkpoint: review the evidence already gathered in this turn. Can you now answer the user's latest request, including every deliverable it named? If so, finish it now. Otherwise read only the specific missing evidence. Do not start a repository overview, a test suite, or a separate citation pass unless the user asked for one.";

/// Only a request for a summary or overview gets the repository checkpoint.
fn summaryRequest(text: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n,;:!?()[]{}\"`");
    while (words.next()) |raw| {
        const word = std.mem.trim(u8, raw, ".");
        if (oneOf(word, &.{ "summarize", "summarise", "summary", "overview", "map" })) return true;
    }
    return false;
}

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
        const text = if (summaryRequest(@import("messages.zig").latestUserText(self.messages.items))) checkpoint else scope_checkpoint;
        var note = try @import("named_work.zig").userNudge(self.arena, self.provider.kind, text);
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
        "Fix src/parser.zig and summarize the change",  "Explain and then refactor the parser",
        "Run tests and describe the results",           "Implement the plan",
        "go on",                                        "hello",
        "Summarize the codebase; then add logging",     "Map the project and build it",
        "Explain the parser and format src/parser.zig", "Describe the output, then format README.md",
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

test "only a request naming an action counts as one (#1518)" {
    for ([_][]const u8{ "Fix src/parser.zig", "Make `python3 test.py` print OK. Do not edit the tests.", "Reply with exactly: pong; then create target.txt", "Format README.md", "Please format src/parser.zig", "Explain the parser and format src/parser.zig" }) |text|
        try std.testing.expect(requestsAction(text));
    for ([_][]const u8{ "What does parse() return for an empty string?", "Which module owns retries?", "what is 2+2", "Explain the bug report format", "Describe the file format" }) |text|
        try std.testing.expect(!requestsAction(text));
}

test "#1581 an explanation that also asks to publish stays actionable" {
    for ([_][]const u8{
        "Explain why the build fails and file an issue",
        "Investigate the crash and open a GitHub issue for it",
        "Explain the error and report it",
        "Research the regression, then raise a ticket",
    }) |text| try std.testing.expectEqual(Intent.general, classify(text));
    try std.testing.expectEqual(Intent.informational, classify("Explain the bug report format"));
    try std.testing.expectEqual(Intent.informational, classify("Describe the file layout"));
    try std.testing.expectEqual(Intent.informational, classify("Describe the file format"));
    try std.testing.expectEqual(Intent.informational, classify("Explain the output format before proceeding"));
}

test "#1581 only a summary request gets the repository checkpoint" {
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
    agent.model_calls_this_turn = 4;
    agent.tool_calls_this_turn = 0;
    try agent.messages.append(try messages.textMessage(a, "user", "Investigate why login fails"));
    var state = State.begin(&agent);
    try state.beforeRequest(&agent);
    const sent = try std.json.Stringify.valueAlloc(a, agent.messages.items[1], .{});
    try std.testing.expect(std.mem.indexOf(u8, sent, "Internal reminder, not a new user request.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "every deliverable it named") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "repository's purpose") == null);
    try std.testing.expectEqualStrings("Investigate why login fails", messages.latestUserText(agent.messages.items));
}

test "#1813 image-generation and documentation-update tasks classify as general, not informational" {
    for ([_][]const u8{
        "Investigate the assets and generate a replacement banner with imagegen",
        "Research the API changes and perform a documentation-update in docs/guide.md",
        "Summarize the release and save the notes using write_file",
        "Explain the layout while updating README.md",
        "Image-generation worker: render the icon and describe the output",
    }) |text| try std.testing.expectEqual(Intent.general, classify(text));
}
