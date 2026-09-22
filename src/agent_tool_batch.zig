//! External tool-batch execution: sequential when any mutating tool is in
//! the batch, otherwise the existing parallel fan-out. Esc after preflight
//! still writes an error result for every remaining call id so the model
//! never sees a dangling tool_use.
const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const tools_mod = @import("tools.zig");
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const ToolCtx = tools_mod.ToolCtx;
const ToolOutput = tools_mod.ToolOutput;
const exec = @import("exec.zig");
const execTool = exec.execTool;
const imagegen = @import("imagegen.zig");
const terminal = @import("term.zig");
const tty = terminal.tty;
const engine_events = @import("engine_events.zig");
const engine_sink = @import("engine_sink.zig");
const tool_handle = @import("tool_handle.zig");
const eval_control = @import("agent_eval_control.zig");

pub const skipped_text = "tool execution skipped because the operation was aborted";

/// Write / edit / imagegen serialize the whole batch so a later edit cannot
/// race a write on the same path. Mixing bash with write/edit still
/// serializes, because write/edit do. Shell-only batches stay parallel
/// (#266); the parent joins all results before converting/freeing them (#1166).
pub fn isSequential(name: []const u8) bool {
    if (std.mem.eql(u8, name, "write_file")) return true;
    if (std.mem.eql(u8, name, "edit_file")) return true;
    if (std.mem.eql(u8, name, imagegen.tool_name)) return true;
    return false;
}

fn isShellName(name: []const u8) bool {
    return std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "bash");
}

/// Preserve the async scheduling policy introduced for #1166. This is not
/// thread affinity: Threaded Io may run async work on its pool too. Safety
/// relies on owned outputs and joining every future before result cleanup.
pub fn batchNeedsCooperative(calls: []const ToolCall, idx: []const usize) bool {
    for (idx) |i| {
        if (isShellName(calls[i].name)) return true;
    }
    return false;
}

pub fn batchNeedsSerial(calls: []const ToolCall, ext_idx: []const usize) bool {
    for (ext_idx) |i| {
        if (isSequential(calls[i].name)) return true;
    }
    return false;
}

pub fn runExternal(self: *Agent, calls: []const ToolCall, ext_idx: []const usize, results: []ExecResult) !void {
    if (ext_idx.len == 0) return;
    const serial = batchNeedsSerial(calls, ext_idx);
    if (ext_idx.len > 1 and !self.sub and !serial) {
        engine_sink.forAgent(self).emit(self.io, .{ .parallel_batch_started = .{ .count = ext_idx.len } });
    }
    const ctx: ToolCtx = .{
        .gpa = self.gpa,
        .io = self.io,
        .client = self.client,
        .provider = self.provider,
        .subagent_provider = self.subagent_provider,
        .subagent_cross_provider = self.subagent_cross_provider,
        .mcp_context = self.mcp_context.value,
        .registry = self.registry,
        .from_sub = self.sub,
        .interactive_children = !self.sub and @import("subagent_interactive.zig").enabled.load(.acquire),
        .session_name = self.session_name,
        .has_eval = self.eval_cmd != null,
        .approvals = self.approvals,
        .tracer = self.tracer,
        .run_budget = self.run_budget,
        .publication_checks = self.publication_checks,
        .publication_observer = .{ .context = self, .state = &self.publication_checks, .record = @import("pr_local_checks.zig").observeOutput },
        .depth = self.depth,
        .snapshots = self.snapshots,
        .tools_used = &self.tools_used,
        .loop_deadline_ms = self.loop_deadline_ms,
        .agent_cwd = self.agent_cwd,
        .subagent_feedback = self.feedback,
        .read_miss = &self.read_miss,
    };
    const esc_watch = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    var esc_tio: ?tty.RawState = null;
    var esc_fut: ?Io.Future(void) = null;
    if (esc_watch) if (Agent.rawNonblockStdin()) |tio| {
        esc_tio = tio;
        Agent.esc_watch_done.store(false, .release);
        esc_fut = self.io.async(Agent.escWatchTask, .{});
    };
    defer if (esc_tio) |tio| {
        Agent.esc_watch_done.store(true, .release);
        if (esc_fut) |*f| f.await(self.io);
        Agent.drainStdin();
        tty.restore(tio);
    };

    if (serial) {
        try runSerial(self, ctx, calls, ext_idx, results);
    } else {
        try runParallel(self, ctx, calls, ext_idx, results);
    }

    if (ext_idx.len > 1 and !self.sub and !serial) {
        var tally: engine_events.BatchOutcome = .{ .done = 0, .failed = 0, .cancelled = 0 };
        for (ext_idx) |i| {
            const r = results[i];
            if (r.cancelled) tally.cancelled += 1 else if (r.is_error) tally.failed += 1 else tally.done += 1;
        }
        engine_sink.forAgent(self).emit(self.io, .{ .parallel_batch_finished = tally });
    }
}

fn skipResult(self: *Agent, call: ToolCall) ExecResult {
    engine_sink.forAgent(self).emit(self.io, .{ .tool_rejected = .{
        .id = call.id,
        .name = call.name,
        .input = call.input,
        .reason = "aborted",
        .message = skipped_text,
    } });
    return .{ .text = skipped_text, .is_error = true, .cancelled = true };
}

fn aborted() bool {
    return Agent.esc_cancel.load(.acquire);
}

fn takeOutput(self: *Agent, call: ToolCall, output: ToolOutput, handle_threshold: usize, handle_target: tool_handle.Target) !ExecResult {
    self.read_miss.noteOutput(call.name, call.input, output.text, output.is_error);
    try @import("pr_local_checks.zig").record(self, call, .{ .text = output.text, .is_error = output.is_error, .cancelled = output.cancelled });
    const handled = try tool_handle.forResult(self.gpa, self.arena, handle_target, output.text, handle_threshold);
    const text = try tool_handle.withFirstNote(self.arena, handled, &self.handle_note_shown);
    if (self.eval_cmd != null and eval_control.toolInvalidatesEval(call)) {
        self.eval_verified = false;
        self.eval_repair_pending = false;
    }
    return .{ .text = text, .is_error = output.is_error, .cancelled = output.cancelled, .ms = output.ms };
}

fn handleTarget(self: *Agent) tool_handle.Target {
    return .{
        .io = self.io,
        .dir = .cwd(),
        .run_id = if (self.tracer) |tr| tr.identity.run_id else "untraced",
    };
}

fn runSerial(self: *Agent, ctx: ToolCtx, calls: []const ToolCall, ext_idx: []const usize, results: []ExecResult) !void {
    const handle_threshold = tool_handle.effectiveThreshold(self.provider.perOutputCap());
    const handle_tgt = handleTarget(self);
    for (ext_idx, 0..) |i, k| {
        if (k > 0 and aborted()) {
            results[i] = skipResult(self, calls[i]);
            continue;
        }
        const output = execTool(ctx, calls[i]);
        defer self.gpa.free(output.text);
        results[i] = try takeOutput(self, calls[i], output, handle_threshold, handle_tgt);
    }
}

fn runParallel(self: *Agent, ctx: ToolCtx, calls: []const ToolCall, ext_idx: []const usize, results: []ExecResult) !void {
    var spawn_at: std.ArrayList(usize) = .empty;
    defer spawn_at.deinit(self.gpa);
    for (ext_idx, 0..) |i, k| {
        if (k > 0 and aborted()) {
            results[i] = skipResult(self, calls[i]);
            continue;
        }
        try spawn_at.append(self.gpa, i);
    }
    if (spawn_at.items.len == 0) return;

    const futures = try self.gpa.alloc(Io.Future(ToolOutput), spawn_at.items.len);
    defer self.gpa.free(futures);
    const outputs = try self.gpa.alloc(ToolOutput, spawn_at.items.len);
    defer self.gpa.free(outputs);
    const cooperative = batchNeedsCooperative(calls, spawn_at.items);
    for (spawn_at.items, futures) |i, *fut| {
        // Async may fall back to inline execution under saturation; it does
        // not guarantee execution on the caller thread (Threaded Io).
        fut.* = if (cooperative)
            self.io.async(execTool, .{ ctx, calls[i] })
        else
            self.io.concurrent(execTool, .{ ctx, calls[i] }) catch self.io.async(execTool, .{ ctx, calls[i] });
    }
    for (futures, outputs) |*fut, *output| output.* = fut.await(self.io);
    defer for (outputs) |output| self.gpa.free(output.text);

    const handle_threshold = tool_handle.effectiveThreshold(self.provider.perOutputCap());
    const handle_tgt = handleTarget(self);
    for (spawn_at.items, outputs) |i, output| {
        results[i] = try takeOutput(self, calls[i], output, handle_threshold, handle_tgt);
    }
}

test "isSequential: mutating file tools, not shell or reads" {
    try std.testing.expect(isSequential("write_file"));
    try std.testing.expect(isSequential("edit_file"));
    try std.testing.expect(isSequential(imagegen.tool_name));
    try std.testing.expect(!isSequential("shell"));
    try std.testing.expect(!isSequential("bash"));
    try std.testing.expect(!isSequential("read_file"));
    try std.testing.expect(!isSequential("codedb"));
    try std.testing.expect(!isSequential("webfetch"));
    try std.testing.expect(!isSequential("subagent"));
}

test "batchNeedsSerial: file mutations serialize; bash-only stays parallel" {
    const read = ToolCall{ .id = "1", .name = "read_file", .input = .{ .object = .empty } };
    const write = ToolCall{ .id = "2", .name = "write_file", .input = .{ .object = .empty } };
    const codedb = ToolCall{ .id = "3", .name = "codedb", .input = .{ .object = .empty } };
    const bash = ToolCall{ .id = "4", .name = "bash", .input = .{ .object = .empty } };
    const mixed = [_]ToolCall{ read, write };
    try std.testing.expect(batchNeedsSerial(&mixed, &.{ 0, 1 }));
    const reads = [_]ToolCall{ read, codedb };
    try std.testing.expect(!batchNeedsSerial(&reads, &.{ 0, 1 }));
    const only_write = [_]ToolCall{write};
    try std.testing.expect(batchNeedsSerial(&only_write, &.{0}));
    const two_bash = [_]ToolCall{ bash, bash };
    try std.testing.expect(!batchNeedsSerial(&two_bash, &.{ 0, 1 }));
    try std.testing.expect(batchNeedsCooperative(&two_bash, &.{ 0, 1 }));
    const bash_write = [_]ToolCall{ bash, write };
    try std.testing.expect(batchNeedsSerial(&bash_write, &.{ 0, 1 }));
    try std.testing.expect(!batchNeedsCooperative(&reads, &.{ 0, 1 }));
}

test "isShellName: bash and shell, not reads" {
    try std.testing.expect(isShellName("bash"));
    try std.testing.expect(isShellName("shell"));
    try std.testing.expect(!isShellName("read_file"));
    try std.testing.expect(!isShellName("webfetch"));
}

test "skipped_text is a stable model-facing sentence" {
    try std.testing.expect(std.mem.indexOf(u8, skipped_text, "skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, skipped_text, "aborted") != null);
}
