//! The shared agent turn loop, including explicit non-completing handoffs.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const empty_completion = @import("agent_empty_completion.zig");
const turn_inbox = @import("turn_inbox.zig");

pub fn run(self: *Agent, root_turn_prepared: *std.atomic.Value(bool)) anyerror![]const u8 {
    defer @import("jev_effort_state.zig").finishTurn(self);
    errdefer self.jev_effort_pending.invalidate(self.io);
    @import("jev_auto.zig").beginTurn(self); // ADR 0246: Jev picks this turn's effort; finishTurn puts it back
    self.async_tools_armed = !self.sub and self.eval_cmd == null;
    defer self.async_tools_armed = false;
    defer @import("agent_async_tools.zig").reset(self);
    if (!self.sub) @import("peer_idle.zig").noteTurnStart();
    defer if (!self.sub) @import("peer_idle.zig").noteTurnEnd();
    var pending_work = empty_completion.PendingWork.begin(self);
    var bounced_answer: empty_completion.BounceAnswer = .{};
    var length: @import("agent_length.zig").State = .{};
    self.empty_completion_retries = 0;
    self.length_cutoffs = 0; // agent_length_cutoff.zig: rewinds this turn
    self.completed = null;
    self.yielded = null;
    self.read_miss.reset();
    self.tool_repeat.reset();
    self.mcp_context.begin(self.io);
    @import("named_work.zig").beginTurn(self);
    try self.ensureRootTools(self.provider.kind);
    var task_scope = @import("task_intent.zig").State.begin(self);
    if (!self.sub and !root_turn_prepared.swap(false, .acq_rel)) @import("cancel_source.zig").clear();
    var review_deadline = try @import("review_deadline.zig").start(self);
    defer review_deadline.stop();
    while (true) {
        try task_scope.beforeRequest(self);
        if (try @import("turn_chrome.zig").beforeRequest(self)) |paused| return review_deadline.finish(paused);
        // Esc during a tool join lands here; root consumes, subagents bail.
        if (Agent.esc_cancel.load(.acquire)) {
            if (!self.sub) Agent.esc_cancel.store(false, .release);
            return error.Interrupted;
        }
        // Peer mail, job/schedule wakes, and REPL steer land here so a
        // follow-up typed during tools is the next user message in this
        // turn rather than the next prompt after runTurn returns.
        try turn_inbox.deliver(self);
        // #193: pre-send overflow gate. A single turn's tool-output burst can
        // push the input past the model's wall before the between-turns 80%
        // meter (last_context_tokens, server-reported) catches up. Estimate the
        // full input locally and compact BEFORE sending so we never ship an
        // over-cap request (codex run_pre_sampling_compact / opencode isOverflow).
        const over_compact = self.inputOverCompactThreshold();
        @import("compact_backoff.zig").step(&self.compact_backoff, self.history_rewrites, over_compact);
        if (over_compact and !readBatchFirst(self) and !compactionHeld(self)) {
            // Bracket the compaction with codex-WS resets, mirroring how every
            // other compactOrRecover call site is bookended by runTurn's
            // closeCodexWs (299 + defer 300). Mid-turn the WS can be live with a
            // prev_id / codex_sent_upto watermark keyed to the pre-trim history:
            // (1) the first reset lets compact()'s own summary request (it calls
            // request() at agent_compact.zig:267, after shrinking history at
            // 259-260) run against a clean session — a stale prev_id makes the
            // server re-prepend the full pre-trim context, defeating or
            // overflowing the summary itself; (2) the second re-anchors so the
            // next in-turn request() re-sends the trimmed full input, not a delta
            // keyed to dropped messages (same closeCodexWs-after-trim reason as
            // the in-turn recovery at agent_request.zig:273).
            self.closeCodexWs();
            // Match the between-turn policy: at the ordinary compactAt
            // threshold, a transient/empty summary must not immediately drop
            // real history. Destructive recovery is reserved for >=95%.
            const recovery_meter = self.effectiveContextTokens();
            self.autocompact(recovery_meter);
            self.closeCodexWs();
        }
        // ADR 0030: showcase rlm once the existing compact meter is
        // actually large. Schema rides the tail; head bytes stay put.
        if (!self.sub) {
            const fold = @import("native_fold.zig");
            if (fold.noticeContext(self.effectiveContextTokens(), self.provider.compactAt())) {
                self.invalidateRootTools();
                try self.ensureRootTools(self.provider.kind);
            }
        }
        if (self.sub) try self.synthesis.beforeRequest(self);
        const hist_len = self.messages.items.len;
        const root = self.request(if (self.text_only and !self.synthesis.keepsCatalog(self)) null else self.toolsJson()) catch |err| {
            if (try @import("agent_length_cutoff.zig").recoverRunaway(self, err, hist_len)) continue;
            return review_deadline.finish(try @import("agent_model_loop.zig").finishError(self, err));
        };
        // request() may compact history; capture this reply's actual boundary.
        // Keep reasoning available to recovery, then exclude non-replayable
        // empty length replies on every exit before another call or save.
        const reply_start = self.messages.items.len;
        defer @import("agent_length_cutoff.zig").discardEmptyReply(self, root, reply_start);
        const done = try length.step(self, root);
        if (done == null) if (self.tool_repeat.stopText()) |stop| { // #1706: every wire's tool batch lands here
            try self.say("{s}\n", .{stop});
            _ = @import("tool_call_repair.zig").endsTurn(self, stop);
            return review_deadline.finish(stop);
        };
        if (done) |final_text| {
            if (self.yielded != null) return review_deadline.finish(final_text);
            if (@import("tool_call_repair.zig").endsTurn(self, final_text)) return review_deadline.finish(final_text); // final: no retry/nudge
            // Retry empty replies; reconcile plain finals with live work (#745).
            if (try bounced_answer.retry(self, final_text, hist_len)) continue;
            if (try @import("named_work.zig").handle(self, final_text)) continue;
            if (try pending_work.finish(self, bounced_answer.finish(self, final_text))) |text| {
                if (self.feedback) |inbox| if (!inbox.tryFinish(self.io)) continue;
                settleFinal(self);
                return review_deadline.finish(text);
            }
            continue;
        }
        self.empty_completion_retries = 0;
    }
}

/// A root turn that ends with its answer settles the human task (#1137):
/// ambient peer mail then waits for the next human prompt instead of
/// reopening it. A yielded turn is a handoff, already latched harder; a
/// stopped tool loop did not finish the task and settles nothing.
fn settleFinal(self: *Agent) void {
    if (!self.sub) @import("peer_idle.zig").noteFinalAnswer();
}

/// #1686: the previous compaction left the context over the line; wait for
/// real growth (or the 95% wall) instead of compacting on every step.
fn compactionHeld(self: *Agent) bool {
    const context = self.effectiveContextTokens();
    const backoff = @import("compact_backoff.zig");
    switch (backoff.gate(&self.compact_backoff, context, self.provider.context, self.provider.nearContextLimit(context))) {
        .compact => return false,
        .hold => return true,
        .hold_started => {
            if (self.tracer) |tr| tr.note("compact", "held: the last compaction left the context over the line");
            if (!main_mod.json_mode) self.say("[compaction freed too little room; compacting again once the context grows]\n", .{}) catch {};
            return true;
        },
    }
}

/// Over the compaction line, but the history ends on a tool batch the model
/// has not read and almost everything else is that batch. A compaction keeps
/// the batch verbatim (compact_cut.unreadToolBatch), so it could only
/// summarize the small prefix in front of it: a summary round trip that buys
/// little. Send the request instead and compact once the model has read the
/// batch. Near the window (95%) the ordinary recovery runs regardless.
fn readBatchFirst(self: *Agent) bool {
    const compact_cut = @import("compact_cut.zig");
    const items = self.messages.items;
    if (compact_cut.unreadToolBatch(items) == null) return false;
    if (self.provider.nearContextLimit(self.effectiveContextTokens())) return false;
    const start = compact_cut.recentContextStart(items, @import("agent_compact.zig").recent_context_tokens);
    const prefix = compact_cut.suffixTokens(items[0..start], 0);
    if (prefix >= self.provider.compactAt() / 4) return false;
    if (self.tracer) |tr| tr.note("compact", "deferred: the model has not read the newest tool results");
    return true;
}
