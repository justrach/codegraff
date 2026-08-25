//! Root and subagent `bash` dispatch. Split out of exec.zig so the grok-build
//! auto-background path (#620) has room without growing exec.zig.
//!
//! Root foreground: spawn a job, wait up to 120s (or `timeout` ms), then
//! promote rather than kill — the process keeps running and the model gets a
//! job id. Subagents stay on the #93 kill-at-120s path (no TTY, no /jobs UI).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const strField = tools.strField;
const intField = tools.intField;
const missingArg = tools.missingArg;
const bash_stdout_cap = tools.bash_stdout_cap;
const bash_stderr_cap = tools.bash_stderr_cap;

const jobs = @import("jobs.zig");
const job_wait = @import("job_wait.zig");
const exec_bash_stream = @import("exec_bash_stream.zig");

/// grok-build's default foreground wait. After this, root bash is moved to
/// the job registry instead of being killed (xai-org/grok-build BashTool).
pub const root_wait_ms: u64 = 120 * 1000;

/// Wall-clock ceiling for one *subagent* bash command. Subagents run on pool
/// threads with no TTY, so there is no Esc to kill a runaway command — without
/// this, a codedb refusal that pushes a subagent onto an unfiltered `grep ~/`
/// hangs the whole workflow for ~48 min (#93).
pub const subagent_deadline_ms: u64 = 120 * 1000;

const cancel_hint =
    "If this was a server, drill, or anything that should outlive one turn, restart with run_in_background: true — do not wait in the foreground again.";

/// #266: killing a local `ssh` proves nothing about the remote command it was
/// running — a cancelled or timed-out ssh result carries a caveat saying so.
fn isSshCommand(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    const first = it.next() orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(first), "ssh");
}

test "isSshCommand: bare and pathed ssh, not scp or substrings" {
    try std.testing.expect(isSshCommand("ssh host uptime"));
    try std.testing.expect(isSshCommand("  /usr/bin/ssh -T host"));
    try std.testing.expect(!isSshCommand("scp file host:"));
    try std.testing.expect(!isSshCommand("echo ssh"));
    try std.testing.expect(!isSshCommand(""));
}

fn spawnFailText(gpa: Allocator, err: anyerror) ![]u8 {
    // #122: backgrounding costs MORE fds (pipes + pump task), so the generic
    // "run it in the foreground" advice is right for every error except the
    // fd-quota ones. #253: SYSTEM-wide exhaustion is not a ulimit problem.
    return if (err == error.ProcessFdQuotaExceeded)
        try gpa.dupe(u8, "could not start background job (ProcessFdQuotaExceeded) — graff hit its open-file limit. Wait for running jobs/tools to finish, then retry with less parallel fan-out; if it recurs, raise the limit (`ulimit -n 4096`) before starting graff.")
    else if (err == error.SystemFdQuotaExceeded)
        try gpa.dupe(u8, "could not start background job (SystemFdQuotaExceeded) — the SYSTEM-wide open-file table is full, so neither foregrounding nor `ulimit` helps. Wait for other processes to release files (or close some applications), then retry.")
    else
        try std.fmt.allocPrint(gpa, "could not start background job ({t}) — run it in the foreground instead", .{err});
}

fn startedText(gpa: Allocator, id: u32, cmd: []const u8, ssh: bool, auto_bg: bool, wait_s: u64, partial: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("[job {d} started: {s}]\n", .{ id, cmd });
    if (auto_bg) {
        try w.print("Command exceeded the {d}s foreground wait and was automatically moved to the background. Process is still running. ", .{wait_s});
    }
    try w.print("You are notified on exit — do not poll. bash_output(id {d}, wait_ms>0) blocks until it exits; omit wait_ms for a snapshot. bash_kill stops it.", .{id});
    if (ssh) try w.writeAll(" Killing the local SSH job cannot prove a detached remote process stopped; verify the remote host.");
    if (partial.len > 0) {
        try w.writeAll("\n");
        try w.writeAll(partial);
    }
    return aw.toOwnedSlice();
}

fn rootWaitMs(input: Value) u64 {
    const t = intField(input, "timeout") orelse return root_wait_ms;
    if (t <= 0) return root_wait_ms;
    return @min(@as(u64, @intCast(t)), job_wait.wait_cap_ms);
}

test "rootWaitMs: omitted/zero use 120s; positive values clamp to the 10h cap" {
    const empty = try std.json.parseFromSlice(Value, std.testing.allocator, "{}", .{});
    defer empty.deinit();
    try std.testing.expectEqual(root_wait_ms, rootWaitMs(empty.value));
    const zero = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"timeout\":0}", .{});
    defer zero.deinit();
    try std.testing.expectEqual(root_wait_ms, rootWaitMs(zero.value));
    const custom = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"timeout\":5000}", .{});
    defer custom.deinit();
    try std.testing.expectEqual(@as(u64, 5_000), rootWaitMs(custom.value));
    const huge = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"timeout\":999999999}", .{});
    defer huge.deinit();
    try std.testing.expectEqual(job_wait.wait_cap_ms, rootWaitMs(huge.value));
}

fn formatJobDone(gpa: Allocator, cmd: []const u8, wait: jobs.FgDone) !ToolOutput {
    defer gpa.free(wait.output);
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (wait.output.len > 0) try w.writeAll(wait.output);
    if (wait.dropped) try w.print("\n[oldest unread output was dropped at the {d} KB cap]", .{jobs.job_unread_cap / 1024});
    if (wait.killed) {
        try w.writeAll("\n[cancelled by user; local process group killed]\n");
        try w.writeAll(cancel_hint);
        if (isSshCommand(cmd)) try w.writeAll("\n[ssh note: the local SSH client was killed, but a detached or disconnect-resistant remote process may survive; verify it on the remote host]");
        if (wait.output.len == 0) try w.writeAll("\n(no output)");
        return .{ .text = try aw.toOwnedSlice(), .is_error = true, .cancelled = true };
    }
    if (wait.exit_code) |code| {
        if (code != 0) try w.print("\n[exit code {d}]", .{code});
    } else try w.writeAll("\n[terminated abnormally]");
    if (wait.output.len == 0 and (wait.exit_code orelse 1) == 0) try w.writeAll("(no output)");
    const code = wait.exit_code;
    return .{ .text = try aw.toOwnedSlice(), .is_error = code == null or code.? != 0 };
}

fn formatCancelled(gpa: Allocator, cmd: []const u8, wait: jobs.FgPartial) !ToolOutput {
    defer gpa.free(wait.output);
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (wait.output.len > 0) {
        try w.writeAll(wait.output);
        try w.writeAll("\n");
    }
    try w.writeAll("[cancelled by user; local process group killed]\n");
    try w.writeAll(cancel_hint);
    if (isSshCommand(cmd)) try w.writeAll("\n[ssh note: the local SSH client was killed, but a detached or disconnect-resistant remote process may survive; verify it on the remote host]");
    return .{ .text = try aw.toOwnedSlice(), .is_error = true, .cancelled = true };
}

test "cancel hint tells the model to restart with run_in_background" {
    try std.testing.expect(std.mem.indexOf(u8, cancel_hint, "run_in_background") != null);
}

fn formatCapped(gpa: Allocator, cmd: []const u8, run: jobs.CappedRun) !ToolOutput {
    const exit_code: ?u8 = switch (run.term) {
        .exited => |code| code,
        else => null,
    };
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (run.stdout.len > 0) try w.writeAll(run.stdout);
    if (run.stdout_truncated) try w.print("\n[stdout truncated at {d} KB]", .{bash_stdout_cap / 1024});
    if (run.stderr.len > 0) try w.print("\n[stderr]\n{s}", .{run.stderr});
    if (run.stderr_truncated) try w.print("\n[stderr truncated at {d} KB]", .{bash_stderr_cap / 1024});
    if (run.cancelled) {
        try w.writeAll("\n[cancelled by user; local process group killed]\n");
        try w.writeAll(cancel_hint);
    } else if (run.timed_out) {
        try w.print("\n[timed out after {d}s and was killed — too long for a subagent. Don't retry as-is: scope it to specific paths or globs instead of scanning the whole directory, or report back what you need run.]", .{subagent_deadline_ms / 1000});
    } else if (exit_code) |code| {
        if (code != 0) try w.print("\n[exit code {d}]", .{code});
    } else try w.writeAll("\n[terminated abnormally]");
    if ((run.cancelled or run.timed_out) and isSshCommand(cmd)) {
        try w.writeAll("\n[ssh note: the local SSH client was killed, but a detached or disconnect-resistant remote process may survive; verify it on the remote host]");
    }
    if (run.stdout.len == 0 and run.stderr.len == 0 and exit_code == 0) try w.writeAll("(no output)");
    return .{ .text = try aw.toOwnedSlice(), .is_error = exit_code == null or exit_code.? != 0, .cancelled = run.cancelled };
}

pub fn exec(ctx: ToolCtx, call: tools.ToolCall) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const input = call.input;
    const cmd = strField(input, "command") orelse return missingArg(gpa, "command");
    // Subagents have no stdin to prompt on; their gate is the allowlist.
    if (ctx.from_sub) if (ctx.approvals) |ap| if (!ap.allowed(ctx.io, cmd)) return .{
        .text = try gpa.dupe(u8, "command not pre-approved — subagents may only run user-approved or read-only commands, with no chaining/pipes/redirection. Use read_file/edit_file/write_file, or report back what you need run."),
        .is_error = true,
    };
    const ssh = isSshCommand(cmd);
    const bg = tools.json_args.flag(input, "run_in_background");
    if (bg or !ctx.from_sub) {
        var live = exec_bash_stream.Ctx{ .io = io };
        const job = jobs.spawnJobOpts(gpa, io, cmd, .{
            .cwd = ctx.agent_cwd,
            .stream = if (!ctx.from_sub and !bg) exec_bash_stream.emit else null,
            .stream_ctx = if (!ctx.from_sub and !bg) &live else null,
            .quiet = !bg, // foreground wait is not a /jobs event until auto-bg
        }) catch |err| return .{ .text = try spawnFailText(gpa, err), .is_error = true };
        if (bg) {
            return .{ .text = try startedText(gpa, job.id, job.cmd, ssh, false, 0, "") };
        }
        const wait_ms = rootWaitMs(input);
        const waited = jobs.waitForeground(gpa, io, job.id, wait_ms) catch |err| return .{
            .text = try std.fmt.allocPrint(gpa, "could not wait on job {d} ({t})", .{ job.id, err }),
            .is_error = true,
        };
        return switch (waited) {
            .done => |d| blk: {
                defer jobs.reapFinished(gpa, io, job.id);
                break :blk try formatJobDone(gpa, cmd, d);
            },
            .running => |r| blk: {
                defer gpa.free(r.output);
                break :blk .{ .text = try startedText(gpa, r.id, cmd, ssh, true, wait_ms / 1000, r.output) };
            },
            .cancelled => |c| blk: {
                defer jobs.reapFinished(gpa, io, c.id);
                break :blk try formatCancelled(gpa, cmd, c);
            },
        };
    }
    const sh = jobs.shellArgv(cmd);
    var opts = jobs.toolRunOptions(ctx.agent_cwd);
    var live = exec_bash_stream.Ctx{ .io = io };
    exec_bash_stream.attach(&opts, false, &live); // subagents stay quiet (#93)
    const run = try jobs.runCappedWithOptions(gpa, io, &sh, bash_stdout_cap, bash_stderr_cap, subagent_deadline_ms, opts);
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    return formatCapped(gpa, cmd, run);
}
