//! Tool dispatch: `execTool` (the timed/traced/hooked outer wrapper) and
//! `execToolInner` (the big per-tool-name switch — bash, bash_output,
//! bash_kill, webfetch, read_file, codedb, edit_file, write_file, subagent,
//! workflow, learn_candidate). Split out of main.zig (600-line goal); LAST in the tool-exec
//! region since it's the glue that imports tools.zig/subagent.zig/
//! workflow.zig as siblings, plus approvals.zig/mcp.zig/jobs.zig/skills.zig/
//! telemetry.zig. Back-imports main (as `main_mod`) for
//! `ToolCall`/`plan_mode` (pub-flipped) and `utf8Prefix`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const util = @import("util.zig");
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
const read_file = @import("read_file.zig");
const hooks = @import("hooks.zig");
const telemetry = @import("telemetry.zig");
const learning_privacy = @import("learning_privacy.zig");

/// Wall-clock ceiling for one *subagent* bash command. Subagents run on pool
/// threads with no TTY, so there is no Esc to kill a runaway command — without
/// this, a codedb refusal that pushes a subagent onto an unfiltered `grep ~/`
/// hangs the whole workflow for ~48 min (#93). The root keeps its Esc-only,
/// no-deadline behavior (a human is watching and may want a long build).
const subagent_bash_deadline_ms: u64 = 120 * 1000;

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
pub fn execTool(ctx: ToolCtx, call: ToolCall) ToolOutput {
    const t0: Io.Timestamp = .now(ctx.io, .awake);
    // #255: reserved before any gate/dispatch runs so tool_started/
    // tool_finished bracket the whole call, including a gate denial below.
    const call_id: u64 = if (ctx.tracer) |tr| tr.toolStarted(call.name, call.input) else 0;
    if (codedbGuard(ctx, call) orelse companionRoute(ctx, call) orelse hookGate(ctx, call)) |blocked| {
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
    runPostToolHooks(ctx, call, out);
    return out;
}

fn execToolInner(ctx: ToolCtx, call: ToolCall) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;

    // Plan mode backstop: the root gate already denies these with a nicer
    // message; this catches subagents (which skip the gate entirely).
    if (main_mod.plan_mode) {
        if (std.mem.eql(u8, call.name, "learn_candidate") or std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or mcp.Registry.isMcp(call.name)) return .{
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
        const r = try reg.call(gpa, call.name, call.input);
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
                // error except the fd-quota one — special-case that.
                .text = if (err == error.ProcessFdQuotaExceeded)
                    try gpa.dupe(u8, "could not start background job (ProcessFdQuotaExceeded) — graff hit its open-file limit. Wait for running jobs/tools to finish, then retry with less parallel fan-out; if it recurs, raise the limit (`ulimit -n 4096`) before starting graff.")
                else
                    try std.fmt.allocPrint(gpa, "could not start background job ({t}) — run it in the foreground instead", .{err}),
                .is_error = true,
            };
            return .{ .text = try std.fmt.allocPrint(gpa, "[job {d} started: {s}]\nIt keeps running across turns. Poll new output with bash_output (id {d}, optional wait_ms), stop it with bash_kill.", .{ job.id, job.cmd, job.id }) };
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
        if (run.timed_out) {
            try w.print("\n[timed out after {d}s and was killed — too long for a subagent. Don't retry as-is: scope it to specific paths or globs instead of scanning the whole directory, or report back what you need run.]", .{subagent_bash_deadline_ms / 1000});
        } else if (exit_code) |code| {
            if (code != 0) try w.print("\n[exit code {d}]", .{code});
        } else try w.writeAll("\n[terminated abnormally]");
        if (run.stdout.len == 0 and run.stderr.len == 0 and exit_code == 0) try w.writeAll("(no output)");
        return .{ .text = try aw.toOwnedSlice(), .is_error = exit_code == null or exit_code.? != 0 };
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
        const want_compact = tools.json_args.flag(input, "compact");
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
        const outcome = read_file.read(io, gpa, .cwd(), resolved, start_line, end_line) catch |err| {
            if (fsErrorText(gpa, .read, path, err)) |t| return .{ .text = t, .is_error = true };
            return err;
        };
        return switch (outcome) {
            .text => |text| .{ .text = text },
            .truncated => |value| blk: {
                defer gpa.free(value.head);
                break :blk .{ .text = try std.fmt.allocPrint(gpa, "{s}\n\n[read_file preview: {d}-byte file exceeds the {d} KiB whole-file limit; use start_line/end_line for byte-exact windows]", .{ util.utf8Prefix(value.head, value.head.len), value.total_bytes, read_file.max_bytes / 1024 }) };
            },
            .binary => |size| .{
                .text = try std.fmt.allocPrint(gpa, "{s} is a binary file ({d} bytes) — read_file only handles text. Use bash instead (e.g. `file`, `strings`, `pdftotext`, `sips`, `unzip -l`).", .{ path, size }),
                .is_error = true,
            },
            .range_too_large => .{
                .text = try std.fmt.allocPrint(gpa, "read_file: requested range from {s} exceeds {d} KiB — request a narrower start_line/end_line window", .{ path, read_file.max_bytes / 1024 }),
                .is_error = true,
            },
            .start_past_end => .{
                .text = try std.fmt.allocPrint(gpa, "start_line {?d} is past the end of {s}", .{ start_line, path }),
                .is_error = true,
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
        // Context guard: an unbounded `read <big file>` once dumped 500KB into
        // a subagent's context, ballooning it to 160k tokens and minutes-long
        // API calls. Cap what reaches the model and point it at targeted reads.
        if (text.len > codedb_result_cap) {
            defer gpa.free(text);
            const head = util.utf8Prefix(text, codedb_result_cap);
            return .{ .text = try std.fmt.allocPrint(gpa, "{s}\n[codedb output truncated at {d} KB — prefer targeted queries: outline <path>, symbol <name> --body, or search, instead of whole-file reads]", .{ head, codedb_result_cap / 1024 }) };
        }
        return .{ .text = text };
    }
    if (std.mem.eql(u8, call.name, "edit_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        const old = strField(input, "old_string") orelse return missingArg(gpa, "old_string");
        const new = strField(input, "new_string") orelse return missingArg(gpa, "new_string");
        if (!confinedPath(path) or !noSymlinkEscape(io, path, ctx.agent_cwd)) return outsideCwd(gpa, path);
        const all = tools.json_args.flag(input, "replace_all");
        if (old.len == 0) return .{ .text = try gpa.dupe(u8, "old_string must not be empty"), .is_error = true };

        // #276 P0-1: resolve under the agent's isolated worktree when set.
        const resolved: []const u8 = if (ctx.agent_cwd) |base| try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, path }) else path;
        defer if (ctx.agent_cwd != null) gpa.free(resolved);

        const data = Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(1024 * 1024)) catch |err| {
            if (fsErrorText(gpa, .edit, path, err)) |t| return .{ .text = t, .is_error = true };
            return err;
        };
        defer gpa.free(data);
        const count = std.mem.count(u8, data, old);
        if (count == 0) return .{
            .text = try std.fmt.allocPrint(gpa, "old_string not found in {s} — read_file it and match the existing text exactly", .{path}),
            .is_error = true,
        };
        if (count > 1 and !all) return .{
            .text = try std.fmt.allocPrint(gpa, "old_string matches {d} places in {s} — include more surrounding context to make it unique, or set replace_all", .{ count, path }),
            .is_error = true,
        };

        const replaced = try gpa.alloc(u8, std.mem.replacementSize(u8, data, old, new));
        defer gpa.free(replaced);
        _ = std.mem.replace(u8, data, old, new, replaced);
        if (ctx.snapshots) |snaps| if (!ctx.from_sub) snaps.record(path, data); // pre-edit content for /rewind
        // #179: capture the file's mode now so the atomic rewrite below can't drop
        // a 0755 executable bit down to the default 0644.
        const prev_stat = Io.Dir.cwd().statFile(io, resolved, .{}) catch null;
        // Premium splice: when the zigrep suite is installed, zigpatch does
        // the write — an atomic tmp+rename byte-level --all splice (our count
        // checks above already enforce the uniqueness semantics). Any
        // failure, including the tool simply not being on PATH, falls back
        // to the native in-place write below. zigpatch is a separate process
        // (`.inherit` cwd, #276) so it's handed `resolved` — an absolute path
        // when isolated — directly, rather than relying on its own cwd.
        zp: {
            const run = runCapped(gpa, io, &.{ "zigpatch", resolved, "-p", old, "--all", "--content", new }, 4096, 4096, 0) catch break :zp;
            defer {
                gpa.free(run.stdout);
                gpa.free(run.stderr);
            }
            const ok = switch (run.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok and std.mem.indexOf(u8, run.stdout, "\"ok\":true") != null) {
                preserveMode(io, resolved, prev_stat); // #179: zigpatch renamed a fresh inode into place
                return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s} (zigpatch)", .{ count, path }) };
            }
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = replaced });
        preserveMode(io, resolved, prev_stat); // #179: keep the pre-edit mode
        return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s}", .{ count, path }) };
    }
    if (std.mem.eql(u8, call.name, "write_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        const content = strField(input, "content") orelse return missingArg(gpa, "content");
        if (!confinedPath(path) or !noSymlinkEscape(io, path, ctx.agent_cwd)) return outsideCwd(gpa, path);
        // #276 P0-1: resolve under the agent's isolated worktree when set.
        // (snapshots are root-only — `ctx.agent_cwd` is only ever set for a
        // subagent, so the branch below never runs together with isolation.)
        const resolved: []const u8 = if (ctx.agent_cwd) |base| try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, path }) else path;
        defer if (ctx.agent_cwd != null) gpa.free(resolved);
        if (ctx.snapshots) |snaps| if (!ctx.from_sub) {
            // capture the prior content (or absence) before overwriting, for /rewind
            const before = Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(4 * 1024 * 1024)) catch null;
            defer if (before) |b| gpa.free(b);
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

/// The three native file tools, used to shape a filesystem-error message with
/// the tool's own name and the right recovery hint (#183).
const FileOp = enum {
    read,
    edit,
    write,
    fn tool(self: FileOp) []const u8 {
        return switch (self) {
            .read => "read_file",
            .edit => "edit_file",
            .write => "write_file",
        };
    }
};

/// Maps an EXPECTED filesystem error from a native file tool to a clear message
/// naming the tool, the supplied path, and the failure — so the model sees
/// "read_file: foo.zig does not exist" instead of a bare "error: FileNotFound"
/// (#183). Returns null for anything outside the usual path/permission set, so
/// the caller re-throws it onto the generic harness-failure path. Confinement,
/// symlink, and validation errors are already handled before the fs call and
/// never reach here. Caller owns the returned slice.
fn fsErrorText(gpa: Allocator, op: FileOp, path: []const u8, err: anyerror) ?[]u8 {
    return (switch (err) {
        // A missing target, or a non-directory used as a path component.
        error.FileNotFound, error.NotDir => switch (op) {
            .read => std.fmt.allocPrint(gpa, "read_file: {s} does not exist (paths are relative to the cwd) — check the name, or list the directory with bash `ls`", .{path}),
            .edit => std.fmt.allocPrint(gpa, "edit_file: {s} does not exist — edit_file only rewrites an existing file; use write_file to create it", .{path}),
            .write => std.fmt.allocPrint(gpa, "write_file: cannot create {s} — its parent directory does not exist; create it first with bash `mkdir -p`", .{path}),
        },
        error.IsDir => std.fmt.allocPrint(gpa, "{s}: {s} is a directory, not a file", .{ op.tool(), path }),
        error.AccessDenied, error.PermissionDenied => std.fmt.allocPrint(gpa, "{s}: permission denied for {s}", .{ op.tool(), path }),
        error.NoSpaceLeft => std.fmt.allocPrint(gpa, "write_file: no space left on device writing {s}", .{path}),
        else => return null,
    }) catch null;
}

/// Re-apply a file's saved permission bits after a rewrite. edit_file's atomic
/// zigpatch splice — and write_file overwriting an existing file — land the new
/// content on a fresh inode with the default 0644, silently dropping a 0755
/// executable bit; restore it (#179). `prev` is null for a brand-new file (keep
/// the default) or when the pre-write stat failed. Best-effort: a chmod failure
/// never fails the write itself.
fn preserveMode(io: Io, path: []const u8, prev: ?Io.Dir.Stat) void {
    const st = prev orelse return;
    Io.Dir.cwd().setFilePermissions(io, path, st.permissions, .{}) catch {};
}

test "fsErrorText names the tool, path, and failure (#183)" {
    const gpa = std.testing.allocator;

    const nf = fsErrorText(gpa, .read, "src/foo.zig", error.FileNotFound).?;
    defer gpa.free(nf);
    try std.testing.expect(std.mem.indexOf(u8, nf, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, nf, "src/foo.zig") != null);

    const ed = fsErrorText(gpa, .edit, "src/bar.zig", error.FileNotFound).?;
    defer gpa.free(ed);
    try std.testing.expect(std.mem.indexOf(u8, ed, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, ed, "write_file") != null); // points at creation

    const wr = fsErrorText(gpa, .write, "nope/out.txt", error.FileNotFound).?;
    defer gpa.free(wr);
    try std.testing.expect(std.mem.indexOf(u8, wr, "write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, wr, "parent") != null); // distinguishes a missing parent dir

    const perm = fsErrorText(gpa, .edit, "p", error.AccessDenied).?;
    defer gpa.free(perm);
    try std.testing.expect(std.mem.indexOf(u8, perm, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, perm, "permission") != null);

    // Errors outside the usual path/permission set fall through to the generic handler.
    try std.testing.expect(fsErrorText(gpa, .read, "p", error.OutOfMemory) == null);
}

test "internal learning respects the parent privacy ceiling" {
    var argv: [10][]const u8 = undefined;
    var len = learningArgv(&argv, "graff", false);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "local", "learn", "run" }, argv[0..len]);
    len = learningArgv(&argv, "graff", true);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "aggregate", "learn", "run", "--submit" }, argv[0..len]);
}
