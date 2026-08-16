//! Tool dispatch: `execTool` (the timed/traced/hooked outer wrapper, whose
//! guard chain starts with the #330 `--no-local-tools` refusal) and
//! `execToolInner` (the big per-tool-name switch — bash, bash_output,
//! bash_kill, webfetch, read_file, codedb, edit_file, write_file, subagent,
//! workflow, learn_candidate). Split out of main.zig (600-line goal); LAST in
//! the tool-exec region since it's the glue that imports tools.zig/
//! subagent.zig/workflow.zig as siblings, plus approvals.zig/mcp.zig/jobs.zig/
//! skills.zig/telemetry.zig. Back-imports main (`main_mod`) for `ToolCall`/
//! `plan_mode` (pub-flipped) and `utf8Prefix`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const util = @import("util.zig");
const codedbpro_report = @import("codedbpro_report.zig"); // licensed-companion failure → redacted issue filer
const codedbpro_paths = @import("codedbpro_paths.zig"); // session-cwd paths for the resident companion daemon
const tool_balance = @import("tool_balance.zig"); // session-wide tool-class tally (/tools)
const ToolCall = tools.ToolCall;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const codedbGuard = tools.codedbGuard;
const companionRoute = tools.companionRoute;
const hookGate = tools.hookGate;
const runPostToolHooks = tools.runPostToolHooks;
const failure = tools.failure;
const strField = tools.strField;
const intField = tools.intField;
const missingArg = tools.missingArg;
const outsideCwd = tools.outsideCwd;
const beforeFromRead = tools.beforeFromRead; // /rewind snapshot classifier (snapshots.zig)
const blankText = tools.blankText;
const rawFetch = tools.rawFetch;
const bash_stdout_cap = tools.bash_stdout_cap;
const bash_stderr_cap = tools.bash_stderr_cap;
const webfetch_cap = tools.webfetch_cap;
const codedb_result_cap = tools.codedb_result_cap;

const subagent = @import("subagent.zig");
const execSubagent = subagent.execSubagent;
const agentOutput = subagent.agentOutput; // #276 P0-3
const workflow = @import("workflow.zig");
const execWorkflow = workflow.execWorkflow;

const mcp = @import("mcp.zig");
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const confinedPath = approvals_mod.confinedPath;
const noSymlinkEscape = approvals_mod.noSymlinkEscape;
const jobs = @import("jobs.zig");
const runCapped = jobs.runCapped;
const runCappedWithOptions = jobs.runCappedWithOptions;
const toolRunOptions = jobs.toolRunOptions; // #266/#198: own the child's process group
const spawnJob = jobs.spawnJob;
const jobOutput = jobs.jobOutput;
const jobKill = jobs.jobKill;
const shellArgv = jobs.shellArgv;
const skills = @import("skills.zig");
const skill_docs = @import("skill_docs.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // #416: refuse an MCP tool whose schema was never loaded
const read_file = @import("read_file.zig");
// #337: edit_file's verified write path, plus the file-tool helpers that moved
// out with it (this file is at the 600-line ceiling).
const edit_verify = @import("edit_verify.zig");
const edit_batch = @import("edit_batch.zig"); // batched edit_file spans (#476)
const fsErrorText = edit_verify.fsErrorText;
const preserveMode = edit_verify.preserveMode;
const hooks = @import("hooks.zig");
const telemetry = @import("telemetry.zig");
const learning_privacy = @import("learning_privacy.zig");
const no_local_tools = @import("no_local_tools.zig"); // #330: the hard --no-local-tools gate
const native_fold = @import("native_fold.zig"); // folded native power tools: layer-2 refusal until load_tool_schemas unfolds
const vision = @import("vision.zig"); // read_file stages images like MCP image results (#249)
const input_util = @import("input_util.zig");
const imagegen = @import("imagegen.zig"); // #352: the codex-gated image tool (advertising lives in schema.zig/tool_gates.zig)

/// Wall-clock ceiling for one *subagent* bash command. Subagents run on pool
/// threads with no TTY, so there is no Esc to kill a runaway command — without
/// this, a codedb refusal that pushes a subagent onto an unfiltered `grep ~/`
/// hangs the whole workflow for ~48 min (#93). The root keeps its Esc-only,
/// no-deadline behavior (a human is watching and may want a long build).
const subagent_bash_deadline_ms: u64 = 120 * 1000;

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

/// Wall-clock ceiling for one `codedb` query (#198). Every allowed subcommand
/// is a read that normally answers in seconds; a query that has not returned
/// in a minute is stuck, and before this it stayed stuck forever — the tool
/// blocked on EOF with no deadline at all.
const codedb_deadline_ms: u64 = 60 * 1000;

fn learningArgv(argv: *[10][]const u8, exe_path: []const u8, contribute: bool) usize {
    var argc: usize = 0;
    for ([_][]const u8{ exe_path, "--learning-privacy", if (contribute) "aggregate" else "local", "learn", "run" }) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    if (contribute) {
        argv[argc] = "--submit";
        argc += 1;
    }
    return argc;
}

/// Runs on a pool thread; never throws — failures become is_error results.
/// Every execution is timed (out.ms) and traced.
/// read_file on an image: stage the pixels on the registry's pending-image
/// slot — the same place MCP image results land (#249) — so the per-turn
/// handoff attaches them to the agent's next turn. Null means "fall back to
/// the generic binary-file error" (no registry, unreadable, over the ceiling).
fn stageReadFileImage(gpa: Allocator, io: Io, ctx: ToolCtx, resolved: []const u8, path: []const u8, size: u64) !?ToolOutput {
    const reg = ctx.registry orelse return null;
    if (size == 0 or size > 5 * 1024 * 1024) return null; // vision ceiling, same as stageImagePath
    const media_type = vision.imageMediaType(path);
    if (!vision.visionCapable(ctx.provider)) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — the active model does not accept images, so it was not attached]", .{ media_type, size }),
    };
    const data = Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(5 * 1024 * 1024)) catch return null;
    defer gpa.free(data);
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(data.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, data);
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    if (reg.pending_image != null) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — not attached: another image is already queued for the next turn]", .{ media_type, size }),
    };
    const arena = reg.arena();
    reg.pending_image = .{
        .media_type = try arena.dupe(u8, media_type),
        .b64 = try arena.dupe(u8, b64),
        .label = try arena.dupe(u8, path),
    };
    return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — attached to your next turn]", .{ media_type, size }),
    };
}

pub fn execTool(ctx: ToolCtx, call: ToolCall) ToolOutput {
    const t0: Io.Timestamp = .now(ctx.io, .awake);
    // #255: reserved before any gate/dispatch runs so tool_started/
    // tool_finished bracket the whole call, including a gate denial below.
    const call_id: u64 = if (ctx.tracer) |tr| tr.toolStarted(call.name, call.input) else 0;
    if (noLocalToolsGate(ctx, call) orelse codedbGuard(ctx, call) orelse companionRoute(ctx, call) orelse hookGate(ctx, call) orelse codedbpro_report.licensedGate(ctx, call) orelse native_fold.gateExec(ctx.gpa, call.name, ctx.from_sub)) |blocked| {
        var out = blocked;
        out.ms = t0.untilNow(ctx.io, .awake).toMilliseconds();
        if (ctx.tracer) |tr| {
            tr.tool(call.name, out.ms, true, out.text.len, ctx.from_sub);
            tr.toolFinished(call.name, call_id, out.ms, true, out.text.len);
        }
        if (ctx.tools_used) |ts| ts.add(ctx.io, ctx.gpa, call.name, true);
        return out;
    }
    var out = execToolInner(ctx, call) catch |err| blk: {
        // Harness-level tool failure (spawn error, OOM, broken pipe) — not a
        // tool that ran and returned is_error; those are normal agent
        // feedback and already counted in the session summary.
        var ebuf: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(&ebuf, "{s}: {t}", .{ call.name, err }) catch @errorName(err);
        if (telemetry.g_telem) |t| t.errorEvent("tool", detail);
        break :blk failure(ctx.gpa, err);
    };
    out.ms = t0.untilNow(ctx.io, .awake).toMilliseconds();
    if (ctx.tracer) |tr| {
        tr.tool(call.name, out.ms, out.is_error, out.text.len, ctx.from_sub);
        tr.toolFinished(call.name, call_id, out.ms, out.is_error, out.text.len);
    }
    if (ctx.tools_used) |ts| ts.add(ctx.io, ctx.gpa, call.name, out.is_error);
    // Session-wide class tally (/tools) — and when suite usage NEWLY skews,
    // the nudge rides this tool result so the model hears it, not just the
    // user's /tools view. Edge-triggered: a few per session at most. The
    // superseded out.text is deliberately NOT freed (it can be a static
    // empty slice; freeing it would corrupt) — a rare small abandonment.
    if (tool_balance.record(ctx.gpa, call, out.is_error)) |nudge| {
        defer ctx.gpa.free(nudge);
        out.text = std.fmt.allocPrint(ctx.gpa, "{s}\n\n[{s}]", .{ out.text, nudge }) catch out.text;
    }
    runPostToolHooks(ctx, call, out);
    return out;
}

/// #330 layer 2: refuse a host-touching built-in even if a provider hallucinates
/// one that was never advertised (layer 1 is schema.zig). FIRST in the guard
/// chain; an `mcp__*` name never matches, so the sandbox proxy keeps working.
fn noLocalToolsGate(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    if (!no_local_tools.blocks(call.name)) return null;
    const text = ctx.gpa.dupe(u8, no_local_tools.refusal_text) catch return .{ .text = &.{}, .is_error = true };
    return .{ .text = text, .is_error = true };
}

fn execToolInner(ctx: ToolCtx, call: ToolCall) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;

    // Plan mode backstop: the root gate already denies these with a nicer
    // message; this catches subagents (which skip the gate entirely).
    if (main_mod.plan_mode) {
        if (std.mem.eql(u8, call.name, "learn_candidate") or std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or std.mem.eql(u8, call.name, imagegen.tool_name) or mcp.Registry.isMcp(call.name)) return .{
            .text = try gpa.dupe(u8, "plan mode is on — read-only; describe the change instead of making it"),
            .is_error = true,
        };
        if (std.mem.eql(u8, call.name, "bash")) {
            if (strField(call.input, "command")) |cmd| if (!Approvals.readOnlyAllowed(cmd)) {
                // The root may have approved this external read-only path this
                // session (#64); subagents (from_sub) never get the external hatch.
                const ext_ok = !ctx.from_sub and if (ctx.approvals) |ap| ap.planReadAllowed(ctx.io, cmd) else false;
                if (!ext_ok) return .{
                    .text = try gpa.dupe(u8, "plan mode is on — only read-only commands run; describe this command in the plan instead"),
                    .is_error = true,
                };
            };
        }
    }

    if (mcp.Registry.isMcp(call.name)) {
        const reg = ctx.registry orelse return .{
            .text = try gpa.dupe(u8, "MCP not available in this context"),
            .is_error = true,
        };
        // #416 layer 2, auto-load era: a confident call to a deferred tool
        // loads its schema inline and runs — the refusal round trip is gone
        // (same user direction as the native fold). Still downstream of
        // agent_tool_gate.gateTool: consent is already settled.
        mcp_schema_gate.autoLoad(gpa, reg.tools, call.name);
        var prepared = codedbpro_paths.prepareInput(gpa, io, ctx.agent_cwd, call.name, call.input) catch |err| {
            codedbpro_report.onFailure(ctx, call.name, @errorName(err));
            return failure(gpa, err);
        };
        defer prepared.deinit(gpa);
        const r = reg.call(gpa, call.name, prepared.value) catch |err| {
            codedbpro_report.onFailure(ctx, call.name, @errorName(err));
            return failure(gpa, err);
        };
        if (r.is_error) codedbpro_report.onFailure(ctx, call.name, r.text);
        return .{ .text = r.text, .is_error = r.is_error };
    }

    const input = call.input;
    if (std.mem.eql(u8, call.name, "learn_candidate")) {
        if (ctx.from_sub) return .{
            .text = try gpa.dupe(u8, "learning is root-only — subagents cannot run mutators, evaluators, or publish grades"),
            .is_error = true,
        };
        const candidates = intField(input, "candidates");
        const repetitions = intField(input, "repetitions");
        if (candidates) |n| if (n < 1 or n > 16) return .{ .text = try gpa.dupe(u8, "candidates must be between 1 and 16"), .is_error = true };
        if (repetitions) |n| if (n < 1 or n > 100) return .{ .text = try gpa.dupe(u8, "repetitions must be between 1 and 100"), .is_error = true };
        const exe_path = try std.process.executablePathAlloc(io, gpa);
        defer gpa.free(exe_path);
        var candidates_buf: [20]u8 = undefined;
        var repetitions_buf: [20]u8 = undefined;
        var argv_buf: [10][]const u8 = undefined;
        const contribute = main_mod.g_fleet and (learning_privacy.allowsAggregate() or learning_privacy.consumeAggregateOnce(io));
        var argc = learningArgv(&argv_buf, exe_path, contribute);
        if (candidates) |n| {
            argv_buf[argc] = "--candidates";
            argv_buf[argc + 1] = try std.fmt.bufPrint(&candidates_buf, "{d}", .{n});
            argc += 2;
        }
        if (repetitions) |n| {
            argv_buf[argc] = "--repetitions";
            argv_buf[argc + 1] = try std.fmt.bufPrint(&repetitions_buf, "{d}", .{n});
            argc += 2;
        }
        const run = try runCapped(gpa, io, argv_buf[0..argc], 256 * 1024, 64 * 1024, 0);
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);
        const ok = run.term == .exited and run.term.exited == 0 and !run.timed_out;
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        if (run.stdout.len > 0) try aw.writer.writeAll(run.stdout);
        if (run.stdout_truncated) try aw.writer.writeAll("\n[learning output truncated]");
        if (run.stderr.len > 0) try aw.writer.print("\n[stderr]\n{s}", .{run.stderr});
        if (run.stderr_truncated) try aw.writer.writeAll("\n[learning stderr truncated]");
        if (run.stdout.len == 0 and run.stderr.len == 0) try aw.writer.writeAll(if (ok) "learning run completed" else "learning run failed without output");
        return .{ .text = try aw.toOwnedSlice(), .is_error = !ok };
    }
    if (std.mem.eql(u8, call.name, "bash")) {
        const cmd = strField(input, "command") orelse return missingArg(gpa, "command");
        // Subagents have no stdin to prompt on; their gate is the allowlist.
        if (ctx.from_sub) if (ctx.approvals) |ap| if (!ap.allowed(ctx.io, cmd)) return .{
            .text = try gpa.dupe(u8, "command not pre-approved — subagents may only run user-approved or read-only commands, with no chaining/pipes/redirection. Use read_file/edit_file/write_file, or report back what you need run."),
            .is_error = true,
        };
        const bg = tools.json_args.flag(input, "run_in_background");
        if (bg) {
            const job = spawnJob(gpa, io, cmd) catch |err| return .{
                // #122: backgrounding costs MORE fds (pipes + pump task), so the
                // generic "run it in the foreground" advice is right for every
                // error except the fd-quota ones — special-case those. #253: for
                // SYSTEM-wide exhaustion neither foregrounding nor ulimit helps.
                .text = if (err == error.ProcessFdQuotaExceeded)
                    try gpa.dupe(u8, "could not start background job (ProcessFdQuotaExceeded) — graff hit its open-file limit. Wait for running jobs/tools to finish, then retry with less parallel fan-out; if it recurs, raise the limit (`ulimit -n 4096`) before starting graff.")
                else if (err == error.SystemFdQuotaExceeded)
                    try gpa.dupe(u8, "could not start background job (SystemFdQuotaExceeded) — the SYSTEM-wide open-file table is full, so neither foregrounding nor `ulimit` helps. Wait for other processes to release files (or close some applications), then retry.")
                else
                    try std.fmt.allocPrint(gpa, "could not start background job ({t}) — run it in the foreground instead", .{err}),
                .is_error = true,
            };
            return .{ .text = try std.fmt.allocPrint(gpa, "[job {d} started: {s}]\nIt keeps running across turns. Poll new output with bash_output (id {d}, optional wait_ms), stop it with bash_kill.{s}", .{
                job.id,
                job.cmd,
                job.id,
                if (isSshCommand(cmd)) " Killing the local SSH job cannot prove a detached remote process stopped; verify the remote host." else "",
            }) };
        }
        const sh = shellArgv(cmd);
        const deadline: u64 = if (ctx.from_sub) subagent_bash_deadline_ms else 0;
        // #276 P0-1: a worktree-isolated agent's bash calls run pinned to its
        // own worktree — via std.process.Child.Cwd, per spawn, never a
        // process-wide chdir — so parallel siblings never share a cwd.
        // #266/#198: toolRunOptions also gives the command its own process
        // group, so an Esc cancel or the deadline kills what it spawned (ssh,
        // xcodebuild) instead of leaving it running against a dead turn.
        const run = try runCappedWithOptions(gpa, io, &sh, bash_stdout_cap, bash_stderr_cap, deadline, toolRunOptions(ctx.agent_cwd));
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);

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
            try w.writeAll("\n[cancelled by user; local process group killed]");
        } else if (run.timed_out) {
            try w.print("\n[timed out after {d}s and was killed — too long for a subagent. Don't retry as-is: scope it to specific paths or globs instead of scanning the whole directory, or report back what you need run.]", .{subagent_bash_deadline_ms / 1000});
        } else if (exit_code) |code| {
            if (code != 0) try w.print("\n[exit code {d}]", .{code});
        } else try w.writeAll("\n[terminated abnormally]");
        if ((run.cancelled or run.timed_out) and isSshCommand(cmd)) {
            try w.writeAll("\n[ssh note: the local SSH client was killed, but a detached or disconnect-resistant remote process may survive; verify it on the remote host]");
        }
        if (run.stdout.len == 0 and run.stderr.len == 0 and exit_code == 0) try w.writeAll("(no output)");
        return .{ .text = try aw.toOwnedSlice(), .is_error = exit_code == null or exit_code.? != 0, .cancelled = run.cancelled };
    }
    if (std.mem.eql(u8, call.name, "bash_output")) {
        const id = intField(input, "id") orelse return missingArg(gpa, "id");
        const wait_ms = intField(input, "wait_ms") orelse 0;
        if (id < 0 or id > std.math.maxInt(u32)) return .{ .text = try gpa.dupe(u8, "invalid job id"), .is_error = true };
        return jobOutput(gpa, io, @intCast(id), @intCast(@max(wait_ms, 0)));
    }
    if (std.mem.eql(u8, call.name, "bash_kill")) {
        const id = intField(input, "id") orelse return missingArg(gpa, "id");
        if (id < 0 or id > std.math.maxInt(u32)) return .{ .text = try gpa.dupe(u8, "invalid job id"), .is_error = true };
        return jobKill(gpa, io, @intCast(id));
    }
    if (std.mem.eql(u8, call.name, "webfetch")) {
        const url = strField(input, "url") orelse return missingArg(gpa, "url");
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return .{
            .text = try gpa.dupe(u8, "webfetch only handles absolute http:// and https:// URLs"),
            .is_error = true,
        };
        // kuri-preferred, never kuri-dependent: kuri-fetch converts HTML to
        // markdown, but its TLS stack rejects some servers and JS-rendered
        // SPAs come back blank — any failure or empty result falls through
        // to the harness's own HTTP client below.
        if (!skills.skillDisabled("kuri") and skills.binOnPath(io, "kuri-fetch")) kuri: {
            const run = runCapped(gpa, io, &.{ "kuri-fetch", "-q", "--no-color", url }, webfetch_cap, 4096, 0) catch break :kuri;
            defer {
                gpa.free(run.stdout);
                gpa.free(run.stderr);
            }
            if (run.term != .exited or run.term.exited != 0) break :kuri;
            if (blankText(run.stdout)) break :kuri; // SPA / conversion failure
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try aw.writer.writeAll(run.stdout);
            if (run.stdout_truncated) try aw.writer.print("\n[truncated at {d} KB]", .{webfetch_cap / 1024});
            return .{ .text = try aw.toOwnedSlice() };
        }
        return rawFetch(gpa, ctx.client, url);
    }
    if (std.mem.eql(u8, call.name, "read_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        if (!confinedPath(path) or !noSymlinkEscape(io, path, ctx.agent_cwd)) return outsideCwd(gpa, path);
        const start_line = intField(input, "start_line");
        const end_line = intField(input, "end_line");
        const contains = strField(input, "contains");
        const want_compact = tools.json_args.flag(input, "compact");
        if (contains) |needle| {
            if (needle.len == 0) return .{ .text = try gpa.dupe(u8, "read_file: contains must not be empty"), .is_error = true };
            if (start_line != null or end_line != null or want_compact) return .{ .text = try gpa.dupe(u8, "read_file: contains cannot be combined with start_line, end_line, or compact"), .is_error = true };
        }
        // #66: opt-in compact view routes to `codedb read <path> [-L a-b] --compact`
        // when codedb is present and this file is indexed. Lossy (strips comments/
        // blanks, shows line numbers) so it is NEVER the default and is labeled
        // not-for-editing; any failure falls through to the native byte-exact read.
        // #276: skipped entirely for a worktree-isolated agent — codedb's index is
        // built over the main checkout, not the scratch worktree, so a compact
        // read there could show stale or altogether wrong content.
        if (want_compact and ctx.agent_cwd == null) {
            if (main_mod.g_codedb_present == null) main_mod.g_codedb_present = skills.binOnPath(io, "codedb");
            if (main_mod.g_codedb_present == true and hooks.codedbFileIndexed(io, gpa, path)) {
                if (try codedbCompactRead(gpa, io, path, start_line, end_line)) |out| return out;
            }
        }
        // #276 P0-1: resolve under the agent's isolated worktree when set —
        // path itself stays relative (that's the agent's own view, used in
        // every message below); only the actual syscall targets the resolved
        // absolute path.
        const resolved: []const u8 = if (ctx.agent_cwd) |base| try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, path }) else path;
        defer if (ctx.agent_cwd != null) gpa.free(resolved);
        const outcome = read_file.read(io, gpa, .cwd(), resolved, start_line, end_line, contains) catch |err| {
            if (fsErrorText(gpa, .read, path, err)) |t| return .{ .text = t, .is_error = true };
            return err;
        };
        return switch (outcome) {
            .text => |text| .{ .text = text },
            .truncated => |value| blk: {
                defer gpa.free(value.head);
                break :blk .{ .text = try std.fmt.allocPrint(gpa, "{s}\n\n[read_file preview: {d}-byte file exceeds the {d} KiB whole-file limit; use start_line/end_line for byte-exact windows]", .{ util.utf8Prefix(value.head, value.head.len), value.total_bytes, read_file.max_bytes / 1024 }) };
            },
            .binary => |size| blk: {
                // An image is only "binary" to a text-only model: stage the
                // pixels exactly like an MCP image result (#249) so read_file
                // on a PNG/JPG/GIF/WebP attaches it to the next turn instead
                // of erroring out. Non-images keep the classic guidance.
                if (input_util.isImagePath(path)) {
                    if (try stageReadFileImage(gpa, io, ctx, resolved, path, size)) |out| break :blk out;
                }
                break :blk .{
                    .text = try std.fmt.allocPrint(gpa, "{s} is a binary file ({d} bytes) — read_file only handles text. Use bash instead (e.g. `file`, `strings`, `pdftotext`, `sips`, `unzip -l`).", .{ path, size }),
                    .is_error = true,
                };
            },
            .range_too_large => .{
                .text = try std.fmt.allocPrint(gpa, "read_file: requested range from {s} exceeds {d} KiB — request a narrower start_line/end_line window", .{ path, read_file.max_bytes / 1024 }),
                .is_error = true,
            },
            .start_past_end => .{
                .text = try std.fmt.allocPrint(gpa, "start_line {?d} is past the end of {s}", .{ start_line, path }),
                .is_error = true,
            },
            .no_match => .{
                .text = try std.fmt.allocPrint(gpa, "No lines in {s} contain the exact literal {s}.", .{ path, contains orelse "" }),
            },
        };
    }
    if (std.mem.eql(u8, call.name, "codedb")) {
        const cmd = strField(input, "command") orelse return missingArg(gpa, "command");
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        const sub = it.next() orelse return .{ .text = try gpa.dupe(u8, "usage: codedb <subcommand> [args] — e.g. search <q>, symbol <name>, callers <name>, outline <path>"), .is_error = true };
        // Allowlist read-only subcommands: never run the long-lived daemons
        // (serve/mcp) — they'd block this tool forever — or the destructive
        // ones (update/nuke).
        const ok_subs = [_][]const u8{ "search", "symbol", "callers", "find", "outline", "read", "tree", "context", "word", "deps", "glob", "ls", "file", "hot" };
        var allowed = false;
        for (ok_subs) |s| if (std.mem.eql(u8, s, sub)) {
            allowed = true;
        };
        if (!allowed) return .{ .text = try std.fmt.allocPrint(gpa, "codedb subcommand '{s}' is not allowed here — use one of: search, symbol, callers, find, outline, read, tree, context, word, deps, glob, ls, file, hot", .{sub}), .is_error = true };
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        argv.append(gpa, "codedb") catch {};
        argv.append(gpa, sub) catch {};
        while (it.next()) |tok| argv.append(gpa, tok) catch {};
        // #198: this used to spawn by hand and block until EOF — no deadline, no
        // process group, no Esc check — which is how abandoned sessions ended up
        // owning dozens of `codedb search` children still asleep days later. The
        // capped runner owns the group and tears it down on Esc or the deadline.
        const run = runCappedWithOptions(gpa, io, argv.items, 512 * 1024, 4096, codedb_deadline_ms, toolRunOptions(null)) catch |e| switch (e) {
            error.FileNotFound => return .{ .text = try gpa.dupe(u8, "codedb isn't installed — it's open source at github.com/justrach/codedb; install it, then run `codedb` once in the repo to index it"), .is_error = true },
            else => return failure(gpa, e),
        };
        gpa.free(run.stderr);
        const text = run.stdout;
        if (run.timed_out) {
            defer gpa.free(text);
            return .{ .text = try std.fmt.allocPrint(gpa, "codedb {s} timed out after {d}s and was killed — narrow the query, or run it through bash if it really needs that long", .{ sub, codedb_deadline_ms / 1000 }), .is_error = true };
        }
        if (text.len == 0) {
            defer gpa.free(text);
            return .{ .text = try gpa.dupe(u8, "(codedb returned nothing — try `codedb tree` to confirm the repo is indexed, or refine the query)") };
        }
        // #440: this used to truncate anything past 64 KB, because an unbounded
        // `read <big file>` once dumped 500KB into a subagent's context and
        // ballooned it to 160k tokens. The guard was right and its method was
        // destructive: the same 500KB now becomes a handle at tool time, so the
        // context is bounded harder than it ever was here AND the bytes survive
        // for a targeted read of the part that mattered.
        return .{ .text = text };
    }
    // #337: the read/splice/write/VERIFY path lives in edit_verify.zig, where
    // the post-edit check sits ON the success path — a write that did not land
    // can no longer be reported as `replaced N occurrence(s)`.
    if (std.mem.eql(u8, call.name, "edit_file")) return if (input == .object and input.object.get("edits") != null) edit_batch.execBatch(ctx, input) else edit_verify.execEdit(ctx, input);
    if (std.mem.eql(u8, call.name, "write_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        const content = strField(input, "content") orelse return missingArg(gpa, "content");
        if (!confinedPath(path) or !noSymlinkEscape(io, path, ctx.agent_cwd)) return outsideCwd(gpa, path);
        // #276 P0-1: resolve under the agent's isolated worktree when set.
        // (snapshots are root-only — `ctx.agent_cwd` is only ever set for a
        // subagent, so the branch below never runs together with isolation.)
        const resolved: []const u8 = if (ctx.agent_cwd) |base| try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, path }) else path;
        defer if (ctx.agent_cwd != null) gpa.free(resolved);
        // #337: a write_file racing an edit_file on the same path in the same
        // assistant turn (agent_tools.zig runs them concurrently) would drop
        // one of the two. Same stripe as edit_file, so they take turns.
        const lock = edit_verify.lockPath(io, resolved);
        defer lock.unlock(io);
        if (ctx.snapshots) |snaps| if (!ctx.from_sub) {
            // capture the prior content (or absence) before overwriting, for /rewind.
            // beforeFromRead keeps a merely UNREADABLE file (over the cap, permissions)
            // distinct from a missing one — only the latter is a rewind-deletes-it.
            const before = beforeFromRead(Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(4 * 1024 * 1024)));
            defer if (before == .content) gpa.free(before.content);
            snaps.record(path, before);
        };
        // #179: an existing file keeps its mode (e.g. 0755) across the overwrite;
        // a brand-new file (prev_stat == null) keeps the default.
        const prev_stat = Io.Dir.cwd().statFile(io, resolved, .{}) catch null;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = content }) catch |err| {
            if (fsErrorText(gpa, .write, path, err)) |t| return .{ .text = t, .is_error = true };
            return err;
        };
        preserveMode(io, resolved, prev_stat);
        return .{ .text = try std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ content.len, path }) };
    }
    // Loads one SKILL.md body (or lists them). Rescans on every call, so a
    // skill written this session is loadable without a restart.
    if (std.mem.eql(u8, call.name, "skill")) return skill_docs.execSkill(gpa, io, input);
    // #352: codex-gated. execImagegen answers a call that was never advertised
    // (an unavailable session) with the same honest error it gives the model.
    if (std.mem.eql(u8, call.name, imagegen.tool_name)) return imagegen.execImagegen(ctx, input);
    if (std.mem.eql(u8, call.name, "subagent")) return execSubagent(ctx, input);
    if (std.mem.eql(u8, call.name, "workflow")) return execWorkflow(ctx, input);
    if (std.mem.eql(u8, call.name, "agent_output")) {
        const id = intField(input, "id") orelse return missingArg(gpa, "id");
        const wait_ms = intField(input, "wait_ms") orelse 0;
        if (id < 0 or id > std.math.maxInt(u32)) return .{ .text = try gpa.dupe(u8, "invalid agent id"), .is_error = true };
        return agentOutput(gpa, io, @intCast(id), @intCast(@max(wait_ms, 0)));
    }
    return .{ .text = try std.fmt.allocPrint(gpa, "unknown tool: {s}", .{call.name}), .is_error = true };
}

/// Opt-in exploratory read via `codedb read <path> [-L a-b] --compact`. Lossy view
/// for reasoning only; returns null on any codedb failure so the caller falls back
/// to the native byte-exact read (#66).
fn codedbCompactRead(gpa: Allocator, io: Io, path: []const u8, start: ?i64, end: ?i64) !?ToolOutput {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var lbuf: [48]u8 = undefined;
    try argv.append(gpa, "codedb");
    try argv.append(gpa, "read");
    try argv.append(gpa, path);
    if (start != null and end != null and start.? >= 1 and end.? >= start.?) {
        try argv.append(gpa, "-L");
        try argv.append(gpa, std.fmt.bufPrint(&lbuf, "{d}-{d}", .{ start.?, end.? }) catch return null);
    }
    try argv.append(gpa, "--compact");
    const run = runCapped(gpa, io, argv.items, codedb_result_cap, 4096, 0) catch return null;
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    const ok = switch (run.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok or run.stdout.len == 0) return null;
    return ToolOutput{ .text = try std.fmt.allocPrint(gpa, "{s}\n[compact view — comments/blank lines stripped, line numbers shown; re-read WITHOUT compact before building an edit_file old_string]", .{run.stdout}) };
}

test "internal learning respects the parent privacy ceiling" {
    var argv: [10][]const u8 = undefined;
    var len = learningArgv(&argv, "graff", false);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "local", "learn", "run" }, argv[0..len]);
    len = learningArgv(&argv, "graff", true);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "aggregate", "learn", "run", "--submit" }, argv[0..len]);
}

test { // main.zig is at the 600-line cap; exec.zig is these modules' importer, so the compiled-in references live here (the reach check diffs the test binary, not which file holds the line)
    _ = @import("codedbpro_report.zig");
    _ = @import("tool_balance.zig");
}
