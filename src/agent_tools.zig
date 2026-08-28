//! Tool-call dispatch: the batch runner (runTools) that rejects/dedupes/
//! gates each call then fans external ones out across the Io thread pool,
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
const ExecResult = tools_mod.ExecResult;

// #422 slice 1c: every emission here leaves as a typed event; the terminal
// palette lives in agent_tool_render.zig, behind the sink. `term.zig` stays
// because raw/nonblocking stdin for the Esc watcher below is frontend INPUT,
// which belongs to the input-inversion issue (#430), not to this one.
const engine_events = @import("engine_events.zig");
const engine_sink = @import("engine_sink.zig");
const terminal = @import("term.zig");
const tty = terminal.tty;

const schema = @import("schema.zig");
const isMetaName = schema.isMetaName;
const eval_control = @import("agent_eval_control.zig");
const goal_state = @import("goal_state.zig");
const task_outcome = @import("task_outcome.zig");
const goal_todo = @import("goal_todo.zig"); // todo_write's replace path + the omitted-completed preserve rule
const peer_channel = @import("peer_channel.zig");
const workspace_switch = @import("workspace_switch.zig");
pub const toolInvalidatesEval = eval_control.toolInvalidatesEval;
pub const gateTool = @import("agent_tool_gate.zig").gateTool;
pub const firstWord = @import("agent_tool_gate.zig").firstWord;

const tools_mod = @import("tools.zig");
const ToolCtx = tools_mod.ToolCtx;
const ToolOutput = tools_mod.ToolOutput;

const exec = @import("exec.zig");
const execTool = exec.execTool;

const brief_diversity = @import("brief_diversity.zig"); // #382: N sibling spawns in one batch are a fleet
const playbook_glue = @import("playbook_glue.zig"); // #381: the note_constraint meta arm
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // #416: the load_tool_schemas meta arm
const native_fold = @import("native_fold.zig"); // folded native power tools: load_tool_schemas's native half
const util = @import("util.zig"); // #225: unixMs, for the clock_sleep interrupted-elapsed measurement

// #440: the ONE size contract for a tool result — preview + durable handle +
// byte count + shape hint, applied at tool time, clamped under the send-time cap.
const tool_handle = @import("tool_handle.zig");

// escWatchTask/drainStdin/rawNonblockStdin live in agent_interrupt.zig;
// esc_cancel/esc_watch_done STAY declared on the Agent struct (never alias
// a var — see agent_interrupt.zig's own header). Reached via Agent's namespace.
const escWatchTask = Agent.escWatchTask;
const drainStdin = Agent.drainStdin;
const rawNonblockStdin = Agent.rawNonblockStdin;

/// Run a batch of tool calls. Meta tools are handled inline (they mutate
/// agent state); everything else fans out across the Io thread pool.
/// Bash calls must clear the permission gate before dispatch. Results
/// are returned in call order, arena-owned.
pub fn runTools(self: *Agent, calls: []const ToolCall) ![]ExecResult {
    if (!self.sub and calls.len >= 4) {
        var names: [32][]const u8 = undefined;
        const n = @min(calls.len, names.len);
        for (calls[0..n], 0..) |c, i| names[i] = c.name;
        // ADR 0030: ≥4 native reads/bash showcases rlm. Must rebuild the
        // cached catalog here — invalidate-only shipped `"tools":,` on the
        // next request (rlm rematch 2026-08-28). See noticeWideNativeAndRefresh.
        _ = native_fold.noticeWideNativeAndRefresh(self, names[0..n]);
    }
    const results = try self.arena.alloc(ExecResult, calls.len);
    const eval_index = eval_control.evalCallIndex(calls);
    const blocks_completion = eval_control.batchBlocksCompletion(calls);
    const defer_completion = eval_control.shouldDeferCompletion(calls);

    // Collect the indices of external (non-meta) calls for parallel exec.
    var ext_idx: std.ArrayList(usize) = .empty;
    defer ext_idx.deinit(self.gpa);
    for (calls, 0..) |call, i| {
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
        } else if (isMetaName(call.name)) {
            results[i] = try self.handleMeta(call);
        } else if (try self.gateTool(call)) |denied| {
            results[i] = denied;
        } else {
            try ext_idx.append(self.gpa, i);
        }
    }

    if (ext_idx.items.len > 0) {
        // A child's fan-out is the root's to announce, so the moment is not
        // produced at all for a subagent: engine policy about who owns the
        // terminal, kept at the emit site rather than re-derived by a sink
        // that would need to back-read the Agent to know (#422 slice-1 rule).
        if (ext_idx.items.len > 1 and !self.sub) {
            engine_sink.forAgent(self).emit(self.io, .{ .parallel_batch_started = .{ .count = ext_idx.items.len } });
        }
        const ctx: ToolCtx = .{
            .gpa = self.gpa,
            .io = self.io,
            .client = self.client,
            .provider = self.provider,
            .subagent_provider = self.subagent_provider,
            .subagent_cross_provider = self.subagent_cross_provider,
            .registry = self.registry, // workers get licensed codedb-pro reads too (#627)
            .from_sub = self.sub,
            .has_eval = self.eval_cmd != null,
            .approvals = self.approvals,
            .tracer = self.tracer,
            .run_budget = self.run_budget,
            .depth = self.depth,
            .snapshots = self.snapshots,
            .tools_used = &self.tools_used,
            .loop_deadline_ms = self.loop_deadline_ms,
            .agent_cwd = self.agent_cwd,
        };
        // Esc while tools run: a stdin watcher for the join (esc_cancel);
        // subagents notice mid-flight, the root aborts at its next runTurn.
        const esc_watch = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
        var esc_tio: ?tty.RawState = null;
        var esc_fut: ?Io.Future(void) = null;
        if (esc_watch) if (rawNonblockStdin()) |tio| {
            esc_tio = tio;
            Agent.esc_watch_done.store(false, .release);
            esc_fut = self.io.async(escWatchTask, .{});
        };
        defer if (esc_tio) |tio| {
            Agent.esc_watch_done.store(true, .release);
            if (esc_fut) |*f| f.await(self.io);
            drainStdin();
            tty.restore(tio);
        };
        // Join ALL futures before any fallible work: an early error
        // return would otherwise free the futures while pool tasks are
        // still writing into them (and abandon running tools).
        const futures = try self.gpa.alloc(Io.Future(ToolOutput), ext_idx.items.len);
        defer self.gpa.free(futures);
        const outputs = try self.gpa.alloc(ToolOutput, ext_idx.items.len);
        defer self.gpa.free(outputs);
        for (ext_idx.items, futures) |i, *fut| fut.* = self.io.async(execTool, .{ ctx, calls[i] });
        for (futures, outputs) |*fut, *output| output.* = fut.await(self.io);
        defer for (outputs) |output| self.gpa.free(output.text);
        // #440: one threshold for the whole batch, pinned under this model's
        // send-time per-output cap so an oversized result is always turned into
        // a handle HERE rather than truncated later.
        const handle_threshold = tool_handle.effectiveThreshold(self.provider.perOutputCap());
        const handle_target: tool_handle.Target = .{
            .io = self.io,
            .dir = .cwd(),
            .run_id = if (self.tracer) |tr| tr.identity.run_id else "untraced",
        };
        for (ext_idx.items, outputs) |i, output| {
            // Over the threshold, the bytes go to a durable handle; the model
            // gets a bounded preview + path + byte count + shape hint.
            const handled = try tool_handle.forResult(self.gpa, self.arena, handle_target, output.text, handle_threshold);
            // #541: the handle-protocol lesson rides this agent's FIRST handle
            // instead of standing in every request's system prompt.
            const text = try tool_handle.withFirstNote(self.arena, handled, &self.handle_note_shown);
            results[i] = .{ .text = text, .is_error = output.is_error, .cancelled = output.cancelled, .ms = output.ms };
            if (self.eval_cmd != null and toolInvalidatesEval(calls[i])) {
                self.eval_verified = false;
                self.eval_repair_pending = false;
            }
        }
        brief_diversity.noteSiblingBatch(self.arena, self.tracer, calls, ext_idx.items, results); // #382
        // #266: a cancelled parallel batch used to just look "running" and then
        // failed — one terminal line says what completed, failed, and cancelled.
        if (ext_idx.items.len > 1 and !self.sub) { // root's line to draw, as above
            var tally: engine_events.BatchOutcome = .{ .done = 0, .failed = 0, .cancelled = 0 };
            for (ext_idx.items) |i| {
                const r = results[i];
                if (r.cancelled) tally.cancelled += 1 else if (r.is_error) tally.failed += 1 else tally.done += 1;
            }
            engine_sink.forAgent(self).emit(self.io, .{ .parallel_batch_finished = tally });
        }
    }
    if (defer_completion) if (eval_control.completionIndex(calls)) |i| {
        var verify_failed = ext_idx.items.len == 0;
        for (ext_idx.items) |j| {
            if (results[j].is_error or results[j].cancelled) verify_failed = true;
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
    for (calls, results) |call, r| self.sayToolResult(call.name, r);
    return results;
}

pub fn rejectToolCall(self: *Agent, call: ToolCall) !?ExecResult {
    if (self.sub) return null;
    if (self.review_mode) if (try review.rejectTool(self.arena, call)) |denied| {
        self.emitToolRejected(call, "review_mode", denied.text);
        return denied;
    };
    if (std.mem.eql(u8, call.name, "attempt_completion")) return null;
    if (main_mod.max_tool_calls) |max| {
        if (self.tool_calls_this_turn >= max) {
            const message = try std.fmt.allocPrint(self.arena, "tool call budget exhausted ({d}/{d}) — answer with what you have or ask for a higher --max-tool-calls", .{ self.tool_calls_this_turn, max });
            self.emitToolRejected(call, "budget", message);
            return .{ .text = message, .is_error = true };
        }
    }
    if (main_mod.dedupe_tool_calls) {
        const key = try self.toolDedupeKey(call);
        for (self.seen_tool_keys.items) |seen| {
            if (std.mem.eql(u8, seen, key)) {
                const message = try std.fmt.allocPrint(self.arena, "duplicate tool call rejected: {s} with the same normalized input already ran this turn", .{call.name});
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
fn parseClockSleepMs(input: Value) error{InvalidMs}!ClockSleepMs {
    if (input != .object) return error.InvalidMs;
    const raw = input.object.get("ms") orelse return error.InvalidMs;
    if (raw != .integer or raw.integer < 0) return error.InvalidMs;
    if (raw.integer > clock_sleep_max_ms) return .{ .ms = clock_sleep_max_ms, .clamped = true };
    return .{ .ms = raw.integer, .clamped = false };
}

fn clockSleepSuccessText(arena: std.mem.Allocator, ms: i64, clamped: bool) ![]const u8 {
    if (clamped) return std.fmt.allocPrint(arena, "clock_sleep: requested ms exceeded the 12h cap, clamped to {d} ms; slept {d} ms", .{ clock_sleep_max_ms, ms });
    return std.fmt.allocPrint(arena, "slept {d} ms", .{ms});
}

fn clockSleepInterruptedText(arena: std.mem.Allocator, elapsed_ms: i64) ![]const u8 {
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
    if (std.mem.eql(u8, call.name, "attempt_completion")) {
        if (!self.review_mode and self.eval_cmd != null and (!self.eval_verified or self.eval_repair_pending)) {
            const message = if (self.eval_repair_pending)
                "completion blocked: the latest verifier contradicted the plan; repair the failure and run eval until it meets the target"
            else
                "completion blocked: workspace state is not verified; run eval and meet the target after the final change";
            self.completion_refused = true; // blocked, not silence: attempt_completion skips the tool counter, and /loop must give the model a turn to run eval (#318)
            return .{ .text = message, .is_error = true };
        }
        if (try goal_state.completionGate(self.arena, self)) |refusal| {
            goal_state.noteCompletionRefused(self); // arm the double-check (across turns) and mark the turn as worked (#318)
            if (!self.sub) engine_sink.forAgent(self).emit(self.io, .completion_deferred); // root-only notice, as ever
            return .{ .text = refusal, .is_error = true };
        }
        const result = if (tools_mod.json_args.object(call.input)) |o| (tools_mod.json_args.str(o, "result") orelse "") else "";
        self.completed = try self.arena.dupe(u8, result);
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
        return .{ .text = r.text, .is_error = r.rejected };
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
    if (std.mem.eql(u8, call.name, mcp_schema_gate.tool_name) or @import("mcp_select.zig").isName(call.name)) return (native_fold.handleLoadNative(self, call.input) catch null) orelse @import("mcp_select.zig").dispatch(self, call);
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
/// event carrying its outcome and duration. Meta tools render their own UX,
/// so both sinks drop them (ask_user excepted on the wire, where the typed
/// reply IS the result).
pub fn sayToolResult(self: *Agent, name: []const u8, r: ExecResult) void {
    if (self.out == null) return; // no frontend attached: nothing to tell, as ever
    const ev: engine_events.ToolOutcome = .{
        .name = name,
        .text = r.text,
        .is_error = r.is_error,
        .cancelled = r.cancelled,
        .ms = r.ms,
        .meta = isMetaName(name),
        .ask_user = std.mem.eql(u8, name, "ask_user"),
    };
    const sink = engine_sink.forAgent(self);
    sink.emit(self.io, .{ .tool_result = ev });
    sink.emit(self.io, .{ .tool_call_finished = ev });
}

test "parseClockSleepMs: valid ms passes through, missing/negative/non-integer reject, over-cap clamps (#225)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const valid = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":200}", .{}) catch unreachable;
    const parsed = try parseClockSleepMs(valid);
    try std.testing.expectEqual(@as(i64, 200), parsed.ms);
    try std.testing.expect(!parsed.clamped);

    const zero = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":0}", .{}) catch unreachable;
    try std.testing.expectEqual(@as(i64, 0), (try parseClockSleepMs(zero)).ms);

    const missing = std.json.parseFromSliceLeaky(Value, a, "{}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(missing));

    const negative = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":-1}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(negative));

    const string_ms = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":\"soon\"}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(string_ms));

    const float_ms = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":200.5}", .{}) catch unreachable;
    try std.testing.expectError(error.InvalidMs, parseClockSleepMs(float_ms));

    const over_cap = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":99999999999}", .{}) catch unreachable;
    const clamped = try parseClockSleepMs(over_cap);
    try std.testing.expectEqual(clock_sleep_max_ms, clamped.ms);
    try std.testing.expect(clamped.clamped);
}

test "clockSleepSuccessText/clockSleepInterruptedText: exact result strings (#225 acceptance)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("slept 200 ms", try clockSleepSuccessText(a, 200, false));
    try std.testing.expectEqualStrings(
        "clock_sleep: requested ms exceeded the 12h cap, clamped to 43200000 ms; slept 43200000 ms",
        try clockSleepSuccessText(a, clock_sleep_max_ms, true),
    );
    try std.testing.expectEqualStrings("sleep interrupted after 150 ms by user input", try clockSleepInterruptedText(a, 150));
}

test "handleMeta clock_sleep: ms=0 completes for real end-to-end, bad ms rejects without touching Io" {
    // clock_sleep is a folded native: handleMeta refuses it until loaded. Mark it loaded rather than toggling fold.enabled: `enabled` is shared mutable state the parallel test runner races on (native_fold.zig's own tests flip it), while g_loaded is append-only and safe (the refusal is covered in native_fold.zig).
    @import("native_fold.zig").markLoaded("clock_sleep");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = a,
        .arena = a,
        // ms=0 never reaches sleepInterruptible's self.io.sleep() call (its
        // while loop is skipped at left=0), and the ms-error paths below
        // return before sleepInterruptible is even called — undefined Io is
        // safe for exactly these cases (a real Io backend has no unit-test
        // seam in this codebase; see agent_argstream.zig's own `.io =
        // undefined` test for the established precedent).
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    const zero_call: ToolCall = .{ .id = "1", .name = "clock_sleep", .input = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":0}", .{}) catch unreachable };
    const zero_result = try handleMeta(&agent, zero_call);
    try std.testing.expectEqualStrings("slept 0 ms", zero_result.text);
    try std.testing.expect(!zero_result.is_error);

    inline for (.{ "{}", "{\"ms\":-1}", "{\"ms\":\"soon\"}", "{\"ms\":200.5}" }) |bad_json| {
        const bad_call: ToolCall = .{ .id = "1", .name = "clock_sleep", .input = std.json.parseFromSliceLeaky(Value, a, bad_json, .{}) catch unreachable };
        const bad_result = try handleMeta(&agent, bad_call);
        try std.testing.expect(bad_result.is_error);
        try std.testing.expectEqualStrings("clock_sleep: ms must be a non-negative integer", bad_result.text);
    }
}

test "clock_sleep counts against --max-tool-calls and --dedupe-tool-calls like any other call (#225 rails, no bypass)" {
    const saved_max = main_mod.max_tool_calls;
    const saved_dedupe = main_mod.dedupe_tool_calls;
    defer {
        main_mod.max_tool_calls = saved_max;
        main_mod.dedupe_tool_calls = saved_dedupe;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = a,
        .arena = a,
        .io = undefined, // rejectToolCall never touches self.io
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    const call: ToolCall = .{ .id = "1", .name = "clock_sleep", .input = std.json.parseFromSliceLeaky(Value, a, "{\"ms\":0}", .{}) catch unreachable };

    main_mod.max_tool_calls = 1;
    main_mod.dedupe_tool_calls = false;
    try std.testing.expect((try rejectToolCall(&agent, call)) == null); // 1st call clears the budget gate
    const budget_denied = try rejectToolCall(&agent, call);
    try std.testing.expect(budget_denied != null);
    try std.testing.expect(budget_denied.?.is_error);
    try std.testing.expect(std.mem.indexOf(u8, budget_denied.?.text, "budget") != null);

    agent.tool_calls_this_turn = 0;
    main_mod.max_tool_calls = null;
    main_mod.dedupe_tool_calls = true;
    try std.testing.expect((try rejectToolCall(&agent, call)) == null); // 1st identical call clears the dedupe gate
    const dupe_denied = try rejectToolCall(&agent, call);
    try std.testing.expect(dupe_denied != null);
    try std.testing.expect(dupe_denied.?.is_error);
    try std.testing.expect(std.mem.indexOf(u8, dupe_denied.?.text, "duplicate") != null);
}
