//! Task-outcome telemetry (#compact-ab follow-up): did the session's goal
//! actually get DONE, and at what effort — per compaction arm.
//!
//! One OTLP record per goal outcome: body="task", kind="goal",
//! detail="completed|abandoned arm=server|client|other", plus numeric attrs
//! (turns, calls, compactions, duration_ms) serialized by telemetry.zig's
//! body=="task" branch and stored verbatim in the worker's attrs JSON. The
//! /v1/stats rollup (TASK_OUTCOME_SQL in zigrepper's harness-telemetry)
//! groups these by arm — completion rate and effort per arm is the
//! ship/rollback signal for server-side compaction.
//!
//! Emission points:
//!   - noteGoalSet: goal_flow's two set sites — snapshots the session
//!     counters into the Goal so completion can diff effort.
//!   - noteGoalCompleted: agent_tools handleMeta attempt_completion (root
//!     only, after the gates pass).
//!   - noteSessionEnd: session_run.finalizeSession — a non-standing goal
//!     still active/blocked at exit counts as abandoned. Paused is a user
//!     decision and standing goals are open-ended by design: neither counts.
//!
//! Static/numeric content only — the goal's TEXT never leaves the process.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const Goal = @import("agent.zig").Goal;
const Provider = @import("provider.zig").Provider;
const telemetry = @import("telemetry.zig");
const server_compact = @import("agent_server_compact.zig");
const util = @import("util.zig");

/// Which compaction arm a session on this provider is in, for the detail
/// label. Non-Responses providers have no server path at all: "other".
pub fn armLabel(p: Provider) []const u8 {
    if (p.kind != .responses) return "other";
    return if (server_compact.enabled(p)) "server" else "client";
}

pub const Effort = struct { turns: u64, calls: u64, compacts: u64 };

/// Pure diff of session counters against the goal-set snapshot. Saturating:
/// counters only move forward, but a restored session could see smaller ones.
pub fn effortSince(goal: Goal, turns: u64, calls: u64, compacts: u64) Effort {
    return .{
        .turns = turns -| goal.turns_at_set,
        .calls = calls -| goal.calls_at_set,
        .compacts = compacts -| goal.compacts_at_set,
    };
}

fn sessionTurns() u64 {
    const t = telemetry.g_telem orelse return 0;
    return t.turns;
}

fn sessionCalls() u64 {
    const t = telemetry.g_telem orelse return 0;
    return t.tool_calls;
}

fn sessionCompacts() u64 {
    return server_compact.session_prunes +| server_compact.session_summaries;
}

/// Snapshot the effort counters into a freshly set goal. Call right after
/// root.goal is assigned.
pub fn noteGoalSet(root: *Agent) void {
    if (root.goal) |*g| {
        g.turns_at_set = sessionTurns();
        g.calls_at_set = sessionCalls();
        g.compacts_at_set = sessionCompacts();
    }
}

fn pushTask(self: *Agent, outcome: []const u8) void {
    const t = telemetry.g_telem orelse return;
    if (!t.on()) return;
    const g = self.goal orelse return;
    const e = effortSince(g, sessionTurns(), sessionCalls(), sessionCompacts());
    var buf: [40]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, "{s} arm={s}", .{ outcome, armLabel(self.provider) }) catch return;
    const dup = t.gpa.dupe(u8, detail) catch "";
    t.mutex.lockUncancelable(t.io);
    t.push(.{
        .t_ms = t.elapsedMsLocked(),
        .body = "task",
        .kind = "goal",
        .detail = dup,
        .tasks = @intCast(e.turns),
        .phases = @intCast(e.calls),
        .failed = @intCast(e.compacts),
        .ms = util.unixMs(self.io) - g.created_ms,
    });
    t.mutex.unlock(t.io);
    t.maybeFlushEvents();
}

/// attempt_completion passed its gates (agent_tools handleMeta, root only).
pub fn noteGoalCompleted(self: *Agent) void {
    pushTask(self, "completed");
}

/// finalizeSession: a working goal that never completed counts as abandoned.
pub fn noteSessionEnd(root: *Agent) void {
    const g = root.goal orelse return;
    if (g.standing) return; // open-ended by design (#318)
    if (g.status != .active and g.status != .blocked) return;
    pushTask(root, "abandoned");
}

test "armLabel: responses follows the arm, others are out of the experiment" {
    var p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 272_000 };
    try std.testing.expectEqualStrings("client", armLabel(p)); // unassigned in tests → client
    p.kind = .anthropic;
    try std.testing.expectEqualStrings("other", armLabel(p));
    p.kind = .openai;
    try std.testing.expectEqualStrings("other", armLabel(p));
}

test "effortSince: diffs the snapshot, saturates on restored sessions" {
    const g: Goal = .{ .objective = "x", .turns_at_set = 3, .calls_at_set = 10, .compacts_at_set = 1 };
    const e = effortSince(g, 8, 25, 4);
    try std.testing.expectEqual(@as(u64, 5), e.turns);
    try std.testing.expectEqual(@as(u64, 15), e.calls);
    try std.testing.expectEqual(@as(u64, 3), e.compacts);
    const odd = effortSince(g, 1, 0, 0); // counters below the snapshot
    try std.testing.expectEqual(@as(u64, 0), odd.turns);
    try std.testing.expectEqual(@as(u64, 0), odd.calls);
}
