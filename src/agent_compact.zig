//! Context management: transactional history compaction and emergency
//! recovery when a summary request cannot run.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const utf8Prefix = @import("util.zig").utf8Prefix;
const context_tokens = @import("context_tokens.zig");

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const prompts = @import("prompts.zig");
const compact_instruction = prompts.compact_instruction;
const goal_flow = @import("goal_flow.zig");

const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;

const title_mod = @import("title.zig");
const assistantText = title_mod.assistantText;

const agent_eval = @import("agent_eval.zig");
pub const runEval = agent_eval.runEval;
pub const appendEvalLog = agent_eval.appendEvalLog;
pub const runJudge = agent_eval.runJudge;

pub const recent_context_tokens: u64 = 8_000;

/// Head-cap for a child's pinned task prompt when restated in a handoff.
/// ~2k tokens; head-capped because a workflow child's prompt carries the
/// previous phase's results as a TAIL, so the head is the instruction.
pub const task_pin_cap: usize = 8_000;

/// Pick the earliest clean user-turn boundary whose suffix fits in the recent
/// context budget. Returning items.len means "summarize everything". We never
/// split at a tool output, so retained call/result history stays valid.
pub fn recentContextStart(items: []const Value, token_budget: u64) usize {
    if (items.len == 0 or token_budget == 0) return items.len;
    var total: u64 = 0;
    var start = items.len;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        total +|= context_tokens.estimatedTokens(items[i]);
        if (total > token_budget) break;
        if (cleanUserTurn(items[i])) start = i;
    }
    // If the entire conversation fits, summarizing all is the only operation
    // that can actually reduce context; otherwise compaction would be a no-op.
    return if (start == 0) items.len else start;
}

/// Ask the model for a context-handoff summary (no tools), then restart
/// history from that summary.
pub fn summaryResponseComplete(self: *Agent, root: std.json.ObjectMap) bool {
    if (root.get("incomplete")) |value| if (value == .bool and value.bool) return false;
    return switch (self.provider.kind) {
        .responses => true, // parseResponses marks incomplete/missing terminals above
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

pub fn compact(self: *Agent) anyerror!usize {
    if (self.messages.items.len == 0) {
        if (!main_mod.json_mode) try self.say("nothing to compact\n", .{});
        return 0;
    }
    pinChildTask(self);
    self.last_request_context_overflow = false;
    if (!main_mod.json_mode) try self.say("[compacting ~{d} tokens…]\n", .{self.effectiveContextTokens()});
    // #163: reclaim room BEFORE the summarization request so it fits under the
    // model's input cap. On codex/gpt-5.x an over-cap request fails to WRITE
    // (WriteFailed) rather than returning a clean overflow, so compaction could
    // never run once near the cap. Old tool outputs are superseded by the summary
    // anyway; truncating them keeps the request sendable + all pairing intact.
    // Build the summary request on a temporary deep copy of every JSON
    // container. Pruning reasoning and truncating tool output must be
    // transactional: if the summary call fails or returns empty, the live
    // conversation remains byte-for-byte usable for the next attempt.
    var compact_arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer compact_arena_state.deinit();
    const compact_arena = compact_arena_state.allocator();
    const live_messages = self.messages;
    const live_context_tokens = self.last_context_tokens;
    const live_context_local_tokens = self.context_local_tokens;
    const live_effective_context = self.effectiveContextTokens();
    const recent_start = recentContextStart(live_messages.items, recent_context_tokens);
    const recent_messages = live_messages.items[recent_start..];
    var summary_messages = std.json.Array.init(compact_arena);
    try summary_messages.ensureTotalCapacity(recent_start);
    for (live_messages.items[0..recent_start]) |item|
        try summary_messages.append(try cloneJsonValue(compact_arena, item));
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

    try self.messages.append(try textMessage(compact_arena, "user", compact_instruction));
    // #174: establish the synthetic summary turn before pruning Responses
    // reasoning. An active tool loop's reasoning is newer than the real user
    // turn and must remain while that loop is in flight, but it becomes prior-
    // turn context once this synthetic user request is appended. Pruning first
    // left precisely that large encrypted blob in the full summary resend.
    _ = dropPriorTurnReasoning(self);
    _ = trimOldestToolOutputsAlloc(self, compact_arena);

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
    const root = try self.request(null);
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
    try fresh.append(try textMessage(self.arena, "user", try handoffMessage(self, summary)));
    // Preserve a valid recent suffix verbatim (up to ~8k estimated tokens),
    // including its user boundary and paired tool calls/results.
    for (recent_messages) |message| try fresh.append(message);
    self.messages = fresh;
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.goal_note_fp = 0; // the injected goal note died with the old history - re-state in full (#318)
    self.history_rewrites +%= 1; // readers of pasted state (the /loop checklist gate) re-carry it (#318)
    installed_summary = true;
    if (!main_mod.json_mode) try self.say("[history compacted to a {d}-char summary]\n", .{summary.len});
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
pub fn handoffMessage(self: *Agent, summary: []const u8) ![]const u8 {
    const base = if (self.sub)
        (if (self.task_prompt) |tp| try childHandoff(self, tp, summary) else try rootHandoff(self, summary))
    else
        try rootHandoff(self, summary);
    const standing = (try goal_flow.compactionSnapshot(self.arena, self)) orelse return base;
    return std.fmt.allocPrint(self.arena, "{s}\n\n{s}", .{ base, standing });
}

fn rootHandoff(self: *Agent, summary: []const u8) ![]const u8 {
    return std.fmt.allocPrint(self.arena,
        \\Context: the earlier conversation was compacted to save space.
        \\Summary of the earlier work:
        \\
        \\{s}
        \\
        \\Continue assisting the user based on this summary.
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
        \\Continue the assigned task above using this summary of the work already done, and report back as the task requires.
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

pub fn cleanUserTurn(m: Value) bool {
    if (m != .object) return false;
    const role = m.object.get("role") orelse return false;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
    const content = m.object.get("content") orelse return true;
    switch (content) {
        .string => return true, // a plain-text user turn
        .array => |arr| {
            // An anthropic user message that only carries tool_result blocks
            // is the response half of a tool call — it can't begin a
            // conversation, so it is not a safe trim boundary.
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const t = blk.object.get("type") orelse continue;
                if (t == .string and std.mem.eql(u8, t.string, "tool_result")) return false;
            }
            return true;
        },
        else => return true,
    }
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
        if (role == .string and std.mem.eql(u8, role.string, "user")) last_user = i;
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

/// Index to cut history at for an emergency trim: the first clean user turn
/// at or after the midpoint, so messages[cut..] is always a valid
/// conversation start (never an orphaned tool_result). null when there is no
/// safe cut — too short, or only tool_result user messages remain.
pub fn emergencyCutIndex(items: []const Value) ?usize {
    if (items.len < 4) return null;
    var i: usize = items.len / 2;
    while (i < items.len) : (i += 1) {
        if (cleanUserTurn(items[i])) return i;
    }
    return null;
}

/// True if `m` is a tool-output message whose payload can be truncated to
/// reclaim context: responses `function_call_output`, openai `role:"tool"`, or an
/// anthropic user message carrying `tool_result` blocks (#163).
fn isToolOutputMsg(m: Value) bool {
    if (m != .object) return false;
    if (m.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "function_call_output")) return true;
    if (m.object.get("role")) |r| if (r == .string) {
        if (std.mem.eql(u8, r.string, "tool")) return true;
        if (std.mem.eql(u8, r.string, "user")) if (m.object.get("content")) |c| if (c == .array)
            for (c.array.items) |blk| {
                if (blk == .object) if (blk.object.get("type")) |bt|
                    if (bt == .string and std.mem.eql(u8, bt.string, "tool_result")) return true;
            };
    };
    return false;
}

fn truncateStrField(arena: Allocator, o: *std.json.ObjectMap, key: []const u8, cap: usize, note: []const u8) usize {
    const v = o.get(key) orelse return 0;
    if (v != .string or v.string.len <= cap) return 0;
    const orig = v.string.len;
    // Keep the prefix short enough that prefix + '\n' + note <= cap, so the marker
    // never grows an output that was only barely over the cap.
    const stub = std.fmt.allocPrint(arena, "{s}\n{s}", .{ utf8Prefix(v.string, cap -| (note.len + 1)), note }) catch return 0;
    o.put(arena, key, .{ .string = stub }) catch return 0;
    return orig -| stub.len;
}

/// Truncate an over-large tool-output payload in `m` in place to ~`cap` bytes,
/// preserving the message and its call/output pairing. Returns bytes reclaimed.
fn truncateToolOutput(arena: Allocator, m: *Value, cap: usize, note: []const u8) usize {
    if (m.* != .object) return 0;
    if (m.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "function_call_output"))
        return truncateStrField(arena, &m.object, "output", cap, note);
    if (m.object.get("role")) |r| if (r == .string) {
        if (std.mem.eql(u8, r.string, "tool")) return truncateStrField(arena, &m.object, "content", cap, note);
        if (std.mem.eql(u8, r.string, "user")) if (m.object.get("content")) |c| if (c == .array) {
            var saved: usize = 0;
            for (m.object.get("content").?.array.items) |*blk| {
                if (blk.* != .object) continue;
                const bt = blk.object.get("type") orelse continue;
                if (bt == .string and std.mem.eql(u8, bt.string, "tool_result"))
                    saved += truncateStrField(arena, &blk.object, "content", cap, note);
            }
            return saved;
        };
    };
    return 0;
}

/// Re-pair the meter after removing locally measurable context. The server-only
/// delta remains intact, while the current local component reflects the trim.
fn accountForReclaimedTokens(self: *Agent, reclaimed_tokens: u64) void {
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
        reclaimed += truncateToolOutput(arena, m, stub_cap, "[old tool output truncated to recover context (#163)]");
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
pub fn capOversizedToolOutputs(self: *Agent, cap: usize) usize {
    if (cap == 0) return 0;
    var reclaimed: usize = 0;
    for (self.messages.items) |*m| {
        if (isToolOutputMsg(m.*))
            reclaimed += truncateToolOutput(self.messageMutationAlloc(), m, cap, "[tool output truncated: over this model's per-result cap — read/fetch a smaller range (#193)]");
    }
    // These outputs are appended after the prior response's usage was recorded,
    // so reclaimed bytes were never part of that authoritative server reading.
    // Never subtract them from it; only raise the floor to the now-capped full
    // request estimate.
    if (reclaimed > 0) self.rebaseContextMeter();
    return reclaimed;
}

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
        self.history_rewrites +%= 1; // and the /loop checklist gate's pasted copies (#318)
        // No synthetic message exists here to hang the standing state on (unlike
        // compact()'s handoff), so it rides the next turn's one-shot slot. Only
        // when that slot is free: a queued /goal replace|clear note is the USER's
        // instruction and outranks the harness restating itself (#318).
        if (self.pending_goal_note == null)
            self.pending_goal_note = goal_flow.compactionSnapshot(self.arena, self) catch null;
        const after_tokens = self.fullInputEstimateTokens();
        accountForReclaimedTokens(self, before_tokens -| after_tokens);
        return cut;
    }
    // #163: no clean user turn to cut at (a runaway tool loop). Don't wedge the
    // session — reclaim context by truncating the oldest tool outputs in place,
    // keeping every call/output pair valid. Nonzero = recovered. This too is a
    // rewrite: the stubbed outputs may include the last todo_write render the
    // suppressed /loop note points the model at (#318).
    if (trimOldestToolOutputs(self) > 0) {
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

pub fn compactOrRecover(self: *Agent, trim_on_fail: bool) void {
    if (self.compact()) |_| {
        self.compact_transport_failures = 0;
        return;
    } else |err| {
        switch (err) {
            error.Interrupted => {
                self.compact_transport_failures = 0;
                return; // user hit Esc mid-compaction
            },
            error.EmptySummary, error.IncompleteSummary => {}, // compact() already explained it
            else => {
                if (main_mod.json_mode)
                    self.emit(.{ .type = "error", .message = std.fmt.allocPrint(self.arena, "auto-compaction failed: {s}", .{@errorName(err)}) catch "auto-compaction failed" })
                else
                    self.say("[auto-compaction failed: {t}]\n", .{err}) catch {};
            },
        }
        const repeated_opaque_overflow = repeatedOpaqueCompactionFailure(self, err);
        // The caller's policy is computed before compact() makes its summary
        // request. Override it only for a concrete provider overflow rejection,
        // or after two consecutive WriteFailed compaction attempts when the
        // effective meter is near 95% (or local bytes prove over-window). The
        // first failure and ordinary transport outages always preserve history.
        if (!trim_on_fail and !self.last_request_context_overflow and !repeated_opaque_overflow) return;
        const dropped = self.emergencyTrim();
        if (dropped > 0) {
            self.compact_transport_failures = 0;
            if (main_mod.json_mode)
                self.emit(.{ .type = "compact", .ok = true, .trimmed = dropped })
            else
                self.say("[context emergency-trimmed: dropped {d} old message(s) so the session can continue]\n", .{dropped}) catch {};
        } else if (!main_mod.json_mode) {
            self.say("[warning: context too large to compact and could not be trimmed safely]\n", .{}) catch {};
        }
    }
}
