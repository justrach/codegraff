//! Last-resort context recovery when compact() itself can't run.
//!
//! Split from agent_compact.zig for the 600-line ceiling: the summary path
//! owns history rewriting, this module owns what happens when the summary
//! request itself cannot run (overflow) or twice proves unusable. Re-exported
//! through agent_compact so existing call sites and tests keep compiling.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const goal_flow = @import("goal_flow.zig");
const prompts = @import("prompts.zig");
const compact_cut = @import("compact_cut.zig");
const compact = @import("agent_compact.zig");
const server_compact = @import("agent_server_compact.zig");

const emergencyCutIndex = compact_cut.emergencyCutIndex;

/// Last-resort context recovery when compact() itself can't run — typically
/// because the history already overflows the window, so the summarization
/// request overflows too and fails. Drops the oldest messages at a safe
/// boundary; returns the count dropped (0 if none). Conservatively reduce the
/// authoritative meter only by the locally measurable reclaimed tokens: hidden
/// server-side reasoning may make the true reduction larger, but must never let
/// a partial trim blind the next pre-send gate.
pub fn emergencyTrim(self: *Agent) usize {
    if (emergencyCutIndex(self.messages.items)) |cut| {
        const before_tokens = self.fullInputEstimateTokens();
        var fresh = std.json.Array.init(self.arena);
        for (self.messages.items[cut..]) |m| fresh.append(m) catch return 0;
        self.messages = fresh;
        self.goal_note_fp = 0; // trimmed history may have carried the goal note (#318)
        self.history_rewrites +%= 1; // and the run's checklist gate's pasted copies (#318)
        // No synthetic message exists here to hang the standing state on (unlike
        // compact()'s handoff), so it rides the next turn's one-shot slot. Only
        // when that slot is free: a queued /goal replace|clear note is the USER's
        // instruction and outranks the harness restating itself (#318).
        if (self.pending_goal_note == null)
            self.pending_goal_note = goal_flow.compactionSnapshot(self.arena, self) catch null;
        const after_tokens = self.fullInputEstimateTokens();
        compact.accountForReclaimedTokens(self, before_tokens -| after_tokens);
        @import("context_savings.zig").noteCompaction(before_tokens, after_tokens);
        return cut;
    }
    // #163: no clean user turn to cut at (a runaway tool loop). Don't wedge the
    // session — reclaim context by truncating the oldest tool outputs in place,
    // keeping every call/output pair valid. Nonzero = recovered. This too is a
    // rewrite: the stubbed outputs may include the last todo_write render the
    // suppressed run note points the model at (#318).
    if (compact.trimOldestToolOutputs(self) > 0) {
        self.history_rewrites +%= 1;
        if (self.pending_goal_note == null)
            self.pending_goal_note = goal_flow.compactionSnapshot(self.arena, self) catch null;
        return 1;
    }
    return 0;
}

/// Auto-compaction with recovery. compact() summarizes the whole history in
/// one request; once context overflows the window that request overflows too
/// and fails — historically swallowed silently, wedging the session so every
/// later turn failed at the same huge token count (issue #88). Surface the
/// failure and, when `trim_on_fail`, emergency-trim so the next turn has
/// room. Best-effort; never throws into the REPL loop.
pub fn repeatedOpaqueCompactionFailure(self: *Agent, err: anyerror) bool {
    const opaque_transport = err == error.ApiError and self.last_request_write_failed;
    if (opaque_transport)
        self.compact_transport_failures +|= 1
    else
        self.compact_transport_failures = 0;
    const threshold = self.provider.compactAt();
    const effective = self.effectiveContextTokens();
    const locally_over_window = self.provider.context > 0 and self.fullRequestEstimateTokens() >= self.provider.context;
    return opaque_transport and
        threshold > 0 and
        self.compact_transport_failures >= 2 and
        (self.provider.nearContextLimit(effective) or locally_over_window);
}

/// #379: two consecutive COMPLETED-but-unusable summaries (empty or truncated)
/// are provably not transport noise — the model, at this context size, is not
/// going to produce one, and without escalation the over-cap history is
/// re-shipped forever. Unlike compact_transport_failures this counter survives
/// a complete response; only a usable summary (or a trim) resets it.
pub fn repeatedEmptySummaryFailure(self: *Agent, err: anyerror) bool {
    const unusable = err == error.EmptySummary or err == error.IncompleteSummary;
    if (unusable) self.compact_summary_failures +|= 1 else self.compact_summary_failures = 0;
    const threshold = self.provider.compactAt();
    return unusable and threshold > 0 and
        self.compact_summary_failures >= 2 and
        self.effectiveContextTokens() >= threshold;
}

pub fn compactOrRecover(self: *Agent, trim_on_fail: bool) void {
    if (compact_cut.lastIsResolved(self.messages.items)) {
        self.compact_pin_degraded = false;
        compact_cut.resetStall(&self.compact_stall);
    }
    if (self.compact_pin_degraded and !trim_on_fail) return;
    const has_opaque = @import("compaction_window.zig").latestBlob(self.messages.items) != null;
    // ADR 0259: first-party Responses routes compact only server-side, so they
    // never reach compact() (the client summary, or Clef's hook at its top).
    const result = if (has_opaque or server_compact.serverOnly(self.provider)) server_compact.manualCompact(self) else self.compact();
    if (result) |_| {
        self.compact_transport_failures = 0;
        return;
    } else |err| {
        switch (err) {
            error.Interrupted => {
                self.compact_transport_failures = 0;
                return; // user hit Esc mid-compaction
            },
            error.CompactionOff => return, // explicit credit policy: preserve history without emergency trimming
            error.EmptySummary, error.IncompleteSummary, error.ActivePromptPinned => {}, // compact() already explained it
            else => {
                if (main_mod.json_mode)
                    self.emit(.{ .type = "error", .message = std.fmt.allocPrint(self.arena, "auto-compaction failed: {s}", .{@errorName(err)}) catch "auto-compaction failed" })
                else
                    self.say("[auto-compaction failed: {t}]\n", .{err}) catch {};
            },
        }
        if (has_opaque) return; // server failed: preserve its canonical window, never emergency-trim it
        const repeated_opaque_overflow = repeatedOpaqueCompactionFailure(self, err);
        const repeated_empty_summary = repeatedEmptySummaryFailure(self, err);
        // The caller's policy is computed before compact() makes its summary
        // request. Override it only for a concrete provider overflow rejection,
        // after two consecutive WriteFailed compaction attempts when the
        // effective meter is near 95% (or local bytes prove over-window), or
        // after two complete-but-unusable summaries while over compact@ (#379).
        // The first failure and ordinary transport outages preserve history.
        if (!trim_on_fail and !self.last_request_context_overflow and !repeated_opaque_overflow and !repeated_empty_summary) return;
        const dropped = self.emergencyTrim();
        if (dropped > 0) {
            self.compact_transport_failures = 0;
            self.compact_summary_failures = 0;
            // #445: a trim is the harsher half of the same boundary — the model
            // lost that history WITHOUT even a summary standing in for it, so
            // the transcript line is worth more here, not less. Hooked at this
            // call site rather than inside emergencyTrim() because the direct
            // emergencyTrim callers drive partially-initialized test agents.
            prompts.noteSessionCompacted(self, self.arena);
            @import("hot_context.zig").afterCompact(self);
            if (main_mod.json_mode)
                self.emit(.{ .type = "compact", .ok = true, .trimmed = dropped })
            else
                self.say("[context emergency-trimmed: dropped {d} old message(s) so the session can continue]\n", .{dropped}) catch {};
        } else if (!main_mod.json_mode) {
            self.say("[warning: context too large to compact and could not be trimmed safely]\n", .{}) catch {};
        }
    }
}
