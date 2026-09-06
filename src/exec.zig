//! Tool dispatch: `execTool` + `execToolInner`. Split out of main.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const util = @import("util.zig");
const codedbpro_report = @import("codedbpro_report.zig"); // licensed-companion failure → redacted issue filer
const tool_surface = @import("tool_surface.zig"); // companion-write gate + licensed hide
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
const webfetch_cap = tools.webfetch_cap;

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
const jobOutput = jobs.jobOutput;
const jobKill = jobs.jobKill;
const exec_bash = @import("exec_bash.zig");
const skills = @import("skills.zig");
const skill_docs = @import("skill_docs.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // #416: refuse an MCP tool whose schema was never loaded
const read_file = @import("read_file.zig");
const result_read = @import("result_read.zig");
const codedb_exec = @import("codedb_exec.zig"); // native codedb dispatch (list_dir / status / one-shots)
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
const local_tools = @import("local_tools.zig");

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
    if (noLocalToolsGate(ctx, call) orelse codedbGuard(ctx, call) orelse companionRoute(ctx, call) orelse hookGate(ctx, call) orelse codedbpro_report.licensedGate(ctx, call) orelse tool_surface.gate(ctx, call) orelse native_fold.gateExec(ctx.gpa, call.name, ctx.from_sub)) |blocked| {
        var out = blocked;
        out.ms = t0.untilNow(ctx.io, .awake).toMilliseconds();
        if (ctx.tracer) |tr| {
            tr.tool(call.name, call_id, out.ms, true, out.text.len, ctx.from_sub);
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
        tr.tool(call.name, call_id, out.ms, out.is_error, out.text.len, ctx.from_sub);
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
    if (no_local_tools.enabled and local_tools.isLocal(call.name)) {
        const text = ctx.gpa.dupe(u8, no_local_tools.refusal_text) catch return .{ .text = &.{}, .is_error = true };
        return .{ .text = text, .is_error = true };
    }
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
        if (local_tools.isLocal(call.name) or std.mem.eql(u8, call.name, "learn_candidate") or std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file") or std.mem.eql(u8, call.name, imagegen.tool_name) or mcp.Registry.isMcp(call.name)) return .{
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
        if (!r.is_error) {
            const shapes = @import("mcp_shapes.zig");
            shapes.remember(ctx, call.name, r.text);
            return .{ .text = shapes.takeSlim(gpa, r.text), .is_error = false };
        }
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
    if (std.mem.eql(u8, call.name, "bash")) return exec_bash.exec(ctx, call);
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
    if (std.mem.eql(u8, call.name, result_read.tool_name)) return result_read.exec(ctx, call);
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
        if (want_compact) {
            if (try codedb_exec.maybeCompactRead(ctx, path, start_line, end_line)) |out| return out;
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
    if (std.mem.eql(u8, call.name, "codedb")) return codedb_exec.exec(ctx, input);
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
    if (std.mem.eql(u8, call.name, @import("rlm.zig").tool_name)) return @import("rlm.zig").exec(ctx, input);
    if (local_tools.isLocal(call.name)) return local_tools.exec(gpa, io, call.name, input);
    if (std.mem.eql(u8, call.name, "agent_output")) {
        const id = intField(input, "id") orelse return missingArg(gpa, "id");
        const wait_ms = intField(input, "wait_ms") orelse 0;
        if (id < 0 or id > std.math.maxInt(u32)) return .{ .text = try gpa.dupe(u8, "invalid agent id"), .is_error = true };
        return agentOutput(gpa, io, @intCast(id), @intCast(@max(wait_ms, 0)));
    }
    return .{ .text = try std.fmt.allocPrint(gpa, "unknown tool: {s}", .{call.name}), .is_error = true };
}

test "preserveMode restores bits via handle chmod so Windows cannot panic (#179/#606)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x.sh", .data = "a" });
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(io, "x.sh", Io.File.Permissions.fromMode(0o755), .{});
    }
    const st = try tmp.dir.statFile(io, "x.sh", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "x.sh", .data = "b" });
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &real_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/x.sh", .{real_buf[0..n]});
    defer std.testing.allocator.free(path);
    preserveMode(io, path, st);
    if (builtin.os.tag != .windows) {
        const after = try tmp.dir.statFile(io, "x.sh", .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), after.permissions.toMode() & 0o777);
    }
}

test "internal learning respects the parent privacy ceiling" {
    var argv: [10][]const u8 = undefined;
    var len = learningArgv(&argv, "graff", false);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "local", "learn", "run" }, argv[0..len]);
    len = learningArgv(&argv, "graff", true);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "aggregate", "learn", "run", "--submit" }, argv[0..len]);
}

test { // main.zig is at the 600-line cap; exec.zig is these modules' importer, so the compiled-in references live here (the reach check diffs the test binary, not which file holds the line)
    _ = exec_bash;
    _ = @import("codedbpro_report.zig");
    _ = @import("tool_balance.zig");
    _ = @import("codedb_exec.zig");
    _ = @import("codedb_around.zig");
    _ = @import("codedb_health.zig");
    _ = @import("list_dir.zig");
    _ = @import("list_dir_nearmiss.zig"); // not-found hints
    _ = @import("repo_map.zig"); // breadth-first Project layout selection
    _ = @import("rlm.zig");
    _ = @import("rlm_spec.zig");
    _ = @import("rlm_query.zig");
    _ = @import("rlm_mcp.zig");
    _ = @import("rlm_reduce.zig");
    _ = @import("rlm_tests.zig");
    _ = @import("native_fold_rlm.zig");
    _ = @import("mcp_shapes.zig");
    _ = @import("spec_ptc.zig");
    _ = @import("xai_hosted.zig");
}
