//! #1930, ADR 0356: what the pre-send gate does after its compaction failed.
//!
//! The gate compacts because the context is over the compaction line. When
//! that compaction's own request gave up after its full retry ladder
//! (transport give-up, 429/5xx give-up, stall/drop budget) and history is
//! unchanged, the answer request would be the same conversation sent into
//! the same failure under a brand-new ladder: one turn paid two full ladders
//! of a near-identical full-size body. The turn ends instead, with the
//! compaction's error and what to do next. A compaction the provider
//! answered (refused, malformed) proved the route reachable, and a trim or
//! summary changed the payload; both still send the answer as before.

const std = @import("std");
const Agent = @import("agent.zig").Agent;

pub const After = enum { send, end_turn };

/// `ladder_spent`: the compaction's request gave up after its full retry
/// ladder. `history_changed`: anything rewrote history meanwhile (a trim,
/// a summary, a server window), so the answer is a different payload.
pub fn afterCompaction(ladder_spent: bool, history_changed: bool) After {
    return if (ladder_spent and !history_changed) .end_turn else .send;
}

pub const ended_text =
    "Context compaction failed after its full retry budget, so this turn ended without resending the " ++
    "uncompacted conversation. Send the message again once the provider is reachable, run /compact, " ++
    "or start a new chat. Compaction error: ";

/// Runs the gate's compaction and applies the rule. Same engine path for the
/// line REPL and ACP: both drive Agent.runTurn.
pub fn compact(self: *Agent, recovery_meter: u64) !void {
    const rewrites = self.history_rewrites;
    self.last_request_ladder_spent = false; // only this compaction's request may set it
    self.autocompact(recovery_meter);
    if (afterCompaction(self.last_request_ladder_spent, self.history_rewrites != rewrites) == .send) return;
    const cause = self.last_api_error orelse "the compaction request gave up";
    self.last_api_error = std.fmt.allocPrint(self.arena, ended_text ++ "{s}", .{cause}) catch ended_text ++ "see the trace";
    if (self.tracer) |tr| tr.note("compact", "forced compaction spent its retry ladder; answer not resent (#1930)");
    return error.ApiError;
}

test "#1930: a compaction that spent its retry ladder ends the turn unless history changed" {
    try std.testing.expectEqual(After.end_turn, afterCompaction(true, false));
    try std.testing.expectEqual(After.send, afterCompaction(true, true)); // trimmed or summarized: a new payload
    try std.testing.expectEqual(After.send, afterCompaction(false, false)); // answered refusal or no request
    try std.testing.expectEqual(After.send, afterCompaction(false, true));
}
