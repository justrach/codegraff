//! Run-budget admission for one provider request, split from agent_request.zig
//! for the 600-line ceiling.
//!
//! `--max-model-calls` admits logical calls: request() takes one permit, and
//! the transport retries of that call share it (ADR 0169). `--max-model-attempts`
//! is the strict ceiling (#1932, ADR 0355): `Attempts.admit` runs right before
//! every send of the request — the first, each retry, each reconnect — and a
//! refusal ends the request with RunBudgetExhausted, the existing
//! budget-exhausted outcome, carrying the provider error that would otherwise
//! have been retried.

const std = @import("std");
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const run_budget = @import("run_budget.zig");
const wire_messages = @import("messages.zig");
const error_copy = @import("provider_error_copy.zig");

/// #390 — appended once, on the run's final admitted model call, right where
/// the tools disappear, so the model knows WHY and lands instead of retrying.
pub const landing_note =
    "[budget landing] This is the final model call this run's --max-model-calls budget admits, so " ++
    "no tools are offered. Land the answer NOW from the evidence already gathered: state what was " ++
    "completed and what was verified, then name what remains unchecked. Honestly-labeled partial " ++
    "results beat dying mid-tool-call.";

/// One logical call's permit from the shared pool, or null without a budget.
pub fn acquire(self: *Agent) !?run_budget.Permit {
    const budget = self.run_budget orelse return null;
    const kind: run_budget.CallKind = if (self.compaction_request) .compaction else self.call_kind;
    return budget.acquire(self.io, self.depth, kind) catch |err| {
        self.last_api_error = switch (err) {
            error.RunBudgetExhausted => "model-call budget exhausted for this graff run — restart or raise --max-model-calls",
            error.AgentDepthExceeded => "agent depth limit reached (max depth 1)",
            else => @errorName(err),
        };
        if (self.tracer) |tr| tr.note("budget", self.last_api_error.?);
        return err;
    };
}

/// #390 — the landing reserve's root half: the pool's FINAL admitted call
/// belongs to the answer. Offer no tools (compaction's trick) and say why,
/// so the model lands a text answer now instead of asking for a tool the
/// budget can never pay for. compaction/title requests pass tools=null.
pub fn land(self: *Agent, permit: ?run_budget.Permit, tools: *?[]const u8) !void {
    const b = self.run_budget orelse return;
    const p = permit orelse return;
    if (self.compaction_request or b.max_model_calls == 0 or p.call_number != b.max_model_calls or tools.* == null) return;
    b.model_landed.store(true, .release);
    if (!@import("workflow_synthesis.zig").wireSupportsToolChoiceNone(self)) tools.* = null;
    try self.messages.append(try wire_messages.userNote(self.arena, self.provider.kind, landing_note));
    if (self.tracer) |tr| tr.note("budget", "final call: tools withheld so the run lands its answer (#390)");
}

/// A send outside request()'s retry loop: a direct compaction POST, or the
/// WebSocket→SSE fallback inside one attempt (`failed`: why the first send
/// of that attempt did not land). Same ceiling, same refusal.
pub fn admitSend(self: *Agent, failed: ?anyerror) !void {
    var a: Attempts = .{ .sent = @intFromBool(failed != null), .last_err = failed };
    try a.admit(self);
}

/// Per-request send ledger for the strict attempt ceiling.
pub const Attempts = struct {
    sent: usize = 0,
    last_err: ?anyerror = null, // the previous send failed in transport
    last_msg: []const u8 = "", // ...or the provider answered with this error

    pub fn failed(a: *Attempts, err: anyerror) void {
        a.last_err = err;
        a.last_msg = "";
    }

    pub fn rejected(a: *Attempts, msg: []const u8) void {
        a.last_err = null;
        a.last_msg = msg;
    }

    /// Right before bytes go out. The one place every send of a request,
    /// whatever retry path led here, draws from the strict ceiling.
    pub fn admit(a: *Attempts, self: *Agent) !void {
        if (self.run_budget) |budget| _ = budget.reserveAttempt() catch |err| return a.refuse(self, budget.max_model_attempts, err);
        a.sent += 1;
    }

    /// Before a retry's backoff: when no send is left, end now rather than
    /// announce and sleep through a retry that cannot be sent.
    pub fn beforeRetry(a: *Attempts, self: *Agent) !void {
        const budget = self.run_budget orelse return;
        if (!budget.attemptLeft()) return a.refuse(self, budget.max_model_attempts, error.RunBudgetExhausted);
    }

    fn refuse(a: *Attempts, self: *Agent, limit: u64, err: anyerror) anyerror {
        const head = "model-call attempt budget exhausted (--max-model-attempts {d})";
        const why: []const u8 = if (a.last_err) |last| blk: {
            // The give-up copy an exhausted retry ladder would print, so the
            // provider's own failure is what the user reads, not a bare count.
            error_copy.reportTransportGiveUp(self, last, a.sent, main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len], "") catch {};
            break :blk self.last_api_error orelse @errorName(last);
        } else if (a.last_msg.len > 0) blk: {
            const buf = self.arena.alloc(u8, 1024) catch break :blk "the provider returned an error";
            break :blk error_copy.sanitizeMessage(buf, a.last_msg, true);
        } else "";
        self.last_api_error = if (a.sent == 0)
            std.fmt.allocPrint(self.arena, head ++ " before this request was sent. Raise --max-model-attempts or re-run to continue.", .{limit}) catch "model-call attempt budget exhausted"
        else
            std.fmt.allocPrint(self.arena, head ++ ": not resending after {d} attempt(s). Last provider error: {s}", .{ limit, a.sent, why }) catch "model-call attempt budget exhausted";
        if (self.tracer) |tr| tr.note("budget", self.last_api_error.?);
        return err;
    }
};
