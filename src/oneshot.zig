//! One-shot execution and durable supervisor result boundary.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const trace = @import("trace.zig");
const shapes = @import("shapes.zig");
const prompts = @import("prompts.zig");
const telemetry = @import("telemetry.zig");
const repl_glue = @import("repl_glue.zig");
const eval_memory = @import("eval_memory.zig");
const providers = @import("providers.zig");
const fleet = @import("fleet.zig");
const jobs = @import("jobs.zig");
const pricing = @import("pricing.zig");
const messages_mod = @import("messages.zig");
const session = @import("session.zig");
const title_mod = @import("title.zig");
const engine_sink = @import("engine_sink.zig");
const result = @import("headless_result.zig");

pub fn runOneshotPrompt(gpa: Allocator, io: Io, arena: Allocator, root: *agent_mod.Agent, keys: *provider_mod.Keys, tracer: *trace.Tracer, out: *Io.Writer, prompt_text: []const u8) !void {
    if (@import("goal_pacing.zig").oneshotSlashRefusal(prompt_text)) |why| std.process.fatal("{s}", .{why}); // usage error, not a prompt
    main_mod.unattended = true;
    @import("run_idle.zig").enabled = true; // nothing wakes a finished one-shot: wait for its background work
    @import("named_work.zig").rememberOn(root, prompt_text);
    root.in = null; // gate: deny instead of prompt; ask_user: self-decide
    root.out = if (main_mod.json_mode) out else null;
    root.stream_quiet = true;
    var run = result.Run.start(root);
    // stderr only: same class of "process is live" as Pi's JSONL session line.
    // Eval first_out used to wait for the call-2 stdout pulse (ADR 0046).
    std.debug.print("calling {s}\n", .{root.provider.model});
    const ultracode_msg = try shapes.applyUltracodeSteering(arena, prompt_text, prompt_text, prompts.ultracodeActive(root));
    if (ultracode_msg.explicit) {
        tracer.note("ultracode", prompt_text[0..@min(prompt_text.len, 120)]);
        if (telemetry.g_telem) |t| t.ultracode();
    }
    const goal_note = try repl_glue.goalSteeringNote(arena, root.goal);
    const eval_note = try repl_glue.evalSteeringNote(
        arena,
        root.eval_cmd,
        root.eval_target,
        root.eval_judge != null,
        root.eval_verified,
        root.eval_repair_pending,
        eval_memory.load(root),
    );
    var oneshot_user = if (goal_note.len > 0) try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ ultracode_msg.text, goal_note }) else ultracode_msg.text;
    if (eval_note.len > 0) oneshot_user = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ oneshot_user, eval_note });
    try root.messages.append(try @import("named_work.zig").userNudge(arena, root.provider.kind, oneshot_user));
    if (telemetry.g_telem) |t| t.beginTurn(@intCast(@min(prompt_text.len, std.math.maxInt(u32))), root.provider.model);
    // #502: --output-schema runs TWO-PHASE. A strict grammar on every message
    // pulls the model into answering immediately instead of touching tools
    // (graff-evals caught grok-4.6 guessing a file-inspection answer), so the
    // agentic phase runs unconstrained and one tools-off formatting turn then
    // restates the final answer under the schema — same conversation, so it
    // reads the real evidence.
    const pending_schema = root.output_schema;
    root.output_schema = null;
    var final_text = providers.runTurnWithFallback(root, keys, arena, null) catch |err| {
        // std.process.fatal does not unwind main's defers. Mirror their order:
        // join the fleet, reap jobs/pumps, then the terminal behavioral event.
        fleet.joinElites(io);
        jobs.jobsReap(gpa, io);
        @import("subagent.zig").agentJobsReap(gpa, io);
        // Flush buffered OTLP too: a fatal one-shot stays visible in ordinary telemetry.
        if (telemetry.g_telem) |t| t.flush();
        if (tracer.behavior) |behavior| behavior.finish(.failed);
        pricing.printUsageFooter(io);
        @import("turn_dedup.zig").settleFailedTurn(root, arena, err) catch {}; // #1729: a resumed retry is a new ask
        const saved = save(root, arena);
        const detail = root.last_api_error orelse @errorName(err);
        const failure = result.classify(err, detail);
        run.finish(root, failure, detail, saved);
        if (root.tools_used.count() > 0) std.debug.print("note: {d} tool call(s) completed before the failure; their work was not rolled back\n", .{root.tools_used.count()});
        std.debug.print("turn failed ({s}): {s}\n", .{ failure.reason, detail });
        @import("orchestration_rows.zig").flushPending(0, if (root.run_budget) |b| b.used() else 0, 0, false, "");
        std.process.exit(failure.exit_code);
    };
    const had_schema = pending_schema != null;
    if (pending_schema) |schema_json| {
        root.output_schema = schema_json;
        // Gemini (via the gateway) accepts json_schema then ignores it, so the
        // #543 sox path never learns. Force schema-in-prompt + structured_output.
        if (std.mem.startsWith(u8, root.provider.model, "gemini")) root.sox_json_object = true;
        root.text_only = true;
        defer {
            root.text_only = false;
            root.output_schema = null;
        }
        try root.messages.append(try messages_mod.textMessage(arena, "user", "Return ONLY the final answer matching the enforced output schema: call the structured_output tool if it is offered, otherwise reply with a single JSON object. No prose."));
        if (telemetry.g_telem) |t| t.countTurn();
        run.turns += 1;
        final_text = providers.runTurnWithFallback(root, keys, arena, null) catch blk: {
            // Best-effort: schema-shaping must never lose a finished answer.
            std.debug.print("warning: output-schema formatting call failed — printing the unshaped answer\n", .{});
            break :blk final_text;
        };
    }
    const answer = if (had_schema) unwrapFencedJson(final_text) else final_text;
    // Live -p deltas already rode stdout (`printDelta`); reprinting would
    // duplicate the answer and push first_out to the footer.
    if (!main_mod.json_mode) {
        if (!root.streamed_text) try out.print("{s}\n", .{answer}) else try out.writeAll("\n");
    }
    try out.flush();
    // Usage summary → stderr, so stdout stays exactly the answer.
    pricing.printUsageFooter(io);
    const saved = save(root, arena);
    const incomplete: ?result.Failure = if (root.run_budget != null and (root.run_budget.?.tool_exhausted.load(.acquire) or root.run_budget.?.model_landed.load(.acquire)))
        .{ .reason = "budget_exhausted", .exit_code = 3 }
    else if (root.eval_repair_pending or root.yielded != null or @import("subagent_interactive.zig").yielded or @import("goal_state.zig").openCount(root.todos.items, @import("goal_state.zig").currentEpoch(root.goal)) > 0)
        .{ .reason = "unfinished_work", .exit_code = 2 }
    else if (std.mem.endsWith(u8, answer, "\n\n" ++ @import("agent_model_loop.zig").marker))
        .{ .reason = "model_loop", .exit_code = 2 }
    else if (!saved) .{ .reason = "session_save_failed", .exit_code = 1 } else null;

    // --worktree: checkpoint the one-shot's edits to the scratch branch too.
    // Headless swarm agents (graff -w name -p "task") are the main -w use
    // case — they must not exit with their work left uncommitted.
    jobs.worktreeAutoCommit(gpa, io, std.fmt.allocPrint(arena, "wip: {s}", .{title_mod.titleFromPrompt(prompt_text)}) catch "wip: graff oneshot");
    // One-shot returns here, before the REPL cleanup defer below is even
    // registered, so free the root's gpa-backed buffers explicitly (else a
    // tool-using one-shot leaks its tool log / render buffers on exit).
    @import("subagent.zig").agentJobsReap(gpa, io);
    @import("agent_render_cleanup.zig").deinit(root);
    root.tools_used.deinit(gpa);
    // Presence announced this session at boot (#469); a one-shot returns
    // before finalizeSession, so retire + free its gpa-owned globals here or
    // they reach the exit-time leak check — and our record would linger in
    // the registry until a peer's liveness probe reaps it.
    @import("session_globals.zig").release(gpa, io);
    // #396: the run is over. The frontend hands the terminal back and latches
    // its reader shut before main()'s teardown — a terminal-ownership move the
    // sink owns now, in EVERY mode, exactly as the old unconditional call did.
    engine_sink.writerSink(out).emit(io, .run_finished);
    run.finish(root, incomplete, answer, saved);
    if (incomplete) |f| std.process.exit(f.exit_code);
}

fn save(root: *agent_mod.Agent, arena: Allocator) bool {
    session.saveSession(root, arena, root.session_name) catch |err| {
        std.debug.print("⚠ session save failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

fn unwrapFencedJson(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;
    var rest = trimmed[3..];
    if (std.mem.startsWith(u8, rest, "json")) rest = rest[4..];
    rest = std.mem.trimStart(u8, rest, " \t\r\n");
    if (std.mem.lastIndexOf(u8, rest, "```")) |end| return std.mem.trim(u8, rest[0..end], " \t\r\n");
    return rest;
}

test "unwrapFencedJson strips a markdown fence and leaves bare JSON alone" {
    try std.testing.expectEqualStrings("{\"a\":1}", unwrapFencedJson("```json\n{\"a\":1}\n```\n"));
    try std.testing.expectEqualStrings("{\"a\":1}", unwrapFencedJson("{\"a\":1}"));
}

test "one-shot and --json do not auto-init a learning store" {
    try std.testing.expect(!@import("session_run.zig").shouldAutoLearn(true, false));
    try std.testing.expect(!@import("session_run.zig").shouldAutoLearn(false, true));
    try std.testing.expect(!@import("session_run.zig").shouldAutoLearn(true, true));
    try std.testing.expect(@import("session_run.zig").shouldAutoLearn(false, false));
}
