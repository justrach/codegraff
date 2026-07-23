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
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;

const AnswerRequest = tools_mod.AnswerRequest;
const answerParseError = tools_mod.answerParseError;
const parseAnswerRequest = tools_mod.parseAnswerRequest;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const terminal = @import("term.zig");
const tty = terminal.tty;

const schema = @import("schema.zig");
const isMetaName = schema.isMetaName;
const eval_control = @import("agent_eval_control.zig");
pub const toolInvalidatesEval = eval_control.toolInvalidatesEval;
pub const gateTool = @import("agent_tool_gate.zig").gateTool;
pub const firstWord = @import("agent_tool_gate.zig").firstWord;

const tools_mod = @import("tools.zig");
const ToolCtx = tools_mod.ToolCtx;
const ToolOutput = tools_mod.ToolOutput;

const exec = @import("exec.zig");
const execTool = exec.execTool;

const util = @import("util.zig"); // #225: unixMs, for the clock_sleep interrupted-elapsed measurement

const tool_results_dir = ".graff/tool-results";
pub const tool_preview_chars: usize = 2_000;
var tool_result_seq: std.atomic.Value(u64) = .init(0);

test {
    _ = @import("agent_eval_control_tests.zig");
}

pub fn toolPreviewText(arena: std.mem.Allocator, text: []const u8, path: ?[]const u8) ![]const u8 {
    if (text.len <= tool_preview_chars) return arena.dupe(u8, text);
    const marker = if (path) |p|
        try std.fmt.allocPrint(arena, "[full tool result: {s} — inspect with read_file]", .{p})
    else
        "[tool result truncated: full-result persistence failed]";
    const head = util.utf8Prefix(text, tool_preview_chars -| (marker.len + 2));
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ head, marker });
}

fn persistToolResult(self: *Agent, text: []const u8) ?[]const u8 {
    if (text.len <= tool_preview_chars) return null;
    // createDir reports PathAlreadyExists, which is the normal case because
    // trace setup creates `.graff` at launch. createDirPath is idempotent.
    Io.Dir.cwd().createDirPath(self.io, tool_results_dir) catch return null;
    const seq = tool_result_seq.fetchAdd(1, .monotonic);
    const run_id = if (self.tracer) |tr| tr.identity.run_id else "untraced";
    const path = std.fmt.allocPrint(self.arena, "{s}/{s}-{d}.txt", .{ tool_results_dir, run_id, seq }) catch return null;
    Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = text, .flags = .{ .exclusive = true } }) catch return null;
    return path;
}

// escWatchTask/drainStdin/rawNonblockStdin live in agent_interrupt.zig;
// Agent.esc_watch_done is a struct-level pub var that STAYS declared inside the
// Agent struct in main.zig (never alias a var — see esc_cancel/
// Agent.esc_watch_done in agent_interrupt.zig's own header comment). All reached
// through the Agent struct's namespace.
const escWatchTask = Agent.escWatchTask;
const drainStdin = Agent.drainStdin;
const rawNonblockStdin = Agent.rawNonblockStdin;

/// Run a batch of tool calls. Meta tools are handled inline (they mutate
/// agent state); everything else fans out across the Io thread pool.
/// Bash calls must clear the permission gate before dispatch. Results
/// are returned in call order, arena-owned.
pub fn runTools(self: *Agent, calls: []const ToolCall) ![]ExecResult {
    const results = try self.arena.alloc(ExecResult, calls.len);
    const eval_index = eval_control.evalCallIndex(calls);
    var batch_may_change_workspace = false;
    for (calls) |call| {
        if (toolInvalidatesEval(call)) {
            batch_may_change_workspace = true;
            break;
        }
    }

    // Collect the indices of external (non-meta) calls for parallel exec.
    var ext_idx: std.ArrayList(usize) = .empty;
    defer ext_idx.deinit(self.gpa);
    for (calls, 0..) |call, i| {
        if (eval_index) |verifier| if (i != verifier) {
            self.emitToolRejected(call, "verifier_boundary", eval_control.verifier_boundary);
            results[i] = .{ .text = eval_control.verifier_boundary, .is_error = true };
            continue;
        };
        if (batch_may_change_workspace and std.mem.eql(u8, call.name, "attempt_completion")) {
            const message = "attempt_completion must be a separate post-verification action; this batch also contains a workspace-changing tool";
            self.emitToolRejected(call, "eval_stale", message);
            results[i] = .{ .text = message, .is_error = true };
            continue;
        }
        if (try self.rejectToolCall(call)) |denied| {
            results[i] = denied;
            continue;
        }
        try self.sayToolUse(call);
        if (isMetaName(call.name)) {
            results[i] = try self.handleMeta(call);
        } else if (try self.gateTool(call)) |denied| {
            results[i] = denied;
        } else {
            try ext_idx.append(self.gpa, i);
        }
    }

    if (ext_idx.items.len > 0) {
        if (ext_idx.items.len > 1 and !self.sub) {
            try self.say("  {s}↯ running {d} tools in parallel{s}\n", .{ style.dim, ext_idx.items.len, style.reset });
        }
        const ctx: ToolCtx = .{
            .gpa = self.gpa,
            .io = self.io,
            .client = self.client,
            .provider = self.provider,
            .registry = if (self.sub) null else self.registry,
            .from_sub = self.sub,
            .approvals = self.approvals,
            .tracer = self.tracer,
            .run_budget = self.run_budget,
            .depth = self.depth,
            .snapshots = self.snapshots,
            .tools_used = &self.tools_used,
        };
        // Esc while tools run: spawn a stdin watcher for the duration of
        // the join (see esc_cancel). Subagents notice the flag mid-flight;
        // the root aborts the turn at its next runTurn iteration.
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
        for (ext_idx.items, outputs) |i, output| {
            // Keep the model-facing history compact. The exact output remains
            // inspectable on disk and the short preview carries its pointer.
            const detail = persistToolResult(self, output.text);
            results[i] = .{ .text = try toolPreviewText(self.arena, output.text, detail), .is_error = output.is_error, .ms = output.ms };
            if (self.eval_cmd != null and toolInvalidatesEval(calls[i])) {
                self.eval_verified = false;
                self.eval_repair_pending = false;
            }
        }
    }
    // Show a compact ✓/✗ + preview for each non-meta call (no-op for subs).
    for (calls, results) |call, r| self.sayToolResult(call.name, r);
    return results;
}

test "toolPreviewText caps context and preserves an inspect pointer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const preview = try toolPreviewText(arena_state.allocator(), &util.repeatBytes("x", 5000), ".graff/tool-results/run-1.txt");
    try std.testing.expect(preview.len <= tool_preview_chars);
    try std.testing.expect(std.mem.indexOf(u8, preview, ".graff/tool-results/run-1.txt") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview));
}

pub fn rejectToolCall(self: *Agent, call: ToolCall) !?ExecResult {
    if (self.sub) return null;
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

pub fn emitToolRejected(self: *Agent, call: ToolCall, reason: []const u8, message: []const u8) void {
    if (!main_mod.json_mode) return;
    self.emit(.{ .type = "tool_rejected", .name = call.name, .reason = reason, .input = call.input, .message = message });
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
    if (std.mem.eql(u8, call.name, "attempt_completion")) {
        if (self.eval_cmd != null and (!self.eval_verified or self.eval_repair_pending)) {
            const message = if (self.eval_repair_pending)
                "completion blocked: the latest verifier contradicted the plan; repair the failure and run eval until it meets the target"
            else
                "completion blocked: workspace state is not verified; run eval and meet the target after the final change";
            return .{ .text = message, .is_error = true };
        }
        const result = if (call.input.object.get("result")) |r| r.string else "";
        self.completed = try self.arena.dupe(u8, result);
        // Skip the re-print only when the result streamed live in full.
        if (!self.sub and !self.argStreamedFully(call)) try self.say("{s}\n", .{result});
        return .{ .text = "completion recorded", .is_error = false };
    }
    if (std.mem.eql(u8, call.name, "eval")) {
        const note = if (call.input.object.get("note")) |n| (if (n == .string) n.string else "") else "";
        return self.runEval(note);
    }
    if (std.mem.eql(u8, call.name, "todo_write")) {
        self.todos.clearRetainingCapacity();
        if (call.input.object.get("todos")) |list| if (list == .array) {
            for (list.array.items) |item| {
                if (item != .object) continue;
                const content = item.object.get("content") orelse continue;
                if (content != .string) continue;
                const status = if (item.object.get("status")) |st| (if (st == .string) st.string else "pending") else "pending";
                try self.todos.append(self.arena, .{
                    .content = try self.arena.dupe(u8, content.string),
                    .status = try self.arena.dupe(u8, status),
                });
            }
        };
        const rendered = self.renderTodos();
        if (!self.sub) try self.say("{s}\n", .{rendered});
        return .{ .text = rendered, .is_error = false };
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
    if (std.mem.eql(u8, call.name, "ask_user")) return self.askUser(call);
    // todo_read
    return .{ .text = self.renderTodos(), .is_error = false };
}

/// The "user message as a tool" half of the loop: the agent calls
/// ask_user, we block for a typed reply, and hand it back as the tool
/// result. Only the root agent has stdin; subagents must self-decide.
pub fn askUser(self: *Agent, call: ToolCall) !ExecResult {
    const in = self.in orelse return .{
        .text = "no human is attached — make a reasonable assumption and continue",
        .is_error = true,
    };
    const w = self.out.?;
    const question = if (call.input.object.get("question")) |q| q.string else "(no question)";
    if (main_mod.json_mode) {
        const call_id = if (call.id.len > 0) call.id else blk: {
            const id = try std.fmt.allocPrint(self.arena, "ask_user-{d}", .{self.next_ask_id});
            self.next_ask_id += 1;
            break :blk id;
        };
        try self.emitAskUser(call_id, question, call.input);
        const raw = (try in.takeDelimiter('\n')) orelse return .{
            .text = "user ended input without answering",
            .is_error = true,
        };
        const parsed = std.json.parseFromSliceLeaky(Value, self.arena, std.mem.trim(u8, raw, " \t\r"), .{ .allocate = .alloc_always }) catch return .{
            .text = "invalid answer JSON for ask_user",
            .is_error = true,
        };
        const answer = parseAnswerRequest(parsed, call_id) catch |err| return .{
            .text = answerParseError(err),
            .is_error = true,
        };
        if (answer.cancelled) return .{ .text = "user cancelled the follow-up", .is_error = true };
        return .{ .text = try self.arena.dupe(u8, answer.text), .is_error = false };
    }
    // Skip the re-print only when the question streamed live in full.
    if (!self.argStreamedFully(call)) try w.print("\n❓ {s}\n", .{question});
    if (call.input.object.get("options")) |opts| if (opts == .array) {
        for (opts.array.items, 1..) |opt, n| try w.print("   {d}) {s}\n", .{ n, opt.string });
    };
    try w.writeAll("   your answer › ");
    try w.flush();

    const raw = (try in.takeDelimiter('\n')) orelse return .{
        .text = "user ended input without answering",
        .is_error = true,
    };
    const answer = std.mem.trim(u8, raw, " \t\r");
    return .{ .text = try self.arena.dupe(u8, answer), .is_error = false };
}

pub fn emitAskUser(self: *Agent, call_id: []const u8, question: []const u8, input: Value) !void {
    const w = self.out orelse return;
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("ask_user");
    try s.objectField("call_id");
    try s.write(call_id);
    try s.objectField("question");
    try s.write(question);
    try s.objectField("input");
    try s.write(input);
    try s.endObject();
    try w.writeByte('\n');
    try w.flush();
}

pub fn sayToolUse(self: *Agent, call: ToolCall) !void {
    if (main_mod.json_mode) {
        if (std.mem.eql(u8, call.name, "ask_user")) return;
        self.emit(.{ .type = "tool_call", .name = call.name, .input = call.input });
        self.emit(.{ .type = "tool_call_started", .name = call.name, .input = call.input });
        return;
    }
    // The ⚙ line would just repeat prose that already streamed live.
    if (self.argStreamedFully(call)) return;
    var aw: Io.Writer.Allocating = .init(self.gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(call.input);
    const full = aw.writer.buffered();
    const shown = if (full.len > 160) full[0..160] else full;
    try self.say("{s}⚙{s} {s}{s} {s}{s}{s}{s}\n", .{
        style.dim,   style.reset, style.accent, call.name,
        style.dim,   shown,
        if (full.len > 160) "…" else "",
        style.reset,
    });
}

/// Compact result feedback for one finished tool call: a green ✓ / red ✗
/// and a one-line preview of what it returned. Root only (subagents have
/// no writer); meta tools render their own UX, so skip them.
pub fn sayToolResult(self: *Agent, name: []const u8, r: ExecResult) void {
    const w = self.out orelse return;
    if (main_mod.json_mode) {
        if (isMetaName(name) and !std.mem.eql(u8, name, "ask_user")) return;
        self.emit(.{ .type = "tool_result", .name = name, .is_error = r.is_error, .text = r.text });
        self.emit(.{ .type = "tool_call_finished", .name = name, .is_error = r.is_error, .ms = r.ms });
        return;
    }
    if (isMetaName(name)) return;
    const all = std.mem.trim(u8, r.text, " \t\r\n");
    var preview = all;
    if (std.mem.indexOfScalar(u8, preview, '\n')) |nl| preview = preview[0..nl];
    preview = std.mem.trim(u8, preview, " \t\r");
    const shown = if (preview.len > 100) preview[0..100] else preview;
    const truncated = shown.len < all.len; // more content (extra lines or >100 chars)
    const mark = if (r.is_error) "✗" else "✓";
    const mc = if (r.is_error) style.red else style.green;
    var tbuf: [24]u8 = undefined;
    const timing = if (main_mod.show_timing and r.ms > 0)
        (std.fmt.bufPrint(&tbuf, " ({d}ms)", .{r.ms}) catch "")
    else
        "";
    w.print("  {s}{s}{s}{s}{s}{s} {s}{s}{s}{s}\n", .{
        mc,          mark,  style.reset, style.dim, timing, style.reset,
        style.dim,   shown,
        if (truncated) "…" else "",
        style.reset,
    }) catch return;
    w.flush() catch return;
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
