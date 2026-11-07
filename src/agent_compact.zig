//! Context management: transactional history compaction and emergency
//! recovery when a summary request cannot run.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const utf8Prefix = @import("util.zig").utf8Prefix;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const goal_flow = @import("goal_flow.zig");
// #445 needs this back: #411 dropped the alias as unused in the same release,
// having moved the last compact_instruction reference into handoff_note, while
// #445 added noteSessionCompacted call sites that reach through it. Neither
// branch could see the other, so the break only appeared at integration.
const prompts = @import("prompts.zig");
const handoff_note = @import("compact_handoff_note.zig"); // #411: both halves of "what survives a compaction"
const peer_context = @import("peer_context.zig"); // ADR 0004: peer injects are not a human turn
const compact_note_glue = @import("compact_note_glue.zig"); // #391
const server_compact = @import("agent_server_compact.zig"); // #compact-ab telemetry
const compact_mix = @import("compact_mix.zig"); // GRAFF_COMPACT_MIX: two-pass extract+synthesis arm

const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;

// #409: the per-output cap's truncation primitives, plus the artifact spill that
// now runs inside them. Moved out of this file, which sits at the 600-line cap.
const tool_spill = @import("tool_spill.zig");
const isToolOutputMsg = tool_spill.isToolOutputMsg;
const truncateToolOutput = tool_spill.truncateToolOutput;

const title_mod = @import("title.zig");
const assistantText = title_mod.assistantText;

const agent_eval = @import("agent_eval.zig");
pub const runEval = agent_eval.runEval;
pub const appendEvalLog = agent_eval.appendEvalLog;
pub const runJudge = agent_eval.runJudge;

pub const recent_context_tokens: u64 = 8_000;
const compact_cut = @import("compact_cut.zig");
pub const recentContextStart = compact_cut.recentContextStart;
pub const cleanUserTurn = compact_cut.cleanUserTurn;
pub const turnOpeningUserIndex = compact_cut.turnOpeningUserIndex;
pub const emergencyCutIndex = compact_cut.emergencyCutIndex;

/// Head-cap for a child's pinned task prompt when restated in a handoff.
/// ~2k tokens; head-capped because a workflow child's prompt carries the
/// previous phase's results as a TAIL, so the head is the instruction.
pub const task_pin_cap: usize = 8_000;

/// Ask the model for a context-handoff summary (no tools), then restart
/// history from that summary.
pub fn summaryResponseComplete(self: *Agent, root: std.json.ObjectMap) bool {
    if (root.get("incomplete")) |value| if (value == .bool and value.bool) return false;
    return switch (self.provider.kind) {
        .responses => true, // parseResponses marks incomplete/missing terminals above
        // The assembler only emits a status when it saw interaction.completed;
        // a truncated stream is already flagged via root.incomplete above.
        .interactions => true,
        .anthropic => blk: {
            // Raw non-streaming compatibility gateways may omit stop_reason.
            // Stream reassembly marks that same absence as root.incomplete, so
            // only an explicit truncating/unknown reason is rejected here.
            const reason = root.get("stop_reason") orelse break :blk true;
            if (reason == .null) break :blk true;
            break :blk reason == .string and
                (std.mem.eql(u8, reason.string, "end_turn") or std.mem.eql(u8, reason.string, "stop_sequence"));
        },
        .openai => blk: {
            const choices = root.get("choices") orelse break :blk false;
            if (choices != .array or choices.array.items.len == 0) break :blk false;
            const choice = choices.array.items[0];
            if (choice != .object) break :blk false;
            // finish_reason is optional on otherwise-valid raw gateway JSON.
            // Assembled streams without a terminal reason carry root.incomplete.
            const reason = choice.object.get("finish_reason") orelse break :blk true;
            if (reason == .null) break :blk true;
            break :blk reason == .string and std.mem.eql(u8, reason.string, "stop");
        },
    };
}

/// The pure prelude of compact(): the early return for an already-empty
/// history and the one-time task-prompt pin for a sub-agent (#B3). Split out
/// of compact() because everything after this point needs a live Io and a
/// network summarization request, so a plain unit test can never reach
/// compact() itself - it can drive this slice directly instead, which is the
/// actual proof that compact() is wired to call pinChildTask: delete the call
/// below and the compactPrelude test goes red, whereas pinChildTask's own
/// isolated tests do not notice.
/// Everything compact() must do before it touches the network, returning the
/// token figure the caller reports. Null means there is nothing to compact.
///
/// It returns that figure DELIBERATELY. An earlier version returned bool and
/// only pinned, which left the call re-inlineable: deleting one line from
/// compact() restored a plausible-looking empty-history check and a compacting
/// child silently lost its task prompt again, with the suite fully green. Now
/// compact() cannot drop the call without losing the number it prints, so the
/// pin cannot be orphaned by a tidy-up that looks harmless.
pub fn compactPrelude(self: *Agent) ?usize {
    // Drop the codex chain BEFORE the summary request. runTurn used to bracket
    // every compaction with closeCodexWs; now that the chain spans user turns,
    // the BETWEEN-turn callers (mainloop's two compactOrRecover sites) have no
    // such bracket. compact() sets stream_quiet, so its summary request goes out
    // over codex HTTP - which rejects previous_response_id outright - and
    // recentContextStart can leave summary_messages LONGER than codex_sent_upto,
    // so the length guard would not catch it. history_rewrites covers the state
    // AFTER compaction; this covers the request compaction itself makes.
    self.closeCodexWs();
    if (self.messages.items.len == 0) return null;
    pinChildTask(self);
    self.last_request_context_overflow = false;
    return self.effectiveContextTokens();
}

pub fn compact(self: *Agent) anyerror!usize {
    // An opaque item anywhere in history needs the server, never a local summary.
    if (@import("compaction_window.zig").latestBlob(self.messages.items) != null) return error.ServerCompactionRequired;
    // ADR 0261: both hosted paths require the existing experimental opt-in.
    const hosted = @import("gateway_compact.zig");
    if (@import("agent_clef_compact.zig").enabled() and hosted.hasLogin(self.io)) {
        if (try hosted.run(self)) |freed| return freed;
    } else if (@import("agent_clef_compact.zig").tryCompact(self)) |n| return n;
    const fork = @import("cache_fork.zig").begin(self); // ADR 0220: read the cached history, not rewrite it
    defer @import("cache_fork.zig").end();
    const pending_tokens = compactPrelude(self) orelse {
        if (!main_mod.json_mode) try self.say("nothing to compact\n", .{});
        return 0;
    };
    // ADR 0021: successful compaction is a status-bar fact, not a transcript
    // row. `/debug` still prints the archaeology.
    if (!main_mod.json_mode and @import("repl.zig").g_debug) try self.say("[compacting ~{d} tokens…]\n", .{pending_tokens});
    // #391: the agent writes its own handoff BEFORE the summarizer rewrites the
    // history it describes. Gated, budgeted, best-effort: every refusal is a
    // named skip, so everything below runs unconditionally.
    const note = compact_note_glue.maybeWrite(self);
    defer if (note == .fire and fork) compact_note_glue.publish(self); // a fork's summary keeps the cached prompt
    // #163: reclaim room BEFORE the summarization request so it fits under the
    // model's input cap. On codex/gpt-5.x an over-cap request fails to WRITE
    // (WriteFailed) rather than returning a clean overflow, so compaction could
    // never run once near the cap. Old tool outputs are superseded by the summary
    // anyway; truncating them keeps the request sendable + all pairing intact.
    // Summary construction is transactional: a failed/empty reply restores the live conversation.
    var compact_arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer compact_arena_state.deinit();
    const compact_arena = compact_arena_state.allocator();
    const live_messages = self.messages;
    const live_context_tokens = self.last_context_tokens;
    const live_context_local_tokens = self.context_local_tokens;
    const live_effective_context = self.effectiveContextTokens();
    const plan = compact_cut.pinDegrade(live_messages.items, recent_context_tokens, self.compact_pin_degraded);
    const suffix = compact_cut.suffixTokens(live_messages.items, plan.start);
    // #706: same unresolved pin that is not shrinking — do not resend an
    // ever-larger current turn. Escalate once, then stay quiet.
    if (compact_cut.noteStall(&self.compact_stall, plan.start, suffix)) {
        compact_cut.noteCut(self.tracer, live_messages.items, plan.start);
        if (!self.compact_pin_degraded) {
            if (!main_mod.json_mode) try self.say("[compaction stalled: the current turn is not shrinking — stopping further cuts]\n", .{});
            self.compact_pin_degraded = true;
        }
        return error.ActivePromptPinned;
    }
    compact_cut.noteCut(self.tracer, live_messages.items, plan.start);
    // #581 residual: a pin that already exceeds the keep budget cannot be
    // summarized. Announce once per unresolved turn, then stay quiet.
    switch (plan.action) {
        .silent => return error.ActivePromptPinned,
        .announce => {
            if (!main_mod.json_mode) try self.say("[compaction skipped: the current prompt's attachments must stay verbatim]\n", .{});
            self.compact_pin_degraded = true;
            return error.ActivePromptPinned;
        },
        .proceed => {},
    }
    const recent_start = plan.start;
    if (plan.pin_over_budget) self.compact_pin_degraded = true;
    const recent_messages = live_messages.items[recent_start..];
    var summary_messages = std.json.Array.init(compact_arena);
    try summary_messages.ensureTotalCapacity(recent_start);
    for (live_messages.items[0..if (fork) live_messages.items.len else recent_start]) |item| {
        if (peer_context.isPeerInject(item)) continue; // ADR 0004: do not ask the summarizer to hoard the room
        try summary_messages.append(try cloneJsonValue(compact_arena, item));
    }
    self.messages = summary_messages;
    var installed_summary = false;
    defer if (!installed_summary) {
        self.messages = live_messages;
        if (self.last_request_context_overflow) {
            self.context_local_tokens = self.fullRequestEstimateTokens();
            self.last_context_tokens = @max(live_effective_context, self.provider.context);
        } else {
            // Summary construction and usage sampling are transactional too.
            self.last_context_tokens = live_context_tokens;
            self.context_local_tokens = live_context_local_tokens;
        }
    };

    try self.messages.append(try textMessage(compact_arena, "user", try compact_mix.summaryRequest(self, compact_arena))); // mix off: handoff_note's request
    // #174: establish the synthetic summary turn before pruning Responses
    // reasoning. An active tool loop's reasoning is newer than the real user
    // turn and must remain while that loop is in flight, but it becomes prior-
    // turn context once this synthetic user request is appended. Pruning first
    // left precisely that large encrypted blob in the full summary resend.
    _ = dropPriorTurnReasoning(self);
    if (!fork) _ = trimOldestToolOutputsAlloc(self, compact_arena);

    var progress = @import("compact_status.zig").begin(self);
    defer progress.end(self);
    var acp_run = @import("acp_compaction.zig").start(!self.sub and self.call_kind != .title);
    defer acp_run.finish(.failed, null, "compaction did not complete; history unchanged"); // no-op after success
    // The handoff summary is internal — don't stream it to the terminal.
    const was_quiet = self.stream_quiet;
    const was_compaction_request = self.compaction_request;
    const was_message_mutation_arena = self.message_mutation_arena;
    self.stream_quiet = true;
    self.compaction_request = true;
    self.message_mutation_arena = compact_arena;
    defer self.stream_quiet = was_quiet;
    defer self.compaction_request = was_compaction_request;
    defer self.message_mutation_arena = was_message_mutation_arena;
    const root = try compact_mix.synthRequest(self, @import("cache_fork.zig").tools(self, fork));
    progress.end(self);
    // Any complete transport response proves the previous opaque failure was
    // transient/non-wedging, even when its summary text is empty or truncated.
    self.compact_transport_failures = 0;
    if (!summaryResponseComplete(self, root)) {
        if (!main_mod.json_mode) try self.say("[compaction failed: provider returned an incomplete summary, history unchanged]\n", .{});
        return error.IncompleteSummary;
    }
    const summary = std.mem.trim(u8, assistantText(self.provider.kind, root), " \t\r\n");
    if (summary.len == 0) {
        if (!main_mod.json_mode) try self.say("[compaction failed: empty summary, history unchanged]\n", .{});
        return error.EmptySummary;
    }

    var fresh = std.json.Array.init(self.arena);
    try fresh.append(try @import("messages.zig").userNote(self.arena, self.provider.kind, try handoffMessage(self, summary, live_messages.items[0..recent_start])));
    // Preserve a valid recent suffix verbatim (up to ~8k estimated tokens),
    // including its user boundary and paired tool calls/results.
    try peer_context.appendWorkingSet(&fresh, recent_messages, live_messages.items);
    self.messages = fresh;
    self.compact_summary_failures = 0; // #379: a usable summary ends the streak
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.goal_note_fp = 0; // the injected goal note died with the old history - re-state in full (#318)
    self.history_rewrites +%= 1; // readers of pasted state (the run's checklist gate) re-carry it (#318)
    installed_summary = true;
    @import("context_savings.zig").noteCompaction(live_effective_context, self.fullRequestEstimateTokens());
    acp_run.finish(.completed, summary, null);
    // #445: the history the model was reading is gone and the durable file is
    // now the only place its exact wording survives, so THIS is where the #410
    // transcript line starts being worth its tokens. It rides this boundary
    // deliberately: the rewrite above already invalidated the provider's cached
    // prefix, so mutating the system prompt here costs nothing extra. Root-only
    // and once per session — prompts.noteSessionCompacted owns both rules.
    prompts.noteSessionCompacted(self, self.arena);
    @import("hot_context.zig").afterCompact(self); // #1333: fold latest keys into the new prefix
    // A/B control arm doing work (#compact-ab): a client-side summary on the
    // Responses wire. Manual /compact on codex lands here too — correctly
    // labeled, since it IS a client compaction.
    if (self.provider.kind == .responses) server_compact.noteClientSummary(summary.len);
    if (!main_mod.json_mode and @import("repl.zig").g_debug) try self.say("[history compacted to a {d}-char summary]\n", .{summary.len});
    return summary.len;
}

/// The message a successful compaction installs as the new history head: the
/// model's handoff summary, plus the harness-kept standing state when a goal is
/// live (#318). That state is HISTORY, not steering, for two reasons: a
/// mid-turn compaction (agent.zig's in-loop call) must reach the tool loop
/// immediately rather than at the next turn boundary, and feeding it through
/// goalSteeringNote would move that note's diff-gate fingerprint on every
/// compaction, defeating the suppression the gate exists for. With no live goal
/// the text is byte-identical to what it always was.
///
/// A subagent's ONLY clean user turn is its task prompt at index 0 (#B3):
/// recentContextStart never keeps a verbatim suffix for a child, since every
/// message after it is either assistant or a tool_result/tool-role turn.
/// Without a pin, compaction would summarize the mandate away with nothing
/// left to restate it - childHandoff below restates it verbatim instead of
/// re-deriving it, so it can never drift or compound across compactions.
/// `discarded` is the history this summary replaces, read only for the #409 artifact paths #411 re-states out of it.
pub fn handoffMessage(self: *Agent, summary: []const u8, discarded: []const Value) ![]const u8 {
    const base = if (self.sub)
        (if (self.task_prompt) |tp| try childHandoff(self, tp, summary) else try rootHandoff(self, summary))
    else
        try rootHandoff(self, summary);
    const standing = try goal_flow.compactionSnapshot(self.arena, self);
    return handoff_note.handoff(self.arena, self, base, standing, discarded);
}

pub fn rootHandoff(self: *Agent, summary: []const u8) ![]const u8 {
    return std.fmt.allocPrint(self.arena,
        \\Context: the earlier conversation was compacted to save space.
        \\Summary of the earlier work:
        \\
        \\{s}
        \\
        \\Continue assisting the user based on this summary. Messages after this one were kept verbatim from the most recent part of the conversation; where they differ from the summary (for example a next step they show as already done), trust them over the summary.
    , .{summary});
}

fn childHandoff(self: *Agent, task_prompt: []const u8, summary: []const u8) ![]const u8 {
    const capped = utf8Prefix(task_prompt, task_pin_cap);
    const truncated_note = if (capped.len < task_prompt.len)
        "\n[task prompt truncated for the handoff - the head above is the mandate]"
    else
        "";
    return std.fmt.allocPrint(self.arena,
        \\Your assigned task, restated verbatim. The conversation that carried it was compacted; this is still your mandate and the only thing you have to deliver:
        \\
        \\{s}{s}
        \\
        \\Context: the earlier conversation was compacted to save space.
        \\Summary of the earlier work:
        \\
        \\{s}
        \\
        \\Continue the assigned task above using this summary of the work already done, and report back as the task requires. Messages after this one were kept verbatim from the most recent part of the conversation; where they differ from the summary (for example a next step they show as already done), trust them over the summary.
    , .{ capped, truncated_note, summary });
}

/// Clone JSON arrays/objects while borrowing immutable leaf strings. Send-time
/// normalization replaces Value slots rather than mutating string bytes, so
/// separate containers are sufficient to isolate a compaction request without
/// duplicating multi-megabyte reasoning and tool-output payloads.
fn cloneJsonValue(arena: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .array => |src| .{ .array = try cloneJsonArray(arena, src) },
        .object => |src| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = src.iterator();
            while (it.next()) |entry|
                try out.put(arena, entry.key_ptr.*, try cloneJsonValue(arena, entry.value_ptr.*));
            break :blk .{ .object = out };
        },
        else => value,
    };
}

pub fn cloneJsonArray(arena: Allocator, src: std.json.Array) Allocator.Error!std.json.Array {
    var out = std.json.Array.init(arena);
    try out.ensureTotalCapacity(src.items.len);
    for (src.items) |item| try out.append(try cloneJsonValue(arena, item));
    return out;
}

/// Capture a subagent's task prompt ONCE, before the first history rewrite.
/// Capturing once is the whole point: after a compaction messages[0] IS the
/// handoff, so re-deriving it would fold each summary into the next without
/// bound. Best-effort - a shape we do not recognise simply leaves the pin unset
/// and behaviour unchanged.
pub fn pinChildTask(self: *Agent) void {
    if (!self.sub or self.task_prompt != null) return;
    if (self.messages.items.len == 0) return;
    const m = self.messages.items[0];
    if (m != .object) return;
    const role = m.object.get("role") orelse return;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return;
    const c = m.object.get("content") orelse return;
    if (c != .string or c.string.len == 0) return;
    self.task_prompt = self.arena.dupe(u8, c.string) catch null;
}

/// #174: drop Responses `reasoning` items older than the last user message,
/// in place (no allocation). These are exactly the items the backend discards
/// from chained context (previous_response_id), so removing them can't lose
/// anything the server would have kept — and on a long high-effort session
/// their encrypted blobs dominate the full-resend size. Reasoning at or after
/// the last user message stays: the API requires the current turn's reasoning
/// between a function_call and its output. Returns how many were dropped.
pub fn dropPriorTurnReasoning(self: *Agent) usize {
    if (self.provider.kind != .responses) return 0;
    var last_user: usize = 0;
    for (self.messages.items, 0..) |m, i| {
        if (m != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role == .string and std.mem.eql(u8, role.string, "user") and !peer_context.isPeerInject(m)) last_user = i;
    }
    var w: usize = 0;
    for (self.messages.items, 0..) |m, i| {
        const old_reasoning = i < last_user and m == .object and blk: {
            const t = m.object.get("type") orelse break :blk false;
            break :blk t == .string and std.mem.eql(u8, t.string, "reasoning");
        };
        if (old_reasoning) continue;
        self.messages.items[w] = m;
        w += 1;
    }
    const dropped = self.messages.items.len - w;
    self.messages.shrinkRetainingCapacity(w);
    return dropped;
}

/// Re-pair the meter after removing locally measurable context. The server-only
/// delta remains intact, while the current local component reflects the trim.
/// Pub for agent_compact_recover.zig (same split that moved the recovery tail).
pub fn accountForReclaimedTokens(self: *Agent, reclaimed_tokens: u64) void {
    if (reclaimed_tokens == 0) return;
    self.rebaseContextMeter();
}

fn accountForReclaimedContext(self: *Agent, reclaimed: usize) void {
    accountForReclaimedTokens(self, @intCast(reclaimed / 4));
}

/// #163: reclaim context when it has overflowed and there is no clean user turn
/// to cut at (a runaway tool loop is all tool_call/tool_result after the last
/// user turn). Truncate the OLDEST tool outputs in place, keeping the most recent
/// `keep_recent` verbatim (opencode-style) and every call/output pair intact
/// (codex's trim_function_call_history). Never drops a message, so no orphaned
/// tool_result can reach the API. Returns bytes reclaimed.
pub fn trimOldestToolOutputsAlloc(self: *Agent, arena: Allocator) usize {
    const keep_recent: usize = 4;
    const stub_cap: usize = 400;
    var total: usize = 0;
    for (self.messages.items) |m| {
        if (isToolOutputMsg(m)) total += 1;
    }
    if (total <= keep_recent) return 0;
    var seen: usize = 0;
    var reclaimed: usize = 0;
    for (self.messages.items) |*m| {
        if (!isToolOutputMsg(m.*)) continue;
        seen += 1;
        if (seen > total - keep_recent) break; // keep the most recent verbatim
        reclaimed += truncateToolOutput(arena, m, stub_cap, .{ .fallback = "[old tool output truncated to recover context (#163)]" });
    }
    accountForReclaimedContext(self, reclaimed);
    return reclaimed;
}

pub fn trimOldestToolOutputs(self: *Agent) usize {
    return trimOldestToolOutputsAlloc(self, self.arena);
}

/// #193 follow-up: bound ANY single tool output to `cap` serialized bytes before
/// send, in place, across every wire format (responses `function_call_output`,
/// openai `role:"tool"`, anthropic `tool_result` blocks). normalizeResponsesHistory
/// already hard-caps the responses output at the Responses API limit, but
/// anthropic/openai tool results had no per-output bound: one uncapped result (a
/// runaway MCP tool, a big fetch on a small-window model) could alone push the
/// input past the window — and past what emergencyTrim can reclaim, since it keeps
/// the most-recent outputs verbatim. Cap is window-proportional (Provider.perOutputCap)
/// so large-context models keep full results untouched. Preserves every call/output
/// pairing (shrinks strings, never drops a message). Returns bytes reclaimed.
///
/// #440: a backstop now, not the first line of defense. runTools applies the
/// handle contract at tool time with a threshold clamped below `cap`, so a
/// freshly produced result is never oversized by the time it gets here; what
/// remains for this pass is history this process did not produce (a session
/// resumed from a pre-#440 build). See tool_handle.effectiveThreshold.
///
/// #409: the elided bytes are no longer destroyed. When this agent has a durable
/// session, each oversized output is written to that session's artifact dir
/// first and the marker cites the absolute path and the full byte count, so the
/// model can read or grep the slice it needs instead of re-running the tool. A
/// subagent (no persisted history) keeps the plain truncation below.
pub fn capOversizedToolOutputs(self: *Agent, cap: usize) usize {
    if (cap == 0) return 0;
    const note: tool_spill.Note = .{
        .fallback = "[tool output truncated: over this model's per-result cap — read/fetch a smaller range (#193)]",
        .session = tool_spill.sessionFor(self.sub, self.session_name),
    };
    var reclaimed: usize = 0;
    for (self.messages.items) |*m| {
        if (isToolOutputMsg(m.*))
            reclaimed += truncateToolOutput(self.messageMutationAlloc(), m, cap, note);
    }
    // These outputs are appended after the prior response's usage was recorded,
    // so reclaimed bytes were never part of that authoritative server reading.
    // Never subtract them from it; only raise the floor to the now-capped full
    // request estimate.
    if (reclaimed > 0) self.rebaseContextMeter();
    return reclaimed;
}

/// Re-exported recovery entry points (agent_compact_recover.zig owns them).
pub const emergencyTrim = @import("agent_compact_recover.zig").emergencyTrim;
pub const repeatedOpaqueCompactionFailure = @import("agent_compact_recover.zig").repeatedOpaqueCompactionFailure;
pub const repeatedEmptySummaryFailure = @import("agent_compact_recover.zig").repeatedEmptySummaryFailure;
pub const compactOrRecover = @import("agent_compact_recover.zig").compactOrRecover;
