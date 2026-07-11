//! Tool dispatch: `execTool` (the timed/traced/hooked outer wrapper) and
//! `execToolInner` (the big per-tool-name switch — bash, bash_output,
//! bash_kill, webfetch, read_file, codedb, edit_file, write_file, subagent,
//! workflow). Split out of main.zig (600-line goal); LAST in the tool-exec
//! region since it's the glue that imports tools.zig/subagent.zig/
//! workflow.zig as siblings, plus approvals.zig/mcp.zig/jobs.zig/skills.zig/
//! input_util.zig/telemetry.zig. Back-imports main (as `main_mod`) for
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
const workflow = @import("workflow.zig");
const execWorkflow = workflow.execWorkflow;

const mcp = @import("mcp.zig");
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const confinedPath = approvals_mod.confinedPath;
const noSymlinkEscape = approvals_mod.noSymlinkEscape;
const jobs = @import("jobs.zig");
const runCapped = jobs.runCapped;
const spawnJob = jobs.spawnJob;
const jobOutput = jobs.jobOutput;
const jobKill = jobs.jobKill;
const shellArgv = jobs.shellArgv;
const skills = @import("skills.zig");
const input_util = @import("input_util.zig");
const binaryFileExt = input_util.binaryFileExt;
const telemetry = @import("telemetry.zig");

/// Wall-clock ceiling for one *subagent* bash command. Subagents run on pool
/// threads with no TTY, so there is no Esc to kill a runaway command — without
/// this, a codedb refusal that pushes a subagent onto an unfiltered `grep ~/`
/// hangs the whole workflow for ~48 min (#93). The root keeps its Esc-only,
/// no-deadline behavior (a human is watching and may want a long build).
const subagent_bash_deadline_ms: u64 = 120 * 1000;

/// Runs on a pool thread; never throws — failures become is_error results.
/// Every execution is timed (out.ms) and traced.
pub fn execTool(ctx: ToolCtx, call: ToolCall) ToolOutput {
    const t0: Io.Timestamp = .now(ctx.io, .awake);
    if (codedbGuard(ctx, call) orelse companionRoute(ctx, call) orelse hookGate(ctx, call)) |blocked| {
        var out = blocked;
        out.ms = t0.untilNow(ctx.io, .awake).toMilliseconds();
        if (ctx.tracer) |tr| tr.tool(call.name, out.ms, true, out.text.len, ctx.from_sub);
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
    if (ctx.tracer) |tr| tr.tool(call.name, out.ms, out.is_error, out.text.len, ctx.from_sub);
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
        if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or mcp.Registry.isMcp(call.name)) return .{
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
    if (std.mem.eql(u8, call.name, "bash")) {
        const cmd = strField(input, "command") orelse return missingArg(gpa, "command");
        // Subagents have no stdin to prompt on; their gate is the allowlist.
        if (ctx.from_sub) if (ctx.approvals) |ap| if (!ap.allowed(ctx.io, cmd)) return .{
            .text = try gpa.dupe(u8, "command not pre-approved — subagents may only run user-approved or read-only commands, with no chaining/pipes/redirection. Use read_file/edit_file/write_file, or report back what you need run."),
            .is_error = true,
        };
        const bg = if (input == .object) (if (input.object.get("run_in_background")) |v| v == .bool and v.bool else false) else false;
        if (bg) {
            const job = spawnJob(gpa, io, cmd) catch |err| return .{
                .text = try std.fmt.allocPrint(gpa, "could not start background job ({t}) — run it in the foreground instead", .{err}),
                .is_error = true,
            };
            return .{ .text = try std.fmt.allocPrint(gpa, "[job {d} started: {s}]\nIt keeps running across turns. Poll new output with bash_output (id {d}, optional wait_ms), stop it with bash_kill.", .{ job.id, job.cmd, job.id }) };
        }
        const sh = shellArgv(cmd);
        const run = try runCapped(gpa, io, &sh, bash_stdout_cap, bash_stderr_cap, if (ctx.from_sub) subagent_bash_deadline_ms else 0);
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
        if (!confinedPath(path) or !noSymlinkEscape(io, path)) return outsideCwd(gpa, path);
        const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024));
        // Binary guard: PDFs/images/archives would only poison the context
        // with mojibake — point the model at bash converters instead.
        if (binaryFileExt(path) or std.mem.indexOfScalar(u8, data[0..@min(data.len, 4096)], 0) != null) {
            defer gpa.free(data);
            return .{ .text = try std.fmt.allocPrint(gpa, "{s} is a binary file ({d} bytes) — read_file only handles text. Use bash instead (e.g. `file`, `strings`, `pdftotext`, `sips`, `unzip -l`).", .{ path, data.len }), .is_error = true };
        }
        return .{ .text = data };
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
        var child = std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch {
            return .{ .text = try gpa.dupe(u8, "codedb isn't installed — it's open source at github.com/justrach/codedb; install it, then run `codedb` once in the repo to index it"), .is_error = true };
        };
        const out_file = child.stdout orelse return .{ .text = try gpa.dupe(u8, "codedb: no output stream"), .is_error = true };
        var rbuf: [4096]u8 = undefined;
        var fr = out_file.readerStreaming(io, &rbuf);
        const text = fr.interface.allocRemaining(gpa, .limited(512 * 1024)) catch |e| return failure(gpa, e);
        _ = child.wait(io) catch {};
        if (text.len == 0) return .{ .text = try gpa.dupe(u8, "(codedb returned nothing — try `codedb tree` to confirm the repo is indexed, or refine the query)") };
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
        if (!confinedPath(path) or !noSymlinkEscape(io, path)) return outsideCwd(gpa, path);
        const all = if (input.object.get("replace_all")) |v| v == .bool and v.bool else false;
        if (old.len == 0) return .{ .text = try gpa.dupe(u8, "old_string must not be empty"), .is_error = true };

        const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
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
        // Premium splice: when the zigrep suite is installed, zigpatch does
        // the write — an atomic tmp+rename byte-level --all splice (our count
        // checks above already enforce the uniqueness semantics). Any
        // failure, including the tool simply not being on PATH, falls back
        // to the native in-place write below.
        zp: {
            const run = runCapped(gpa, io, &.{ "zigpatch", path, "-p", old, "--all", "--content", new }, 4096, 4096, 0) catch break :zp;
            defer {
                gpa.free(run.stdout);
                gpa.free(run.stderr);
            }
            const ok = switch (run.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok and std.mem.indexOf(u8, run.stdout, "\"ok\":true") != null)
                return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s} (zigpatch)", .{ count, path }) };
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = replaced });
        return .{ .text = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s}", .{ count, path }) };
    }
    if (std.mem.eql(u8, call.name, "write_file")) {
        const path = strField(input, "path") orelse return missingArg(gpa, "path");
        const content = strField(input, "content") orelse return missingArg(gpa, "content");
        if (!confinedPath(path) or !noSymlinkEscape(io, path)) return outsideCwd(gpa, path);
        if (ctx.snapshots) |snaps| if (!ctx.from_sub) {
            // capture the prior content (or absence) before overwriting, for /rewind
            const before = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch null;
            defer if (before) |b| gpa.free(b);
            snaps.record(path, before);
        };
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
        return .{ .text = try std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ content.len, path }) };
    }
    if (std.mem.eql(u8, call.name, "subagent")) return execSubagent(ctx, input);
    if (std.mem.eql(u8, call.name, "workflow")) return execWorkflow(ctx, input);
    return .{ .text = try std.fmt.allocPrint(gpa, "unknown tool: {s}", .{call.name}), .is_error = true };
}
