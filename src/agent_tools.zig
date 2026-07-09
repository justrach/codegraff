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
const Agent = main_mod.Agent;
const ToolCall = main_mod.ToolCall;
const ExecResult = main_mod.ExecResult;
const AnswerRequest = main_mod.AnswerRequest;
const answerParseError = main_mod.answerParseError;
const parseAnswerRequest = main_mod.parseAnswerRequest;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const terminal = @import("term.zig");
const tty = terminal.tty;

const mcp = @import("mcp.zig");

const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;

const skills = @import("skills.zig");
const companionTrusted = skills.companionTrusted;
const companionReadOnly = skills.companionReadOnly;

const schema = @import("schema.zig");
const isMetaName = schema.isMetaName;

const tools_mod = @import("tools.zig");
const ToolCtx = tools_mod.ToolCtx;
const ToolOutput = tools_mod.ToolOutput;

const exec = @import("exec.zig");
const execTool = exec.execTool;

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

    // Collect the indices of external (non-meta) calls for parallel exec.
    var ext_idx: std.ArrayList(usize) = .empty;
    defer ext_idx.deinit(self.gpa);
    for (calls, 0..) |call, i| {
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
            results[i] = .{ .text = try self.arena.dupe(u8, output.text), .is_error = output.is_error, .ms = output.ms };
        }
    }
    // Show a compact ✓/✗ + preview for each non-meta call (no-op for subs).
    for (calls, results) |call, r| self.sayToolResult(call.name, r);
    return results;
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

/// The permission gate, root side: an unapproved bash command prompts
/// the user — yes once, always (approve the command's first word for
/// the rest of the session), or no. Returns the denial result, or null
/// when cleared to execute. Subagents never prompt; their gate is the
/// allowlist check in execToolInner.
pub fn gateTool(self: *Agent, call: ToolCall) !?ExecResult {
    if (self.sub) {
        // Destructive git is blocked for subagents outright — they have no
        // human to confirm with. The root agent falls through to a y/n
        // prompt below. Completes the Codex-style `.git` guard across both.
        if (std.mem.eql(u8, call.name, "bash") and call.input == .object) {
            if (call.input.object.get("command")) |cv| if (cv == .string and Approvals.isDestructiveGit(cv.string)) return .{
                .text = try self.arena.dupe(u8, "destructive git is blocked for subagents (no one to confirm) — leave reset --hard / clean -f / force-push / branch -D to the root session"),
                .is_error = true,
            };
        }
        return null; // subagents: otherwise gated structurally, not by prompt
    }
    const approvals = self.approvals orelse return null;

    // Plan mode: read-only, regardless of approvals — deny mutating tools
    // up front (no point prompting for something the mode forbids).
    if (main_mod.plan_mode) {
        if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or
            (mcp.Registry.isMcp(call.name) and !companionReadOnly(call.name, call.input))) return .{
            .text = try self.arena.dupe(u8, "plan mode is on — read-only. Fold this change into the plan you present; the user applies it after approving (/plan toggles the mode off)."),
            .is_error = true,
        };
        if (std.mem.eql(u8, call.name, "bash")) {
            const cmd_val = call.input.object.get("command") orelse return null;
            if (cmd_val != .string) return null;
            const cmd = std.mem.trim(u8, cmd_val.string, " \t");
            if (!Approvals.readOnlyAllowed(cmd)) return .{
                .text = try self.arena.dupe(u8, "plan mode is on — only read-only commands run (ls/cat/grep/git status…). Put this command in the plan instead."),
                .is_error = true,
            };
            return null;
        }
    }

    // Decide whether this call needs approval, and what the approval key
    // and prompt line are. bash keys on the command's first word; writes
    // and MCP tools key on the tool name.
    var key: []const u8 = undefined;
    var line_buf: [256]u8 = undefined;
    var prompt_line: []const u8 = undefined;

    if (std.mem.eql(u8, call.name, "bash")) {
        const cmd_val = call.input.object.get("command") orelse return null;
        if (cmd_val != .string) return null;
        const cmd = std.mem.trim(u8, cmd_val.string, " \t");
        // Destructive git (reset --hard, clean -f, branch -D, force-push…)
        // stays gated in normal mode + for subagents, but DOES run under --yolo
        // so the agent can't wipe the user's work or a worktree's checkpoints.
        // It falls through to a human y/n (or a deny in non-interactive runs).
        const destructive_git = Approvals.isDestructiveGit(cmd);
        const gate_ok = !destructive_git or Approvals.destructiveGitAllowed(approvals.yolo, self.sub);
        if (gate_ok and approvals.allowed(self.io, cmd)) return null;
        key = firstWord(cmd);
        prompt_line = if (destructive_git)
            std.fmt.bufPrint(&line_buf, "DESTRUCTIVE git — run: {s}", .{cmd}) catch cmd
        else
            std.fmt.bufPrint(&line_buf, "run: {s}", .{cmd}) catch cmd;
    } else if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file")) {
        if (approvals.allowedExact(self.io, call.name)) return null;
        key = call.name;
        const path = if (call.input == .object)
            (if (call.input.object.get("path")) |p| (if (p == .string) p.string else "?") else "?")
        else
            "?";
        prompt_line = std.fmt.bufPrint(&line_buf, "{s} {s}", .{ call.name, path }) catch call.name;
    } else if (mcp.Registry.isMcp(call.name)) {
        if (companionTrusted(call.name)) return null; // the whole suite: like native tools
        if (approvals.allowedExact(self.io, call.name)) return null;
        key = call.name;
        prompt_line = std.fmt.bufPrint(&line_buf, "call MCP tool {s}", .{call.name}) catch call.name;
    } else {
        return null; // read_file, subagent, workflow, meta: not gated
    }

    // No human to ask (one-shot -p, or stdin gone): deny instead of
    // hanging. Pre-approve in .harness/settings.json or pass --yolo.
    const in = self.in orelse return .{
        .text = try self.arena.dupe(u8, "not pre-approved, and no interactive user to ask in one-shot mode — pre-approve it in .harness/settings.json, or run with --yolo"),
        .is_error = true,
    };
    const w = self.out orelse return .{
        .text = try self.arena.dupe(u8, "not pre-approved, and no interactive user to ask — pre-approve it in .harness/settings.json, or run with --yolo"),
        .is_error = true,
    };

    try w.print("  ⚠ {s}\n  [y]es once · [a]lways allow \"{s}\" (saved to {s}) · [n]o › ", .{ prompt_line, key, Approvals.settings_path });
    try w.flush();
    const raw: []const u8 = (try in.takeDelimiter('\n')) orelse "";
    const answer = std.mem.trim(u8, raw, " \t\r");
    if (answer.len > 0) switch (answer[0]) {
        'y', 'Y' => return null,
        'a', 'A' => {
            try approvals.approve(self.io, self.gpa, key);
            if (std.mem.eql(u8, call.name, "bash") and Approvals.isInterpreter(key)) {
                try w.print("  note: \"{s}\" can execute arbitrary code (e.g. {s} -c '…'); approving it is effectively unrestricted.\n", .{ key, key });
                try w.flush();
            }
            return null;
        },
        else => {},
    };
    return .{
        .text = try self.arena.dupe(u8, "user declined this tool call — try another approach or ask them how to proceed"),
        .is_error = true,
    };
}

pub fn firstWord(cmd: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, cmd, " \t") orelse cmd.len;
    return cmd[0..end];
}

/// Handle a meta tool inline on the agent's own thread.
pub fn handleMeta(self: *Agent, call: ToolCall) !ExecResult {
    if (std.mem.eql(u8, call.name, "attempt_completion")) {
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
        style.dim,   style.reset, style.cyan, call.name,
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
