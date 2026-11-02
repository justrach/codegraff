//! Synthesis consumes evidence; it must not become another unbounded review.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const tools = @import("tools.zig");

pub const evidence_requests: u8 = 8;
pub const report_notice = "Internal workflow boundary, not a new user request: synthesis has used its evidence-reading allowance. Tools are now unavailable. Deliver the best summary from the supplied findings and observations, explicitly marking gaps and uncertainty. Do not restart the investigation or claim missing verification succeeded.";
pub const tool_refusal = "Workflow synthesis is now report-only. Summarize the evidence already available; no further tools will run.";

pub fn context(parent: tools.ToolCtx, slot: []const u8) tools.ToolCtx {
    var child = parent;
    child.synthesis = std.mem.eql(u8, @import("shapes.zig").canonicalSlot(slot), "synthesize");
    return child;
}

pub const State = struct {
    enabled: bool = false,
    requests: u8 = 0,
    prior_text_only: ?bool = null,

    pub fn reporting(self: State) bool {
        return self.enabled and self.requests > evidence_requests;
    }

    pub fn keepsCatalog(self: State, agent: *const Agent) bool {
        if (!self.reporting() or (self.prior_text_only orelse true)) return false;
        return switch (agent.provider.kind) {
            .responses => true,
            .openai => !@import("meta_wire.zig").restricted(agent.provider.id, agent.provider.model),
            else => false,
        };
    }

    pub fn beforeRequest(self: *State, agent: *Agent) !void {
        if (!self.enabled) return;
        // Kept on the worker, not the turn stack: transport retries cannot
        // renew the allowance by re-entering runTurn with the same history.
        if (self.reporting()) return error.WorkflowSynthesisLimit;
        if (self.requests == evidence_requests) {
            var note = try @import("named_work.zig").userNudge(agent.arena, agent.provider.kind, report_notice);
            try note.object.put(agent.arena, @import("session_wake.zig").origin_key, .{ .string = "notification" });
            try agent.messages.append(note);
            self.prior_text_only = agent.text_only;
            agent.text_only = true;
            if (agent.tracer) |tr| tr.note("workflow_synthesis", "evidence allowance spent; final report-only request");
        }
        self.requests += 1;
    }

    pub fn finish(self: *State, agent: *Agent) void {
        // Report-only is task-local, not a new durable capability restriction.
        if (self.prior_text_only) |prior| agent.text_only = prior;
        self.prior_text_only = null;
    }
};

/// An aborted final stage does not erase the already-completed review.
pub fn withEvidence(a: std.mem.Allocator, failure: []const u8, previous: []const u8) ![]const u8 {
    if (previous.len == 0) return failure;
    return std.fmt.allocPrint(a, "{s}\n\n## Previous stage evidence (workflow incomplete)\n{s}\n\nUse this evidence with its stated limitations; the failed stage did not verify it.", .{ failure, @import("workflow.zig").cappedPrevBody(a, previous, 6000) });
}

fn fixture(a: std.mem.Allocator) Agent {
    return .{ .gpa = a, .arena = a, .io = std.testing.io, .client = undefined, .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 128000 }, .messages = .init(a), .sub = true, .label = "test", .out = null };
}

test "workflow synthesis bounds exploration and permits one report-only request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var agent = fixture(arena.allocator());
    agent.synthesis.enabled = true;
    for (0..8) |_| {
        try agent.synthesis.beforeRequest(&agent);
        try std.testing.expect(!agent.text_only);
    }
    try agent.synthesis.beforeRequest(&agent);
    try std.testing.expect(agent.text_only);
    try std.testing.expect(agent.synthesis.reporting());
    try std.testing.expect(@import("session_wake.zig").isNotice(agent.messages.items[0]));
    try std.testing.expectError(error.WorkflowSynthesisLimit, agent.synthesis.beforeRequest(&agent));
    try std.testing.expectError(error.WorkflowSynthesisLimit, agent.synthesis.beforeRequest(&agent));
}

test "workflow synthesis restores the original tool restriction before retention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |prior| {
        var agent = fixture(arena.allocator());
        agent.text_only = prior;
        agent.synthesis = .{ .enabled = true, .requests = 8 };
        try agent.synthesis.beforeRequest(&agent);
        try std.testing.expect(agent.text_only);
        try std.testing.expectEqual(!prior, agent.synthesis.keepsCatalog(&agent));
        agent.synthesis.finish(&agent);
        try std.testing.expectEqual(prior, agent.text_only);
        try std.testing.expectError(error.WorkflowSynthesisLimit, agent.synthesis.beforeRequest(&agent));
    }
}

test "workflow synthesis gate refuses tools even when a model ignores report-only choice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var agent = fixture(arena.allocator());
    agent.synthesis = .{ .enabled = true, .requests = 9 };
    const call: tools.ToolCall = .{ .id = "blocked", .name = "shell", .input = .null };
    const denied = (try agent.rejectToolCall(call)).?;
    try std.testing.expect(denied.is_error);
    try std.testing.expectEqualStrings(tool_refusal, denied.text);
}

test "workflow synthesis withdraws catalogs on unsupported report-only wires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var agent = fixture(arena.allocator());
    agent.synthesis = .{ .enabled = true, .requests = 8 };
    try agent.synthesis.beforeRequest(&agent);
    for ([_]@import("provider.zig").Provider.Kind{ .anthropic, .interactions }) |kind| {
        agent.provider.kind = kind;
        try std.testing.expect(!agent.synthesis.keepsCatalog(&agent));
    }
    agent.provider.kind = .openai;
    agent.provider.id = "meta";
    try std.testing.expect(!agent.synthesis.keepsCatalog(&agent));
}

test "workflow synthesis does not cap ordinary workers or discard earlier findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var agent = fixture(a);
    for (0..20) |_| try agent.synthesis.beforeRequest(&agent);
    try std.testing.expect(!agent.text_only);
    try std.testing.expectEqual(@as(u8, 0), agent.synthesis.requests);
    const text = try withEvidence(a, "WorkflowSynthesisLimit", "FINDING: observed evidence");
    try std.testing.expect(std.mem.indexOf(u8, text, "workflow incomplete") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "FINDING: observed evidence") != null);
    try std.testing.expectEqualStrings("failure", try withEvidence(a, "failure", ""));
}
