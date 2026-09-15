//! Draft-only completion is an explicit user control, never a model claim.
//! Permission belongs to this conversation and goal; it is not persisted.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const goals = @import("goal_state.zig");
const headers = @import("http_headers.zig");

pub const Scope = struct {
    session: []const u8,
    epoch: u64,

    pub fn matches(self: Scope, session: []const u8, epoch: u64) bool {
        return self.epoch == epoch and std.mem.eql(u8, self.session, session);
    }
};

pub fn allowsDraft(root: *const Agent) bool {
    const scope = root.pr_draft_scope orelse return false;
    return scope.matches(headers.sessionId(root.io), goals.currentEpoch(root.goal));
}

/// Called only by the user-facing slash / JSON input paths, not tool dispatch.
pub fn set(root: *Agent, mode: []const u8) !void {
    if (std.mem.eql(u8, mode, "verified")) {
        root.pr_draft_scope = null;
    } else if (std.mem.eql(u8, mode, "draft")) {
        root.pr_draft_scope = .{
            .session = try root.arena.dupe(u8, headers.sessionId(root.io)),
            .epoch = goals.currentEpoch(root.goal),
        };
    } else return error.InvalidPrAcceptance;
    goals.resetCompletionGate(root);
}

pub fn slash(root: *Agent, line: []const u8, out: *std.Io.Writer) !bool {
    const prefix = "/pr-acceptance";
    if (!std.mem.startsWith(u8, line, prefix) or (line.len > prefix.len and line[prefix.len] != ' ' and line[prefix.len] != '\t')) return false;
    const mode = std.mem.trim(u8, line[prefix.len..], " \t");
    if (mode.len != 0) set(root, mode) catch {
        try out.writeAll("usage: /pr-acceptance [verified|draft]\n");
        try out.flush();
        return true;
    };
    try out.writeAll(if (allowsDraft(root))
        "PR acceptance: draft handoff authorized for this conversation and goal. CI remains unverified. This choice resets on resume, a new conversation, or a new goal.\n"
    else
        "PR acceptance: verified. Draft publication does not fulfill the task; current-head checks must pass.\n");
    try out.flush();
    return true;
}

test "draft acceptance cannot transfer to another conversation or goal" {
    const scope = Scope{ .session = "first", .epoch = 7 };
    try std.testing.expect(scope.matches("first", 7));
    try std.testing.expect(!scope.matches("second", 7));
    try std.testing.expect(!scope.matches("first", 8));
    try std.testing.expect(!scope.matches("first", 0));
}
