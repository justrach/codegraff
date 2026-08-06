//! Root interactive/JSON event loop. `main` owns setup and storage; `Ctx` holds
//! borrowed pointers valid until `run` returns for final session cleanup.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const util = @import("util.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");

const ansi = @import("ansi.zig");
const style = &ansi.style;

const pricing = @import("pricing.zig");
const prompts = @import("prompts.zig");
const providers = @import("providers.zig");
const pickers = @import("pickers.zig");
const fleet = @import("fleet.zig");
const jobs = @import("jobs.zig");
const session = @import("session.zig");
const repl_glue = @import("repl_glue.zig");
const goal_state = @import("goal_state.zig");
const goal_flow = @import("goal_flow.zig");
const goal_pacing = @import("goal_pacing.zig");
const eval_memory = @import("eval_memory.zig");
const json_controls = @import("json_controls.zig"); // #415: the --json controls that never become a turn
const mainloop_score = @import("mainloop_score.zig");
const mainloop_trace = @import("mainloop_trace.zig");
const scoring = @import("scoring.zig");
const trace = @import("trace.zig");
const telemetry = @import("telemetry.zig");
const vision = @import("vision.zig");
const messages = @import("messages.zig");
const anim = @import("anim.zig");
const hooks = @import("hooks.zig");
const readline = @import("readline.zig");
const title_mod = @import("title.zig");
const mainloop_title = @import("mainloop_title.zig");
const review = @import("review.zig");
const terminal = @import("term.zig");

/// Borrowed pointers into main()'s stack plus immutable arena-owned prompt slices.
pub const Ctx = struct {
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    out: *Io.Writer,
    in: *Io.Reader,
    history: *std.ArrayList([]const u8),
    linebuf: *std.ArrayList(u8),
    interactive: bool,
    sys_normal: []const u8, // startup-composed BASE; set_agent's reset-to-original path re-derives from this via prompts.setSystemPrompts() (#326)
};

/// Run turns until EOF/quit; main then performs final save/worktree cleanup.
pub fn run(ctx: *Ctx) !void {
    var title_jobs: mainloop_title.Jobs = .{};
    defer title_jobs.deinit(ctx);
    defer session.flushSavesAtExit(); // #273: the turn-path autosaves write in the background — no queued one may outlive this loop, on ANY exit (#364 stamps this teardown phase)
    defer ctx.root.closeCodexWs(); // #424: the held WS + response-id anchor deliberately span turns, so only loop exit may free them — without this they are the gpa's only exit leaks
    defer terminal.tty.releaseTerminal(); // #396: registered LAST so LIFO runs it FIRST — the tty goes back before the save/telemetry/learning phases that can take seconds
    // Trajectory spine: each turn's parent is the previous; a changed prompt fingerprint marks a set_system_prompt edge.
    var prev_turn_id: u64 = 0;
    var prev_prompt_fp: [16]u8 = scoring.promptFingerprint(ctx.root.systemPrompt());

    // Armed only after a clean /loop turn and consumed by the next read (#226).
    const loop_iter_cap: u32 = 25; // hard per-/loop iteration bound (never-completing-model guard)
    var loop_iters_left: u32 = 0; // continuation turns still authorized this /loop run
    var loop_continue_armed = false; // a continuation turn is queued for the next readline
    var loop_list: goal_flow.LoopListGate = .{}; // diff-gate for the checklist copy in continuation prompts (#318)
    var loop_clock: goal_pacing.LoopClock = .{}; // this run's wall clock: `/loop 30m <prompt>` arms a deadline, and every continuation is told where it stands

    while (true) {
        // Titles can land between interactions but never join the response path.
        title_jobs.poll(ctx);
        // Drain streamed follow-ups before reading fresh input (empty in JSON/GUI).
        repl_glue.resetSteerPartial();
        const steer_entry: ?repl_glue.SteerEntry = repl_glue.popSteer();
        defer if (steer_entry) |e| std.heap.page_allocator.free(e.text);
        var is_loop_continuation = false; // #226: this iteration is an autonomous /loop continuation turn
        const raw_line: []const u8 = if (steer_entry) |e| blk: {
            loop_iters_left = 0; // #226: a user steer/force cancels the autonomous /loop run
            loop_continue_armed = false;
            loop_list.reset();
            loop_clock.clear(ctx.root); // and its deadline stops reaching subagents
            if (e.force) {
                try ctx.out.print("{s}↳ force ›{s} {s}\n", .{ style.yellow, style.reset, e.text });
            } else {
                try ctx.out.print("{s}↳ steer ›{s} {s}\n", .{ style.accent, style.reset, e.text });
            }
            try ctx.out.flush();
            break :blk e.text;
        } else if (loop_continue_armed) blk: {
            // #226: autonomous /loop continuation — synthesize the next turn from the
            // continuation steering note instead of reading a new user line. Consumed
            // here, so an interrupted/errored turn does not resume the loop.
            loop_continue_armed = false;
            is_loop_continuation = true;
            // Gated: these prompts persist in root.messages, autosave, and are
            // compaction input, so the current epoch's list is pasted only when
            // it changed or a history rewrite destroyed the pasted copies (#318).
            const note = try loop_list.note(ctx.arena, ctx.root);
            const pace = try goal_pacing.pacingNote(ctx.arena, util.unixMs(ctx.io), loop_clock, loop_iter_cap - loop_iters_left, loop_iter_cap);
            break :blk try std.fmt.allocPrint(ctx.arena, "/loop {s}\n{s}", .{ note, pace });
        } else if (ctx.interactive) blk: {
            try ctx.root.prompt();
            break :blk (try readline.readLine(ctx.root, ctx.in, ctx.out, ctx.gpa, ctx.history, ctx.linebuf)) orelse break;
        } else (try ctx.in.takeDelimiter('\n')) orelse break;
        // The title may have completed while readline was waiting. Apply it
        // before starting the newly-entered turn, still without ever waiting.
        title_jobs.poll(ctx);
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        // `/goal [30m] <objective>` and `/loop [30m] <prompt>` are ONE autonomous run: same
        // plan-act-verify machine, same controller, same optional wall clock. Only /goal also
        // adopts a standing objective (goal_pacing.autonomousFromLine).
        const goal_objective: ?[]const u8 = if (main_mod.json_mode) null else repl_glue.goalPromptFromLine(line);
        const auto: ?goal_pacing.Autonomous = if (main_mod.json_mode) null else try goal_pacing.autonomousFromLine(ctx.arena, line, goal_objective);
        const loop_prompt: ?[]const u8 = if (auto) |a| a.prompt else null;
        // A fresh line starts (or ends) a run: the wall clock begins here, stale todos_dirty is
        // dropped (a checklist finished BEFORE this prompt ended the next run at iteration 1, #318),
        // and an armed budget is echoed - a silently-eaten "5m" reads exactly like a truncated prompt.
        if (!is_loop_continuation) try goal_pacing.armAndAnnounce(&loop_clock, ctx.root, ctx.out, ctx.arena, util.unixMs(ctx.io), if (auto) |a| a.budget() else null);
        var review_prompt: ?[]const u8 = if (!main_mod.json_mode) review.promptFromLine(line) else null;
        if (!main_mod.json_mode) {
            const l = if (line.len > 0 and line[0] == '/') line[1..] else line;
            if (std.mem.eql(u8, l, "exit") or std.mem.eql(u8, l, "quit") or std.mem.eql(u8, l, "q")) break;
        }

        if (!main_mod.json_mode and repl_glue.isSlashCommandLine(line) and auto == null and review_prompt == null) {
            // Bare "/" on a TTY: open the filterable command menu.
            if (ctx.interactive and line.len == 1) {
                if (pickers.listPicker(ctx.root, ctx.arena, ctx.out, "Command ›", &pickers.command_menu)) |idx| {
                    try main_mod.handleCommand(ctx.root, ctx.keys, ctx.arena, pickers.command_menu[idx].name, ctx.out);
                }
                continue;
            }
            try main_mod.handleCommand(ctx.root, ctx.keys, ctx.arena, line, ctx.out);
            continue;
        }

        // /goal <objective>: adopt the standing goal first (handleCommand sets
        // root.goal, saves, prints), then run it on the autonomous machine below.
        if (auto) |a| if (a.goal_line) |gl| try main_mod.handleCommand(ctx.root, ctx.keys, ctx.arena, gl, ctx.out);

        // JSON lines may run a user turn, mutate the system prompt, or append a score.
        var json_request: ?std.json.Parsed(Value) = null;
        defer if (json_request) |*request| request.deinit();
        const base_msg: []const u8 = if (review_prompt) |rp| rp else if (loop_prompt) |lp| lp else if (main_mod.json_mode) blk: {
            json_request = std.json.parseFromSlice(Value, ctx.gpa, line, .{ .allocate = .alloc_if_needed }) catch {
                ctx.root.emit(.{ .type = "error", .message = "invalid JSON (expect {\"type\":\"user\",\"text\":\"...\"})" });
                continue;
            };
            const parsed = json_request.?.value;
            const rtype = if (parsed == .object)
                (if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "")
            else
                "";
            if (std.mem.eql(u8, rtype, "set_model")) {
                ctx.root.ensureStoredKeys(ctx.keys);
                const provider_field = if (parsed.object.get("provider")) |v| (if (v == .string) v.string else "") else "";
                const model_field = if (parsed.object.get("model")) |v| (if (v == .string) v.string else "") else "";
                const legacy_name = if (parsed.object.get("name")) |v| (if (v == .string) v.string else "") else "";
                providers.ensureControlRequestCatalogs(ctx.root, ctx.keys.*, provider_field, model_field, legacy_name);
                const provider = providers.resolveProviderControlRequest(ctx.keys, ctx.arena, provider_field, model_field, legacy_name) catch |err| {
                    const label = providers.setModelRequestLabel(ctx.arena, provider_field, model_field, legacy_name) catch "<requested model>";
                    const message = switch (err) {
                        error.MissingKey => try std.fmt.allocPrint(ctx.arena, "no key/login for requested model '{s}'", .{label}),
                        error.InvalidModel => try std.fmt.allocPrint(ctx.arena, "unknown model '{s}'; refresh/list models before switching", .{label}),
                        error.InvalidModelRequest => "set_model needs a non-empty provider/model or legacy name",
                        else => try std.fmt.allocPrint(ctx.arena, "failed to switch model '{s}': {s}", .{ label, @errorName(err) }),
                    };
                    ctx.root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                const note = try providers.applyProvider(ctx.root, ctx.arena, provider);
                ctx.root.emit(.{ .type = "model", .ok = true, .provider = provider.id, .model = provider.model, .context = provider.context, .note = note });
                continue;
            }
            if (std.mem.eql(u8, rtype, "compact")) {
                const chars = ctx.root.compact() catch |err| {
                    const message = switch (err) {
                        error.EmptySummary => "compaction failed: empty summary, history unchanged",
                        error.IncompleteSummary => "compaction failed: incomplete summary, history unchanged",
                        else => try std.fmt.allocPrint(ctx.arena, "compaction failed: {s}", .{@errorName(err)}),
                    };
                    ctx.root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                ctx.root.emit(.{ .type = "compact", .ok = true, .chars = chars });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_mode")) {
                const mode = if (parsed.object.get("mode")) |v| (if (v == .string) v.string else "") else "";
                if (std.mem.eql(u8, mode, "plan")) {
                    main_mod.plan_mode = true;
                } else if (std.mem.eql(u8, mode, "normal")) {
                    main_mod.plan_mode = false;
                } else {
                    ctx.root.emit(.{ .type = "error", .message = "set_mode needs mode 'plan' or 'normal'" });
                    continue;
                }
                ctx.root.emit(.{ .type = "mode", .ok = true, .mode = mode });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_agent")) {
                const id = if (parsed.object.get("id")) |v| (if (v == .string) v.string else "") else "";
                if (id.len == 0) {
                    try prompts.setSystemPrompts(ctx.root, ctx.sys_normal, ctx.arena); // #326: reset to the startup base, all four variants
                    ctx.root.rebaseContextMeter();
                    ctx.root.emit(.{ .type = "agent", .ok = true, .id = id, .chars = ctx.root.sys_normal.len });
                    continue;
                }
                const prompt = fleet.agentTypePrompt(id) orelse {
                    const message = try std.fmt.allocPrint(ctx.arena, "unknown agent '{s}' (see /agents)", .{id});
                    ctx.root.emit(.{ .type = "error", .message = message });
                    continue;
                };
                const persona_base = try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ ctx.sys_normal, prompt });
                try prompts.setSystemPrompts(ctx.root, persona_base, ctx.arena); // #326: recomputes strict + ultra too
                ctx.root.rebaseContextMeter();
                ctx.root.emit(.{ .type = "agent", .ok = true, .id = id, .chars = ctx.root.sys_normal.len });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_effort")) {
                const level = if (parsed.object.get("level")) |v| (if (v == .string) v.string else "") else "";
                ctx.root.reasoning = std.meta.stringToEnum(main_mod.ReasoningEffort, level) orelse {
                    ctx.root.emit(.{ .type = "error", .message = "set_effort needs level low|medium|high|xhigh|max|ultra" });
                    continue;
                };
                _ = repl_glue.saveThinkingSettings(ctx.root.io, ctx.root.gpa, ctx.root.reasoning, ctx.root.fast, ctx.root.ultracode_mode, ctx.root.show_thinking, ctx.root.ai_title);
                ctx.root.emit(.{ .type = "effort", .ok = true, .level = level, .applies = ctx.root.effortApplies() });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_fast")) {
                const on = if (parsed.object.get("on")) |v| (if (v == .bool) v.bool else false) else false;
                ctx.root.fast = on;
                _ = repl_glue.saveThinkingSettings(ctx.root.io, ctx.root.gpa, ctx.root.reasoning, ctx.root.fast, ctx.root.ultracode_mode, ctx.root.show_thinking, ctx.root.ai_title);
                ctx.root.emit(.{ .type = "fast", .ok = true, .on = on, .applies = ctx.root.provider.kind == .responses });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_ultracode")) {
                const on = if (parsed.object.get("on")) |v| (if (v == .bool) v.bool else false) else false;
                ctx.root.ultracode_mode = on;
                _ = repl_glue.saveThinkingSettings(ctx.root.io, ctx.root.gpa, ctx.root.reasoning, ctx.root.fast, ctx.root.ultracode_mode, ctx.root.show_thinking, ctx.root.ai_title);
                ctx.root.emit(.{ .type = "ultracode", .ok = true, .on = on });
                continue;
            }
            if (std.mem.eql(u8, rtype, "score")) {
                mainloop_score.handle(ctx.root, parsed.object);
                continue;
            }
            if (std.mem.eql(u8, rtype, "answer")) {
                ctx.root.emit(.{ .type = "error", .message = "answer received with no active ask_user prompt" });
                continue;
            }
            const t = if (parsed == .object) parsed.object.get("text") else null;
            const text = if (t) |v| (if (v == .string) v.string else "") else "";
            if (text.len == 0) {
                ctx.root.emit(.{ .type = "error", .message = "request needs a non-empty \"text\" field" });
                continue;
            }
            if (std.mem.eql(u8, rtype, "set_system_prompt")) {
                const append = if (parsed.object.get("append")) |v| v == .bool and v.bool else false;
                const new_base = if (append)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ ctx.root.sys_normal, text })
                else
                    try ctx.arena.dupe(u8, text);
                try prompts.setSystemPrompts(ctx.root, new_base, ctx.arena); // #326: recomputes strict + ultra too
                ctx.root.rebaseContextMeter();
                ctx.root.emit(.{ .type = "system_prompt", .ok = true, .append = append, .chars = ctx.root.sys_normal.len });
                continue;
            }
            if (std.mem.eql(u8, rtype, "review")) review_prompt = text;
            // #415: a side question is ANSWERED here and never becomes a turn —
            // no tools, billed, and nothing added to the session or its transcript.
            if (json_controls.sideQuestion(ctx.root, ctx.arena, rtype, text)) continue;
            json_controls.applyToolKnobs(parsed.object);
            break :blk text;
        } else line;
        ctx.root.review_mode = review_prompt != null;
        const parent_system_override = ctx.root.sys_override;
        if (ctx.root.review_mode)
            ctx.root.sys_override = try review.systemPrompt(ctx.arena, ctx.root.sys_normal);
        defer {
            ctx.root.review_mode = false;
            ctx.root.sys_override = parent_system_override;
        }

        if (ctx.root.fallback_blocked) {
            const message = try std.fmt.allocPrint(ctx.arena, "saved model unavailable; sending to {s} requires explicit consent — run /fallback allow {s} or choose /model", .{ ctx.root.provider.id, ctx.root.provider.id });
            if (main_mod.json_mode) ctx.root.emit(.{ .type = "error", .message = message }) else {
                try ctx.out.print("{s}⚠ {s}{s}\n", .{ style.yellow, message, style.reset });
                try ctx.out.flush();
            }
            continue;
        }

        // Persistent goal steering (#318): the diff-gated standing-goal note
        // plus one-shot notes (/goal replace|clear, and the standing state an
        // emergency trim re-queues). Compaction restates the checklist itself.
        var goal_msg: []const u8 = try goal_state.applyGoalSteering(ctx.arena, ctx.root, base_msg);
        const eval_note = if (ctx.root.review_mode) "" else try repl_glue.evalSteeringNote(
            ctx.arena,
            ctx.root.eval_cmd,
            ctx.root.eval_target,
            ctx.root.eval_judge != null,
            ctx.root.eval_verified,
            ctx.root.eval_repair_pending,
            eval_memory.load(ctx.root),
        );
        if (eval_note.len > 0) goal_msg = try std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}", .{ goal_msg, eval_note });

        // /goal and /loop both ask the model to work autonomously (plan→act→verify).
        const loop_msg: []const u8 = if (loop_prompt != null) try std.fmt.allocPrint(ctx.arena,
            \\{s}
            \\
            \\[harness note: this is an autonomous run. Work until the prompt is satisfied: make a brief plan, execute it with tools, verify the result, and only stop when you can report completion or you need a required human decision. Keep iterations tight and avoid asking for confirmation between routine steps. Track multi-step work with todo_write and finish by calling attempt_completion with the final result - that ends the run. A turn that uses no tools also ends it, so if the prompt needs no tool work, just answer it.]
        , .{goal_msg}) else goal_msg;

        const msg: []const u8 = if (!main_mod.plan_mode or ctx.root.review_mode) loop_msg else try std.fmt.allocPrint(ctx.arena,
            \\{s}
            \\
            \\[harness note: plan mode is ON — read-only. Explore with read-only
            \\tools as needed, then present a concrete plan (files to change,
            \\the changes themselves, sequence, risks) and ask the user to
            \\approve it. Do not write files or run mutating commands — the
            \\gate will deny them. The user toggles execution back on with /plan.]
        , .{loop_msg});

        // Promote a GUI `@[image]` attachment to a native vision block when the
        // model can see (otherwise it only gets the path and resorts to OCR).
        vision.stageGuiImageAttachment(ctx.root, msg);

        // Generate the AI title before the root turn and publish it through the
        // session-scoped nonblocking completion queue.
        if (!main_mod.json_mode and !ctx.root.review_mode and ctx.root.ai_title and !ctx.root.ai_title_done) {
            ctx.root.ai_title_done = true;
            title_jobs.start(ctx, base_msg);
        }

        // Materialize the session header and keep the window title in sync.
        if (!main_mod.json_mode) {
            if (!ctx.root.tui_header_shown) {
                // Print the fast title immediately; the detached AI title later updates
                // the redrawable window title and session filename without blocking.
                const turn_title = title_mod.titleFromPrompt(base_msg);
                title_mod.setTerminalTitle(ctx.out, turn_title, main_mod.g_cwd_display);
                try title_mod.printSessionHeader(ctx.out, turn_title, main_mod.g_cwd_display);
                ctx.root.tui_header_shown = true;
            } else {
                // Later turns: keep the OSC tab/window title synced; header shown.
                const turn_title = ctx.root.session_title orelse title_mod.titleFromPrompt(base_msg);
                title_mod.setTerminalTitle(ctx.out, turn_title, main_mod.g_cwd_display);
            }
        }

        // "ultracode" codeword or persistent /ultracode mode: opt turns into multi-agent workflow mode.
        const ultracode_msg = if (ctx.root.review_mode)
            pickers.UltracodeMessage{ .text = msg, .explicit = false }
        else
            try pickers.applyUltracodeSteering(ctx.arena, msg, base_msg, prompts.ultracodeActive(ctx.root));
        if (ultracode_msg.explicit) {
            if (!main_mod.json_mode) {
                if (ctx.interactive) {
                    anim.ultracodeShine(ctx.out, ctx.io);
                    try ctx.out.writeAll("⚡ multi-agent workflow mode engaged\n");
                } else {
                    try ctx.out.writeAll("⚡ ultracode — multi-agent workflow mode engaged\n");
                }
                try ctx.out.flush();
            }
            ctx.root.tracer.?.note("ultracode", msg[0..@min(msg.len, 120)]);
            if (telemetry.g_telem) |t| t.ultracode();
        }
        var review_context = review.Context.begin(ctx.arena, ctx.root, ctx.root.review_mode);
        if (ctx.root.review_mode) ctx.root.rebaseContextMeter();
        defer if (review_context.restore(ctx.root)) ctx.root.rebaseContextMeter();
        if (ctx.root.pending_image) |img| {
            try ctx.root.messages.append(try vision.imageMessage(ctx.arena, ctx.root.provider.kind, ultracode_msg.text, img));
            ctx.root.pending_image = null;
        } else try ctx.root.messages.append(try messages.textMessage(ctx.arena, "user", ultracode_msg.text));
        ctx.root.snapshots.?.turn += 1; // tag file edits in this turn (matches /rewind numbering)
        if (telemetry.g_telem) |t| t.countTurn();
        // Trajectory: claim this turn's node id up front so subagents spawned during the turn can attach to it as their parent.
        const turn_id: u64 = if (trace.g_traj) |tj| blk: {
            const id = tj.nextId();
            tj.setTurn(id);
            break :blk id;
        } else 0;
        ctx.root.tools_used.clear(ctx.io); // per-turn tool log for the turn's node
        ctx.root.tool_calls_this_turn = 0;
        goal_state.beginTurn(ctx.root, !is_loop_continuation); // per-turn gate flags (the ARMED double-check is NOT one, #318) + the new-ask retirement of a finished checklist (#394)
        ctx.root.seen_tool_keys.clearRetainingCapacity();
        if (main_mod.json_mode) ctx.root.emit(.{ .type = "started", .provider = ctx.root.provider.id, .model = ctx.root.provider.model });
        if (ctx.interactive and !main_mod.json_mode) {
            try ctx.out.writeAll("\n");
            try ctx.out.flush();
        }
        const turn_before = mainloop_trace.begin(ctx.root, ctx.io);
        const turn_started = Io.Timestamp.now(ctx.io, .awake);
        // A failed turn must never kill the session: ApiError is already
        // reported inside request(); anything else is surfaced here. Either
        // way we drop back to the prompt (or emit a JSON error/turn event).
        const turn_result = providers.runTurnWithFallback(ctx.root, ctx.keys, ctx.arena, ctx.out);
        // Reuse one full-history scan for trace, terminal event, and compaction.
        const post_turn_context_tokens = ctx.root.effectiveContextTokens();
        mainloop_trace.record(ctx.root, ctx.io, ctx.arena, base_msg, turn_id, turn_started, turn_result, post_turn_context_tokens, turn_before, &prev_turn_id, &prev_prompt_fp);
        const isolated_review = review_context.restore(ctx.root);
        if (isolated_review) {
            ctx.root.review_mode = false;
            ctx.root.sys_override = parent_system_override;
            try ctx.root.messages.append(try messages.textMessage(ctx.arena, "user", base_msg));
            ctx.root.rebaseContextMeter();
        }
        const final_text = turn_result catch |err| switch (err) {
            error.Interrupted => {
                // Esc: keep what streamed so far in history (as an assistant
                // turn with an explicit marker) so the conversation stays
                // coherent, then drop back to the prompt.
                const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                const marker: []const u8 = if (partial.len > 0)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n[response interrupted by user]", .{partial})
                else
                    "[response interrupted by user]";
                try ctx.root.messages.append(try messages.textMessage(ctx.arena, "assistant", marker));
                const int_msg: []const u8 = if (main_mod.g_force_interrupt) "✗ interrupted (force)" else "✗ interrupted (esc)";
                main_mod.g_force_interrupt = false;
                try ctx.out.print("{s}{s}{s}\n", .{ style.yellow, int_msg, style.reset });
                try ctx.out.flush();
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            error.StreamStalled => {
                // A dead/idle stream (no SSE bytes for stream_stall_ms): the
                // harness gave up, NOT the user (#134) — keep the partial but
                // tag it a stall, and emit the structured error for --json.
                const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                const marker: []const u8 = if (partial.len > 0)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n[response ended early: stream stalled]", .{partial})
                else
                    "[response ended early: stream stalled]";
                try ctx.root.messages.append(try messages.textMessage(ctx.arena, "assistant", marker));
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = ctx.root.last_api_error orelse "stream stalled — ending turn" });
                    if (partial.len > 0) {
                        ctx.root.emit(.{ .type = "finalizing" });
                        const context_tokens = ctx.root.effectiveContextTokens();
                        ctx.root.emit(.{ .type = "turn", .text = partial, .context_tokens = context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = false, .metadata_complete = context_tokens > 0 });
                    }
                }
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            error.StreamDropped => {
                // The provider closed/reset the connection before its terminal
                // event ([DONE]/finish_reason) — the harness ended the turn, NOT
                // the user (#133). Keep the partial, tag it a drop (never
                // "[response interrupted by user]"), and emit the --json error.
                const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                const marker: []const u8 = if (partial.len > 0)
                    try std.fmt.allocPrint(ctx.arena, "{s}\n\n[response ended early: connection dropped]", .{partial})
                else
                    "[response ended early: connection dropped]";
                try ctx.root.messages.append(try messages.textMessage(ctx.arena, "assistant", marker));
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = ctx.root.last_api_error orelse "stream dropped — ending turn" });
                    if (partial.len > 0) {
                        ctx.root.emit(.{ .type = "finalizing" });
                        const context_tokens = ctx.root.effectiveContextTokens();
                        ctx.root.emit(.{ .type = "turn", .text = partial, .context_tokens = context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = false, .metadata_complete = context_tokens > 0 });
                    }
                }
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            error.ApiError => {
                if (telemetry.g_telem) |t| t.errorEvent("api", ctx.root.last_api_error orelse "api error");
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = ctx.root.last_api_error orelse "api error" });
                    const partial = std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n");
                    if (partial.len > 0) {
                        ctx.root.emit(.{ .type = "finalizing" });
                        const context_tokens = ctx.root.effectiveContextTokens();
                        ctx.root.emit(.{ .type = "turn", .text = partial, .context_tokens = context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = false, .metadata_complete = context_tokens > 0 });
                    }
                }
                // A turn can fail because the context window overflowed; if we're
                // over the compaction threshold, compact now so the next turn
                // isn't doomed to fail at the same size (#88). Match every other
                // automatic compaction path: a failed summary may destructively
                // trim only when the best meter says we're genuinely near 95%.
                const recovery_meter = ctx.root.effectiveContextTokens();
                if (recovery_meter >= ctx.root.provider.compactAt()) {
                    ctx.root.compactOrRecover(ctx.root.provider.nearContextLimit(recovery_meter));
                }
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
            else => |e| {
                if (telemetry.g_telem) |t| t.errorEvent("turn", @errorName(e));
                if (main_mod.json_mode) {
                    ctx.root.emit(.{ .type = "error", .message = @errorName(e) });
                } else {
                    ctx.root.say("[turn aborted: {t}]\n", .{e}) catch {};
                }
                session.saveSession(ctx.root, ctx.arena, ctx.root.session_name) catch {};
                continue;
            },
        };
        if (isolated_review)
            try ctx.root.messages.append(try messages.textMessage(ctx.arena, "assistant", final_text));
        const session_context_tokens = if (isolated_review) ctx.root.effectiveContextTokens() else post_turn_context_tokens;
        if (main_mod.json_mode) {
            const emitted_text = if (final_text.len == 0 and ctx.root.partial_text.items.len > 0)
                std.mem.trim(u8, ctx.root.partial_text.items, " \t\r\n")
            else
                final_text;
            ctx.root.emit(.{ .type = "finalizing" });
            // #124: allocator-level leak telemetry (GRAFF_MEM_DEBUG=1) — arena
            // capacity per turn separates a session-arena leak from gpa-side
            // growth, which OS-level RSS sampling can't tell apart. Emit this
            // before the terminal turn event so protocol bridges that stop at
            // `complete:true` never strand a debug event for the next request.
            if (main_mod.g_mem_debug) ctx.root.emit(.{
                .type = "mem",
                .session_arena_kb = if (main_mod.g_session_arena) |a| a.queryCapacity() / 1024 else 0,
                .scratch_arena_kb = if (ctx.root.scratch_arena) |a| a.queryCapacity() / 1024 else 0,
            });
            ctx.root.emit(.{ .type = "turn", .text = emitted_text, .context_tokens = session_context_tokens, .cost_usd = pricing.g_cost.snap(ctx.io).usd, .complete = isolated_review or !ctx.root.eval_repair_pending, .metadata_complete = session_context_tokens > 0 });
        }
        // Apply only if already complete; poll never waits for title generation.
        title_jobs.poll(ctx);
        fleet.joinElites(ctx.io); // publish backgrounded fleet champions for the next turn (no-op once joined)

        // turn_end lifecycle hooks (best-effort; interrupted/errored turns
        // `continue` above and never reach here, so ok is always true).
        if (main_mod.g_hooks.turn_end.len > 0) {
            for (main_mod.g_hooks.turn_end) |h| {
                const res = hooks.runHookCmd(ctx.gpa, ctx.io, h.command, "{\"event\":\"turn_end\",\"ok\":true}", h.timeout_ms);
                if (res.stderr.len > 0) ctx.gpa.free(res.stderr);
            }
        }

        if (session_context_tokens >= ctx.root.provider.compactAt()) {
            // Trim on failure only when we're genuinely against the window — at
            // 80–95% a transient compaction failure can recover next turn.
            const near_cap = ctx.root.provider.nearContextLimit(session_context_tokens);
            ctx.root.compactOrRecover(near_cap); // loop_list re-carries via root.history_rewrites, incl. MID-turn rewrites this block never sees (#318)
        }

        // #226: /loop controller-authorized continuation. After a cleanly-
        // completed autonomous /loop turn the CONTROLLER decides whether to run
        // another turn — not the model merely stopping; the rule itself is
        // goal_flow.loopTurnDecision. `loop_continue_armed` is consumed at the
        // next readline, so an interrupted/errored turn (which `continue`s past
        // here) never resumes the loop.
        if (loop_prompt != null and !main_mod.json_mode) {
            if (!is_loop_continuation) {
                loop_iters_left = loop_iter_cap; // fresh /loop run: arm the bound
                loop_list.reset(); // and a clean gate: its first continuation carries the list in full
            }
            switch (goal_flow.loopTurnDecision(ctx.root, loop_iters_left, util.unixMs(ctx.io))) {
                .continue_turn => {
                    loop_iters_left -= 1; // consume one credit for the queued continuation
                    loop_continue_armed = true;
                },
                .stop => |outcome| {
                    loop_iters_left = 0;
                    loop_continue_armed = false;
                    loop_list.reset();
                    loop_clock.clear(ctx.root);
                    // Only work_done reaches `accepted`, so the loop drove the
                    // goal to done; a --goal standing objective outlives it (#318).
                    if (outcome == .accepted) _ = goal_flow.acceptLoopOutcome(ctx.root);
                    const tone = if (outcome == .accepted) style.green else style.yellow; // success must not look like the four failures
                    try ctx.out.print("{s}↩ run stopped — {s}{s}\n", .{ tone, repl_glue.outcomeText(outcome, loop_iter_cap), style.reset });
                    try ctx.out.flush();
                    if (ctx.root.tracer) |t| t.note("loop", @tagName(outcome)); // every /goal transition is traced; the run's end was not
                },
            }
        }
        // opencode-style continuous autosave: persist after every turn so a crash or quit never loses the
        // thread — last.session.json, the same file /resume reads. Best-effort; a write failure never breaks
        // the loop. #273: unchanged history skips the save whole, and the write itself is queued.
        session.saveSessionAsync(ctx.root, ctx.arena, ctx.root.session_name) catch {};

        // --worktree checkpoint: commit this turn's edits to the scratch branch so the work is durable
        // + rewindable across restarts. No-op when not in a worktree or when --no-autocommit is set.
        jobs.worktreeAutoCommit(ctx.gpa, ctx.io, std.fmt.allocPrint(ctx.arena, "wip: {s}", .{title_mod.titleFromPrompt(base_msg)}) catch "wip: graff checkpoint");
    }
}
