//! Tool-call dispatch: the batch runner (runTools) that rejects/dedupes/
//! gates each call then runs external ones (serial if any write/edit/shell),
//! the human-approval gate for bash/write_file/edit_file/MCP calls
//! (gateTool), meta-tool handling (attempt_completion/eval/todo_write/
//! todo_read/ask_user, on the agent's own thread — handleMeta/askUser),
//! and the tool-call/tool-result UX lines (sayToolUse/sayToolResult).
//! Split out of the Agent struct (#123, 600-line goal).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const review = @import("review.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const shared_tree_batch = @import("shared_tree_batch.zig");
const ExecResult = tools_mod.ExecResult;

// #422 slice 1c: every emission here leaves as a typed event; the terminal
// palette lives in agent_tool_render.zig, behind the sink. `term.zig` stays
// because raw/nonblocking stdin for the Esc watcher below is frontend INPUT,
// which belongs to the input-inversion issue (#430), not to this one.
const engine_events = @import("engine_events.zig");
const engine_sink = @import("engine_sink.zig");

const schema = @import("schema.zig");
const isMetaName = schema.isMetaName;
const eval_control = @import("agent_eval_control.zig");
const goal_state = @import("goal_state.zig");
const goal_verify = @import("goal_verify.zig");
const task_outcome = @import("task_outcome.zig");
const goal_todo = @import("goal_todo.zig"); // todo_write's replace path + the omitted-completed preserve rule
const peer_channel = @import("peer_channel.zig");
const workspace_switch = @import("workspace_switch.zig");
const tool_call_args = @import("tool_call_args.zig");
pub const toolInvalidatesEval = eval_control.toolInvalidatesEval;
pub const gateTool = @import("agent_tool_gate.zig").gateTool;
pub const firstWord = @import("agent_tool_gate.zig").firstWord;

const tools_mod = @import("tools.zig");

const brief_diversity = @import("brief_diversity.zig"); // #382: N sibling spawns in one batch are a fleet
const playbook_glue = @import("playbook_glue.zig"); // #381: the note_constraint meta arm
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // #416: the load_tool_schemas meta arm
const native_fold = @import("native_fold.zig"); // folded native power tools: load_tool_schemas's native half
const local_tools = @import("local_tools.zig");
const schedule = @import("schedule.zig");
const jev_tool = @import("jev_tool.zig");
const util = @import("util.zig"); // #225: unixMs, for the clock_sleep interrupted-elapsed measurement

const cite_markup = @import("cite_markup.zig");
const read_miss = @import("read_miss.zig");

/// Run a batch of tool calls. Meta tools are handled inline (they mutate
/// agent state); mutating file/shell calls run one at a time, otherwise
/// external calls fan out across the Io thread pool. Results are returned
/// in call order, arena-owned.
pub fn runTools(self: *Agent, calls: []const ToolCall) ![]ExecResult {
    defer @import("agent_async_tools.zig").reset(self);
    defer if (self.approvals) |ap| ap.clearPlanReadOnce(self.io, self);
    if (!self.sub and calls.len >= 4) {
        var names: [32][]const u8 = undefined;
        const n = @min(calls.len, names.len);
        for (calls[0..n], 0..) |c, i| names[i] = c.name;
        if (native_fold.noticeWideNative(names[0..n])) {
            // Same contract as load_tool_schemas / noticeContext: wipe then
            // rebuild. Invalidate-only leaves toolsJson empty and the next
            // body is `"tools":,` (stall-warn's 1-call 400).
            self.invalidateRootTools();
            try self.ensureRootTools(self.provider.kind);
        }
    }
    const results = try self.historyAlloc().alloc(ExecResult, calls.len);
    if (try @import("turn_handoff.zig").rejectMixedBatch(self, calls, results)) return results;
    if (try @import("orchestrator_mode.zig").rejectMixedBatch(self, calls, results)) return results;
    const eval_index = eval_control.evalCallIndex(calls);
    // ADR 0256: only a batch that completes needs the model family.
    const writes_complete = eval_control.completionIndex(calls) != null and @import("gemini_turns.zig").family(self.provider.model);
    const blocks_completion = eval_control.batchBlocksCompletionFor(calls, writes_complete);
    const defer_completion = eval_control.shouldDeferCompletionFor(calls, writes_complete);

    // Collect the indices of external (non-meta) calls for parallel exec.
    var ext_idx: std.ArrayList(usize) = .empty;
    defer ext_idx.deinit(self.gpa);
    var hold_idx: std.ArrayList(usize) = .empty;
    defer hold_idx.deinit(self.gpa);
    var read_paths: std.ArrayList([]const u8) = .empty;
    defer read_paths.deinit(self.gpa);
    for (calls) |call| {
        if (std.mem.eql(u8, call.name, "read_file")) {
            if (read_miss.callPath(call.input)) |p| try read_paths.append(self.gpa, p);
        }
    }
    var miss_batch = read_miss.Batch.init(read_paths.items);
    var checkpointed = false; // #1553: one shared-tree checkpoint holds every sibling mutation
    for (calls, 0..) |call, i| {
        if (try @import("agent_async_tools.zig").claim(self, call)) |result| {
            results[i] = result;
            continue;
        }
        if (eval_index) |verifier| if (i != verifier) {
            self.emitToolRejected(call, "verifier_boundary", eval_control.verifier_boundary);
            results[i] = .{ .text = eval_control.verifier_boundary, .is_error = true };
            continue;
        };
        if (std.mem.eql(u8, call.name, "attempt_completion") and blocks_completion) {
            self.emitToolRejected(call, "eval_stale", eval_control.completion_with_mutation);
            results[i] = .{ .text = eval_control.completion_with_mutation, .is_error = true };
            continue;
        }
        if (std.mem.eql(u8, call.name, "attempt_completion") and defer_completion) {
            continue;
        }
        if (try self.rejectToolCall(call)) |denied| {
            results[i] = denied;
            continue;
        }
        try self.sayToolUse(call);
        if (self.output_schema != null and std.mem.eql(u8, call.name, "structured_output")) {
            results[i] = @import("agent_request_body_responses.zig").handleStructuredOutput(self, call.input); // #543 tool-mode capture
        } else if (isMetaName(call.name) or local_tools.isInstall(call.name) or schedule.isName(call.name)) {
            results[i] = try self.handleMeta(call);
        } else if (try self.gateTool(call)) |denied| {
            results[i] = denied;
            checkpointed = checkpointed or shared_tree_batch.isCheckpoint(denied);
        } else switch (classifyRead(self, &miss_batch, call)) {
            .refuse => results[i] = try refuseRead(self, call),
            .hold => try hold_idx.append(self.gpa, i),
            .run => try ext_idx.append(self.gpa, i),
        }
    }

    if (checkpointed) shared_tree_batch.hold(self.gpa, self.io, self.arena, calls, results, &ext_idx);
    if (ext_idx.items.len > 0) {
        try @import("agent_tool_batch.zig").runExternal(self, calls, ext_idx.items, results);
        brief_diversity.noteSiblingBatch(self.arena, self.tracer, calls, ext_idx.items, results); // #382
    }
    if (hold_idx.items.len > 0) {
        var wave2: std.ArrayList(usize) = .empty;
        defer wave2.deinit(self.gpa);
        for (hold_idx.items) |i| {
            const path = read_miss.callPath(calls[i].input) orelse {
                try wave2.append(self.gpa, i);
                continue;
            };
            if (self.read_miss.shouldRefuse(path)) {
                results[i] = try refuseRead(self, calls[i]);
                continue;
            }
            try wave2.append(self.gpa, i);
        }
        if (wave2.items.len > 0) {
            try @import("agent_tool_batch.zig").runExternal(self, calls, wave2.items, results);
            brief_diversity.noteSiblingBatch(self.arena, self.tracer, calls, wave2.items, results);
        }
    }
    if (!self.sub and jev_tool.takeCatalogRefresh()) {
        self.invalidateRootTools();
        try self.ensureRootTools(self.provider.kind);
    }
    if (defer_completion) if (eval_control.completionIndex(calls)) |i| {
        var verify_failed = ext_idx.items.len == 0;
        for (ext_idx.items) |j| {
            if (results[j].is_error or results[j].cancelled or results[j].pending) verify_failed = true;
        }
        if (verify_failed) {
            self.emitToolRejected(calls[i], "eval_stale", eval_control.completion_verify_failed);
            results[i] = .{ .text = eval_control.completion_verify_failed, .is_error = true };
        } else if (try self.rejectToolCall(calls[i])) |denied| {
            results[i] = denied;
        } else {
            try self.sayToolUse(calls[i]);
            results[i] = try self.handleMeta(calls[i]);
        }
    };
    // Show a compact ✓/✗ + preview for each non-meta call (no-op for subs).
    for (calls, results) |call, r| self.sayToolResult(call, r);
    try @import("tool_repeat.zig").observe(self, calls, results); // #1706, after display: the notice is for the model
    return results;
}

fn classifyRead(self: *Agent, batch: *read_miss.Batch, call: ToolCall) read_miss.Wave {
    if (!std.mem.eql(u8, call.name, "read_file")) return .run;
    const path = read_miss.callPath(call.input) orelse return .run;
    return batch.classify(&self.read_miss, path);
}

fn refuseRead(self: *Agent, call: ToolCall) !ExecResult {
    const path = read_miss.callPath(call.input) orelse ".";
    const message = try read_miss.refusalText(self.historyAlloc(), path);
    self.emitToolRejected(call, "read_miss", message);
    return .{ .text = message, .is_error = true };
}

pub fn rejectToolCall(self: *Agent, call: ToolCall) !?ExecResult {
    if (@import("hard_policy_gate.zig").denialAgent(self, self.historyAlloc(), call)) |denied| {
        self.emitToolRejected(call, "hard_policy", denied);
        return .{ .text = denied, .is_error = true };
    }
    if (self.sub and self.synthesis.reporting()) {
        const message = @import("workflow_synthesis.zig").tool_refusal;
        self.emitToolRejected(call, "workflow_synthesis", message);
        return .{ .text = message, .is_error = true };
    }
    if (!call.args_ok) {
        const message = if (call.cut) tool_call_args.cut_exec_message else tool_call_args.invalid_exec_message;
        self.emitToolRejected(call, "invalid_arguments", message);
        return .{ .text = message, .is_error = true };
    }
    if (std.mem.eql(u8, call.name, "read_file")) {
        if (read_miss.callPath(call.input)) |path| {
            if (self.read_miss.shouldRefuse(path)) return try refuseRead(self, call);
        }
    }
    if (!self.sub and std.mem.eql(u8, call.name, "yield_turn")) return null;
    const msg_alloc = self.historyAlloc();
    if (isMetaName(call.name) or local_tools.isInstall(call.name) or schedule.isName(call.name) or std.mem.eql(u8, call.name, "structured_output")) {
        if (self.run_budget) |budget| if (budget.toolRefusal(msg_alloc, self.tracer)) |denied| {
            self.emitToolRejected(call, "exhausted", denied.text);
            return .{ .text = denied.text, .is_error = true };
        };
    }
    if (self.sub) return null;
    if (self.review_mode) if (try review.rejectTool(msg_alloc, call)) |denied| {
        self.emitToolRejected(call, "review_mode", denied.text);
        return denied;
    };
    if (std.mem.eql(u8, call.name, "attempt_completion")) return null;
    if (main_mod.max_tool_calls) |max| {
        if (self.tool_calls_this_turn >= max) {
            const message = try std.fmt.allocPrint(msg_alloc, "tool call budget exhausted ({d}/{d}) — answer with what you have or ask for a higher --max-tool-calls", .{ self.tool_calls_this_turn, max });
            self.emitToolRejected(call, "budget", message);
            return .{ .text = message, .is_error = true };
        }
    }
    if (main_mod.dedupe_tool_calls) {
        const key = try self.toolDedupeKey(call);
        for (self.seen_tool_keys.items) |seen| {
            if (std.mem.eql(u8, seen, key)) {
                const message = try std.fmt.allocPrint(msg_alloc, "duplicate tool call rejected: {s} with the same normalized input already ran this turn", .{call.name});
                self.emitToolRejected(call, "duplicate", message);
                return .{ .text = message, .is_error = true };
            }
        }
        try self.seen_tool_keys.append(self.arena, key);
    }
    self.tool_calls_this_turn += 1;
    return null;
}

pub fn toolDedupeKey(self: *Agent, call: ToolCall) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(self.arena);
    const w = &aw.writer;
    try w.writeAll(call.name);
    try w.writeByte('\n');
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(call.input);
    const key = aw.writer.buffered();
    for (key) |*c| {
        c.* = if (std.ascii.isWhitespace(c.*)) ' ' else std.ascii.toLower(c.*);
    }
    return key;
}

/// A refusal that happened before the tool ran. The terminal has never drawn
/// one (the user learns of it through the model's next answer), so only a
/// wire sink gives this moment a shape.
pub fn emitToolRejected(self: *Agent, call: ToolCall, reason: []const u8, message: []const u8) void {
    engine_sink.forAgent(self).emit(self.io, .{ .tool_rejected = .{
        .id = call.id,
        .name = call.name,
        .input = call.input,
        .reason = reason,
        .message = message,
    } });
}

/// #225: clock_sleep meta tool — root-only, feature-flagged (main.zig
/// g_clock_sleep / --clock-sleep / GRAFF_CLOCK_SLEEP=1). Mirrors codex's
/// clock.sleep: capped at 12h, cancelled by user input like any other
/// backoff (sleepInterruptible), and an interruption is reported as a
/// normal (non-error) outcome, not a tool failure.
pub const clock_sleep_max_ms: i64 = 43_200_000; // 12h, mirrors codex MAX_SLEEP_DURATION_MS

const ClockSleepMs = struct { ms: i64, clamped: bool };

/// Pure `ms`-field validation/clamping, split out of the handleMeta arm so
/// the reject/clamp paths are unit-testable without a live Agent/Io.
/// `input` must be `{"ms": <non-negative integer>}` — anything else
/// (missing, negative, non-integer, wrong shape) is a normal rejection,
/// never a crash. A value over the 12h cap clamps instead of rejecting.
pub fn parseClockSleepMs(input: Value) error{InvalidMs}!ClockSleepMs {
    if (input != .object) return error.InvalidMs;
    const raw = input.object.get("ms") orelse return error.InvalidMs;
    if (raw != .integer or raw.integer < 0) return error.InvalidMs;
    if (raw.integer > clock_sleep_max_ms) return .{ .ms = clock_sleep_max_ms, .clamped = true };
    return .{ .ms = raw.integer, .clamped = false };
}

pub fn clockSleepSuccessText(arena: std.mem.Allocator, ms: i64, clamped: bool) ![]const u8 {
    if (clamped) return std.fmt.allocPrint(arena, "clock_sleep: requested ms exceeded the 12h cap, clamped to {d} ms; slept {d} ms", .{ clock_sleep_max_ms, ms });
    return std.fmt.allocPrint(arena, "slept {d} ms", .{ms});
}

pub fn clockSleepInterruptedText(arena: std.mem.Allocator, elapsed_ms: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "sleep interrupted after {d} ms by user input", .{elapsed_ms});
}

/// Handle a meta tool inline on the agent's own thread.
pub fn handleMeta(self: *Agent, call: ToolCall) !ExecResult {
    // Folded natives, meta path: inline dispatch never reaches exec.zig's
    // guard chain, so auto-load lives here too — same rule as gateExec.
    if (!self.sub) native_fold.markIfFolded(call.name);
    // #469: sideways coordination between co-resident root sessions.
    if (std.mem.eql(u8, call.name, peer_channel.tool_name)) return peer_channel.handleMessage(self, call);
    if (std.mem.eql(u8, call.name, workspace_switch.tool_name)) return workspace_switch.handle(self, call);
    if (local_tools.isInstall(call.name)) {
        if (main_mod.plan_mode) return .{ .text = "plan mode is on — install_agent_tool writes .graff/tools; switch to act first.", .is_error = true };
        return local_tools.handleInstall(self, call);
    }
    if (schedule.isName(call.name)) {
        if (main_mod.plan_mode) return .{ .text = "plan mode is on — schedule_task writes .graff/schedule; switch to act first.", .is_error = true };
        return schedule.handleTool(self, call);
    }
    if (std.mem.eql(u8, call.name, "yield_turn")) return @import("turn_handoff.zig").handle(self, call);
    if (@import("orchestrator_mode.zig").isMetaTool(call.name)) return @import("orchestrator_mode.zig").handleMeta(self, call);
    if (std.mem.eql(u8, call.name, "attempt_completion")) {
        if (!self.review_mode and self.eval_cmd != null and (!self.eval_verified or self.eval_repair_pending)) {
            const message = if (self.eval_repair_pending)
                "completion blocked: the latest verifier contradicted the plan; repair the failure and run eval until it meets the target"
            else
                "completion blocked: workspace state is not verified; run eval and meet the target after the final change";
            self.completion_refused = true; // blocked, not silence: attempt_completion skips the tool counter, and the run must give the model a turn to run eval (#318)
            return .{ .text = message, .is_error = true };
        }
        if (try goal_verify.completionGate(self.arena, self)) |refusal| {
            goal_state.noteCompletionRefused(self); // arm the double-check (across turns) and mark the turn as worked (#318)
            if (!self.sub) engine_sink.forAgent(self).emit(self.io, .completion_deferred); // root-only notice, as ever
            return .{ .text = refusal, .is_error = true };
        }
        const raw = if (tools_mod.json_args.object(call.input)) |o| (tools_mod.json_args.str(o, "result") orelse "") else "";
        const cleaned = try cite_markup.dupe(self.arena, raw);
        const result = cleaned;
        self.completed = result;
        if (!self.sub) @import("peer_idle.zig").noteCompletion();
        if (!self.sub) task_outcome.noteGoalCompleted(self);
        // .complete retires the epoch (goal_state.currentEpoch) and the checklist parks - readable, no longer current, never deleted (#318).
        // A --goal standing objective is exempt: the completion is recorded above, the steering stays, and only /goal clear|pause|<new> retires it.
        if (goal_state.retireOnCompletion(self, util.unixMs(self.io))) {
            if (self.tracer) |t| t.note("goal", "completed via attempt_completion");
            engine_sink.forAgent(self).emit(self.io, .goal_completed);
        } else if (goal_state.goalActive(self)) {
            if (self.tracer) |t| t.note("goal", "completion; standing goal retained");
        }
        // Skip the re-print only when the result streamed live in full.
        if (!self.sub and !self.argStreamedFully(call)) engine_sink.forAgent(self).emit(self.io, .{ .completion_text = .{ .text = result } });
        return .{ .text = "completion recorded", .is_error = false };
    }
    if (std.mem.eql(u8, call.name, "eval")) {
        const note = if (tools_mod.json_args.object(call.input)) |o| (tools_mod.json_args.str(o, "note") orelse "") else "";
        return self.runEval(note);
    }
    if (std.mem.eql(u8, call.name, "todo_write")) {
        // Epoch-scoped replace, keeping omitted completed items; a write with
        // no usable items is rejected untouched (#318). goal_todo owns the rule.
        const r = try goal_todo.applyTodoWrite(self, if (tools_mod.json_args.object(call.input)) |o| o.get("todos") else null);
        if (!self.sub and !r.rejected) engine_sink.forAgent(self).emit(self.io, .{ .todo_list_updated = .{ .text = r.text } });
        return .{ .text = r.reply(), .is_error = r.rejected }; // ADR 0233: the UI got the full list above
    }
    if (std.mem.eql(u8, call.name, "clock_sleep")) {
        const parsed = parseClockSleepMs(call.input) catch return .{
            .text = "clock_sleep: ms must be a non-negative integer",
            .is_error = true,
        };
        if (parsed.ms == 0) {
            // Nothing to wait out — skip the sleep call (and the Io clock
            // reads below) entirely rather than round-tripping a zero-length
            // sleep through sleepInterruptible.
            return .{ .text = try clockSleepSuccessText(self.arena, 0, parsed.clamped), .is_error = false };
        }
        const start_ms = util.unixMs(self.io);
        self.sleepInterruptible(@intCast(parsed.ms)) catch |err| switch (err) {
            error.Interrupted => {
                const elapsed_ms = util.unixMs(self.io) - start_ms;
                return .{ .text = try clockSleepInterruptedText(self.arena, elapsed_ms), .is_error = false };
            },
        };
        return .{ .text = try clockSleepSuccessText(self.arena, parsed.ms, parsed.clamped), .is_error = false };
    }
    if (std.mem.eql(u8, call.name, "note_constraint")) return playbook_glue.noteConstraint(self, call.input); // #381: append-only, and it re-composes the root's own prompt
    if (std.mem.eql(u8, call.name, mcp_schema_gate.tool_name) or @import("mcp_select.zig").isName(call.name)) return @import("mcp_select.zig").loadBoth(self, call);
    if (std.mem.eql(u8, call.name, "ask_user")) return self.askUser(call);
    // todo_read
    return .{ .text = self.renderTodos(goal_state.currentEpoch(self.goal)), .is_error = false };
}

/// The call's announcement moment, as one pair of events: the bracket a
/// --json supervisor times against, and the ⚙ line the terminal draws for the
/// first of the two. Which of them a frontend surfaces (the wire skips
/// ask_user, the terminal skips prose that already streamed) is the sink's
/// call — engine_events.durable() decides the wire half, and jsonSink is
/// non-durable for an agent with no writer, so no sequence id is ever
/// reserved for a line the wire drops (#330).
pub fn sayToolUse(self: *Agent, call: ToolCall) !void {
    const ev: engine_events.ToolInvocation = .{
        .id = call.id,
        .name = call.name,
        .input = call.input,
        .ask_user = std.mem.eql(u8, call.name, "ask_user"),
        .arg_streamed = self.argStreamedFully(call),
    };
    const sink = engine_sink.forAgent(self);
    sink.emit(self.io, .{ .tool_call_announced = ev });
    sink.emit(self.io, .{ .tool_call_started = ev });
}

/// The same bracket, closing: the result a frontend shows and the finish
/// event carrying its outcome and duration. Meta tools own their text UX;
/// the wire still emits their correlated completion status so clients can
/// close the announced row without duplicating the result body.
pub fn sayToolResult(self: *Agent, call: ToolCall, r: ExecResult) void {
    @import("agent_async_tools.zig").presented(self, call);
    const name = call.name;
    if (self.out == null and self.sink == null) return;
    const ev: engine_events.ToolOutcome = .{
        .id = call.id,
        .name = name,
        .text = r.text,
        .is_error = r.is_error,
        .cancelled = r.cancelled,
        .ms = r.ms,
        .meta = isMetaName(name),
        .ask_user = std.mem.eql(u8, name, "ask_user"),
        .run_task = r.run_task,
    };
    const sink = engine_sink.forAgent(self);
    sink.emit(self.io, .{ .tool_result = ev });
    sink.emit(self.io, .{ .tool_call_finished = ev });
}

test {
    _ = @import("agent_tool_batch.zig");
    _ = @import("shared_tree_batch.zig");
}
