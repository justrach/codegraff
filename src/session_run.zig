//! Agent-boot + run-loop entry helpers, split out of session_start.zig (600-line
//! goal). Covers approvals/hooks/fleet-type loading through Agent construction,
//! the `graff repl`/one-shot early-exit paths, and session resume/finalize. The
//! skills/theme/PTY-self-test phase moved on to session_settings.zig (#429) and
//! is re-exported from here.
//!
//! Engine side of the #422 boundary: every line this file used to print — the
//! startup "loaded N …" notices, the session-saved line, the one-shot's
//! terminal handoff — is a typed event now (engine_events.zig), rendered by
//! whichever sink the run has. Nothing here reaches the terminal cluster.
//!
//! Same dangling-pointer discipline as session_start.zig: `buildRootAgent`
//! returns `agent_mod.Agent` by value — safe because its pointer fields
//! (snapshots/client/tracer/approvals/registry) all reference storage the
//! CALLER already placed at a stable, final address (passed in by pointer),
//! not anything local to this function. `runReplCommand`/`runOneshotPrompt`/
//! `restoreResumedSession`/`finalizeSession` take `root: *agent_mod.Agent` —
//! by the time any of these run, `root` is already stable main()-owned
//! storage, so passing its address around is ordinary pointer-passing.
//! `setupSkillsAndTheme` hands back which reset `defer`s main() must register itself.
//!
//! Back-imports main (as main_mod) for Agent/the mutable globals it sets.
//! Sibling-imports everything else directly.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Approvals = agent_mod.Approvals; // via the Agent that owns it, not approvals.zig (#429)
const tools_mod = @import("tools.zig");
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const pricing = @import("pricing.zig");
const mcp = @import("mcp.zig");
const jobs = @import("jobs.zig");
const trace = @import("trace.zig");
const scoring = @import("scoring.zig");
const recipe = @import("recipe.zig");
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");
const engine_sink = @import("engine_sink.zig"); // #429: startup/teardown lines are typed events
const engine_events = @import("engine_events.zig");
const harness_policy = @import("harness_policy.zig");
const title_mod = @import("title.zig");
const repl = @import("repl.zig");
const shapes = @import("shapes.zig"); // applyUltracodeSteering lives here (#326)
const repl_glue = @import("repl_glue.zig");
const eval_memory = @import("eval_memory.zig");
const providers = @import("providers.zig");
const messages_mod = @import("messages.zig");
const session = @import("session.zig");
const session_settings = @import("session_settings.zig");
const presence = @import("presence.zig");
const proc_identity = @import("proc_identity.zig");
const goal_flow = @import("goal_flow.zig");
const fleet = @import("fleet.zig");
const hooks = @import("hooks.zig");
const learn_auto = @import("learn_auto.zig");
const learn_init = @import("learn_init.zig");
const run_budget_mod = @import("run_budget.zig");
const learning_privacy = @import("learning_privacy.zig");
const commands_privacy = @import("commands_privacy.zig");
const prompts = @import("prompts.zig");

/// `graff repl`: interactive chat REPL on the zigzag TUI, backed by the REAL
/// agent loop — each prompt runs a full root turn (tools + MCP) via
/// replTurnCb, reusing the root agent's tool set + registry + system prompt.
/// Self-contained — exits after. Moved out of main() (600-line goal).
/// `root` is already a stable, fully-constructed main()-owned Agent by the
/// time this is called, so taking its address here is safe (this helper
/// only reads through the pointer, it never owns or returns Agent storage).
pub fn runReplCommand(gpa: Allocator, io: Io, environ_map: anytype, root: *agent_mod.Agent, keys: *provider_mod.Keys, client: *std.http.Client, in: *Io.Reader, out: *Io.Writer, arena: Allocator, flags: args.Flags) !bool {
    if (!(flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "repl"))) return false;
    root.ensureStoredKeys(keys);
    providers.ensureModelQueryCatalogs(root, keys.*, "");
    // The standalone chat REPL can switch wire formats inside its own model
    // picker, so materialize every catalog only when this surface is entered.
    try root.ensureRootTools(.anthropic);
    try root.ensureRootTools(.openai);
    try root.ensureRootTools(.responses);
    var repl_ctx = repl_glue.ReplCtx{
        .io = io,
        .client = client,
        .keys = keys.*,
        .home = root.home,
        .provider = root.provider,
        .fallback_allow = root.fallback_allow,
        .fallback_active = root.fallback_active,
        .fallback_blocked = root.fallback_blocked,
        .registry = root.registry,
        .tracer = root.tracer,
        .run_budget = root.run_budget,
        .sys_normal = root.sys_normal,
        .tools_anthropic = root.tools_anthropic,
        .tools_openai = root.tools_openai,
        .tools_responses = root.tools_responses,
    };
    var models_buf = std.array_list.Managed(u8).init(arena);
    for (pricing.models()) |mi| {
        if (mi.name.len == 0) continue;
        if (models_buf.items.len != 0) models_buf.appendSlice(", ") catch {};
        models_buf.appendSlice(mi.name) catch {};
    }
    if (Io.File.stdin().isTty(io) catch true)
        try repl.run(gpa, io, environ_map, &repl_ctx, repl_glue.replTurnCb, repl_glue.replModelCb, repl_glue.replCancelCb, root.provider.model, models_buf.items)
    else
        try repl.runScripted(gpa, io, environ_map, in, out, &repl_ctx, repl_glue.replTurnCb, repl_glue.replModelCb, repl_glue.replCancelCb, root.provider.model, models_buf.items);
    return true;
}

/// One-shot print mode (`-p`/bare positional prompt): run the single prompt
/// to completion, print the final text to stdout, exit. Tool progress goes
/// to stderr (say() with no out writer), streaming stays quiet, and the gate
/// denies anything not pre-approved instead of prompting (there's no one to
/// ask). Moved out of main() verbatim (600-line goal); `root`/`tracer` are
/// already stable main()-owned storage by the time this runs.
pub fn runOneshotPrompt(gpa: Allocator, io: Io, arena: Allocator, root: *agent_mod.Agent, keys: *provider_mod.Keys, tracer: *trace.Tracer, out: *Io.Writer, prompt_text: []const u8) !void {
    if (@import("goal_pacing.zig").oneshotSlashRefusal(prompt_text)) |why| std.process.fatal("{s}", .{why}); // usage error, not a prompt
    main_mod.unattended = true;
    root.in = null; // gate: deny instead of prompt; ask_user: self-decide
    root.out = null; // tool progress → stderr; stdout carries only the answer
    root.stream_quiet = true;
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
    try root.messages.append(try messages_mod.textMessage(arena, "user", oneshot_user));
    if (telemetry.g_telem) |t| t.countTurn();
    const final_text = providers.runTurnWithFallback(root, keys, arena, null) catch |err| {
        // std.process.fatal does not unwind main's defers. Mirror their order:
        // join the fleet, reap jobs/pumps, then the terminal behavioral event.
        fleet.joinElites(io);
        jobs.jobsReap(gpa, io);
        // Flush buffered OTLP too: a fatal one-shot stays visible in ordinary telemetry.
        if (telemetry.g_telem) |t| t.flush();
        if (tracer.behavior) |behavior| behavior.finish(.failed);
        pricing.printUsageFooter(io); // #387/#389: fatal exits still owe cost accounting
        if (root.tools_used.count() > 0) std.debug.print("note: {d} tool call(s) completed before the failure; their work was not rolled back\n", .{root.tools_used.count()});
        switch (err) {
            error.FallbackConsentRequired => std.process.fatal("saved model unavailable; provider '{s}' is not allowlisted — run graff interactively, then /fallback allow {s}", .{ root.provider.id, root.provider.id }),
            error.ApiError => std.process.fatal("{s}", .{root.last_api_error orelse "api error"}),
            error.RunBudgetExhausted => @import("run_budget.zig").RunBudget.exhaustedFatal(if (root.run_budget) |b| b.max_model_calls else 0, &@import("scoring.zig").g_run_id), // #368
            else => |e| std.process.fatal("turn failed: {t}", .{e}),
        }
    };
    try out.print("{s}\n", .{final_text});
    try out.flush();
    // Usage summary → stderr, so stdout stays exactly the answer.
    pricing.printUsageFooter(io);
    session.saveSession(root, arena, root.session_name) catch |err| {
        std.debug.print("⚠ session save failed: {s}\n", .{@errorName(err)});
    };

    // --worktree: checkpoint the one-shot's edits to the scratch branch too.
    // Headless swarm agents (graff -w name -p "task") are the main -w use
    // case — they must not exit with their work left uncommitted.
    jobs.worktreeAutoCommit(gpa, io, std.fmt.allocPrint(arena, "wip: {s}", .{title_mod.titleFromPrompt(prompt_text)}) catch "wip: graff oneshot");
    // One-shot returns here, before the REPL cleanup defer below is even
    // registered, so free the root's gpa-backed buffers explicitly (else a
    // tool-using one-shot leaks its tool log / render buffers on exit).
    root.md_buf.deinit(gpa);
    root.md_word.deinit(gpa);
    for (root.md_table.items) |r| gpa.free(r);
    root.md_table.deinit(gpa);
    root.tools_used.deinit(gpa);
    // Presence announced this session at boot (#469); a one-shot returns
    // before finalizeSession, so retire + free its gpa-owned globals here or
    // they reach the exit-time leak check — and our record would linger in
    // the registry until a peer's liveness probe reaps it.
    presence.retire(io);
    presence.deinit(gpa);
    // #396: the run is over. The frontend hands the terminal back and latches
    // its reader shut before main()'s teardown — a terminal-ownership move the
    // sink owns now, in EVERY mode, exactly as the old unconditional call did.
    engine_sink.writerSink(out).emit(io, .run_finished);
}

/// Loads persisted command/tool approvals + lifecycle hooks + the MAP-Elites
/// agent-type registry (builtins + .harness/agents/*.md), and prints the
/// startup status lines for both. Moved out of main() (600-line goal).
/// `approvals` is an out-param: main() declares it (`var approvals: Approvals
/// = undefined;`) and this fills it in place, so main() can still register
/// its own `defer` for `approvals.prefixes` right after the call (a `defer`
/// registered here would fire when THIS returns, not when main() does).
pub fn initApprovalsHooksFleet(io: Io, gpa: Allocator, arena: Allocator, environ_map: anytype, approvals: *Approvals, flags: args.Flags, out: *Io.Writer, json_mode: bool) !void {
    approvals.* = .{ .yolo = flags.effectiveYolo() }; // -p implies yolo unless --safe
    const persisted_approvals = approvals.loadPersisted(io, gpa, arena);

    // Agent types: builtins + .harness/agents/*.md (the MAP-Elites niches).
    fleet.g_home = keys_cli.homeEnv(environ_map); // for /agents promote's personal tier
    fleet.g_agent_types = fleet.loadAgentTypes(io, arena, fleet.g_home); // builtin < ~/.harness/agents (personal) < ./.harness/agents (private)
    const sink = engine_sink.writerSink(out);
    const speak = !json_mode and flags.oneshot_prompt == null;
    if (persisted_approvals > 0 and speak)
        sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "loaded {d} saved approval(s) from {s}", .{ persisted_approvals, harness_policy.settings_path })));
    // Lifecycle hooks (pre_tool/post_tool/turn_end) from the same file.
    // (Per-skill opt-outs were loaded earlier, before the muonry auto-connect.)
    main_mod.g_hooks = hooks.loadHooks(io, arena);
    if (main_mod.g_hooks.total() > 0 and speak)
        sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "loaded {d} lifecycle hook(s) from {s} — /hooks lists them", .{ main_mod.g_hooks.total(), harness_policy.settings_path })));
}

/// The lifecycle's most common line: dim, no badge. A helper rather than a
/// variant — see session_start.dimNotice.
fn dimNotice(text: []const u8) engine_events.EngineEvent {
    return .{ .session_notice = .{ .text = text, .tone = .dim } };
}

/// Constructs the root Agent: snapshots/client/tracer/approvals/registry are
/// all ALREADY stable main()-owned storage by the time this is called (the
/// caller passes their addresses in), so this returns `agent_mod.Agent` by
/// value safely — its pointer fields reference external, already-placed
/// storage, not anything local to this function (see this file's header).
/// Also does the post-construction config (session name, persisted
/// thinking/goal/eval settings, the session-start trace note) and kicks off
/// the backgrounded fleet-champion pull, moved out of main() verbatim
/// (600-line goal). `sys_normal` is the startup-composed BASE; this calls
/// prompts.setSystemPrompts() to derive sys_strict/sys_ultra/sys_ultra_strict
/// from it, the same funnel every later prompt mutation must use (#326).
pub fn buildRootAgent(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *std.http.Client,
    default_provider: provider_mod.Provider,
    subagent_provider: ?provider_mod.Provider,
    environ_map: anytype,
    out: *Io.Writer,
    in: *Io.Reader,
    registry: ?*mcp.Registry,
    approvals: *Approvals,
    tracer: *trace.Tracer,
    sys_normal: []const u8,
    snaps: *tools_mod.Snapshots,
    flags: args.Flags,
    telem_endpoint: []const u8,
) !agent_mod.Agent {
    var root: agent_mod.Agent = .{
        .snapshots = snaps,
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = client,
        .provider = default_provider,
        .subagent_provider = subagent_provider,
        .subagent_provider_explicit = flags.subagent_provider_flag != null or flags.subagent_model_flag != null or flags.no_subagent_tier_flag or environ_map.get("GRAFF_SUBAGENT_PROVIDER") != null or environ_map.get("GRAFF_SUBAGENT_MODEL") != null, // #371: only a USER-stated worker choice survives /model
        .subagent_cross_provider = flags.allow_cross_provider_subagents_flag,
        .home = keys_cli.homeEnv(environ_map) orelse "",
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "main",
        .out = out,
        .in = in,
        .registry = registry,
        .approvals = approvals,
        .tracer = tracer,
        .tools_anthropic = "",
        .tools_openai = "",
        .tools_responses = "",
    };
    // #410: the durable session's name is settled BEFORE the prompt funnel runs — setRootSystemPrompts composes the transcript line out of it.
    // The pid suffix keeps two graffs started in the same millisecond from
    // sharing a session name — which would also share one .session.json file
    // (#289 contention) and collide as presence peers (#469).
    const fresh_session_name = try std.fmt.allocPrint(arena, "session-{d}-{d}", .{ util.unixMs(io), proc_identity.selfPid() });
    root.session_name = if (flags.resume_flag) |name| (if (!flags.new_session_flag and !flags.no_resume_flag) name else fresh_session_name) else fresh_session_name;
    try prompts.setRootSystemPrompts(&root, sys_normal, arena); // #381: same funnel + the live .graff/playbook.jsonl constraint block
    // Startup pays for one provider format, not all three. Other formats are
    // rendered on first switch with the same built-in + live MCP inputs.
    try root.ensureRootTools(default_provider.kind);
    repl_glue.loadThinkingSettings(io, arena, &root); // {"effort":...,"fast":...} persisted by /effort and /fast
    if (flags.goal_flag) |g| { // --goal is STANDING (#318): every turn (incl. --json/-p/SDK), never model-retired
        root.goal_flag = try arena.dupe(u8, g); // kept: re-applied over every loadSession, incl. /resume
        root.goal = goal_flow.standingGoalFromFlag(root.goal_flag.?, null, root.todos.items, util.unixMs(io));
    }
    // #469: register this root session so co-resident graffs see it (and it
    // them) BEFORE anyone touches the shared tree — a live co-owner is named
    // at birth here, not discovered mid-collision.
    if (presence.announce(io, gpa, arena, root.home, root.session_name, if (root.goal) |g| g.objective else "")) |warning| {
        if (!main_mod.json_mode and flags.oneshot_prompt == null) try out.print("{s}", .{warning});
    }
    if (flags.eval_cmd_flag) |c| root.eval_cmd = try arena.dupe(u8, c);
    if (flags.eval_target_flag) |t| root.eval_target = t;
    if (flags.eval_niche_flag) |n| root.eval_niche = try arena.dupe(u8, n);
    _ = recipe.record(tracer, trace.g_traj, root.provider.id, root.provider.model, @tagName(root.reasoning), root.systemPrompt(), root.toolsJson(), if (root.eval_niche.len > 0) root.eval_niche else "interactive");
    tracer.note("session", root.provider.model);
    // Distribute (docs §9.E): pull this tier's live fleet champions and prefer
    // them over the baked builtins. Best-effort + bounded; emits fleet:elite_pull.
    var esh_pull: [16]u8 = undefined;
    const pull_esh: []const u8 = if (root.eval_cmd) |c| pblk: {
        esh_pull = scoring.promptFingerprint(c);
        break :pblk &esh_pull;
    } else ""; // pull the champion for our eval suite (if any)
    // Background the fleet-champion pull: a ~0.3s TLS round-trip that used to block
    // the first prompt. Spawn it now; joinElites() reaps it on the main thread at the
    // first turn, so the user's typing hides the fetch (prompt paints ~0.3s sooner).
    fleet.g_elites_future = io.async(fleet.pullElites, .{ io, arena, client, telemetry.g_telem, telem_endpoint, scoring.providerClass(root.provider.model), arena.dupe(u8, pull_esh) catch pull_esh, fleet.g_agent_types });
    return root;
}

/// Save-from-the-start (so a killed session isn't a total loss) + the
/// resume-target reload for a resumed one-shot. Moved out of main() verbatim
/// (600-line goal). Both are best-effort (`catch {}`), matching main()'s
/// former inline behavior exactly.
pub fn saveOrResumeSession(root: *agent_mod.Agent, keys: *provider_mod.Keys, arena: Allocator, flags: args.Flags) void {
    const will_resume = flags.resume_flag != null and !flags.new_session_flag and !flags.no_resume_flag;
    if (!will_resume) session.saveSession(root, arena, root.session_name) catch {};
    if (flags.oneshot_prompt != null and flags.resume_flag != null and !flags.new_session_flag and !flags.no_resume_flag) {
        session.loadSession(root, keys, arena, root.session_name) catch {};
        // loadSession overwrote root.goal; the flag wins, idempotently (#318).
        if (root.goal_flag) |g| root.pending_goal_note = goal_flow.reapplyFlagGoal(arena, root, g, util.unixMs(root.io)) catch null;
    }
}

/// Explicit resume only: bare `graff` starts fresh, while `--resume <name>`
/// restores that autosave target. Best-effort: a missing/keyless/corrupt
/// file silently starts fresh. This load-only phase deliberately performs no
/// model work: main emits run_started from the restored configuration before
/// optional cold-cache compaction begins. `root` is already stable
/// main()-owned storage.
pub fn restoreResumedSession(arena: Allocator, out: *Io.Writer, root: *agent_mod.Agent, keys: *provider_mod.Keys, flags: args.Flags, json_mode: bool, cwd_display: []const u8) !void {
    if (!(flags.oneshot_prompt == null and flags.resume_flag != null and !flags.new_session_flag and !flags.no_resume_flag)) return;
    if (session.loadSession(root, keys, arena, root.session_name)) |_| {
        // --goal outranks the restored goal here too, idempotently (#318).
        if (root.goal_flag) |g| root.pending_goal_note = goal_flow.reapplyFlagGoal(arena, root, g, util.unixMs(root.io)) catch null;
        if (root.messages.items.len > 0) {
            if (!json_mode) {
                // Prefer the saved AI summary; fall back to the first user
                // message only for older sessions that have no saved title.
                const restored_title = root.session_title orelse title_mod.firstUserTitle(arena, root.messages);
                title_mod.setTerminalTitle(out, restored_title, cwd_display);
                try title_mod.printSessionHeader(out, restored_title, cwd_display);
                root.tui_header_shown = true;
                try out.print("↩ resumed {s}{s} — {d} message(s) on {s} · /new or /clear for a fresh start\n", .{ root.session_name, session.session_ext, root.messages.items.len, root.provider.model });
                try out.flush();
            }
        }
    } else |_| {}
}

/// Summarize a large restored context only after behavioral lifecycle start.
/// This preprocessing is outside a root-turn scope, so its operational API
/// trace is explicitly attributed to turn 0 rather than to a stale user turn.
/// Cold cache: loadSession rebased the saved server-only token delta onto
/// today's complete local request estimate; summarize up front when that
/// conservative meter crosses compactAt. Resume itself is never permission to
/// destructively trim on a transient/empty summary; a concrete provider
/// overflow can still override this.
pub fn compactResumedSession(root: *agent_mod.Agent) void {
    if (root.inputOverCompactThreshold()) {
        root.compactOrRecover(false);
    }
}

/// Final save-on-exit (also captures command-driven edits since the last
/// turn — /clear, /rewind — so the next start resumes the true end state)
/// + the worktree checkpoint commit for any edits an interrupted/aborted
/// final turn left uncommitted. Moved out of main() verbatim (600-line
/// goal); `root` is already stable main()-owned storage.
pub fn finalizeSession(gpa: Allocator, io: Io, arena: Allocator, out: *Io.Writer, root: *agent_mod.Agent, json_mode: bool) !void {
    // #469: our presence record leaves the registry with us; a crashed session
    // skips this and gets reaped by the next reader's liveness probe instead.
    presence.retire(io);
    presence.deinit(gpa); // its gpa-owned globals must not reach the exit-time leak check
    if (!json_mode and root.messages.items.len > 0) {
        const sink = engine_sink.writerSink(out);
        if (session.saveSession(root, arena, root.session_name)) |_| {
            sink.emit(io, .{ .session_saved = .{ .name = root.session_name, .ext = session.session_ext } });
        } else |err| { // one line, and true: never contradict a failure with "saved" (#273)
            const text = std.fmt.allocPrint(arena, "⚠ session save failed: {t}", .{err}) catch "⚠ session save failed";
            sink.emit(io, .{ .session_notice = .{ .text = text, .tone = .warn } });
        }
    } else {
        session.saveSession(root, arena, root.session_name) catch {};
    }

    // Capture edits from an interrupted/aborted final turn (those `continue`
    // before the per-turn checkpoint) so a worktree never quits with work left
    // uncommitted on its scratch branch.
    jobs.worktreeAutoCommit(gpa, io, "wip: session end");
    try out.writeAll("\n");
    try out.flush();
}

// The settings/theme phase moved to session_settings.zig (#429): it is the one
// part of this file that legitimately draws, so it sits on the terminal side of
// the #422 boundary. Re-exported so main() still calls it through session_run.
pub const ThemeSetup = session_settings.ThemeSetup;
pub const setupSkillsAndTheme = session_settings.setupSkillsAndTheme;

/// Contribution is on by default, so say it once per machine before anything
/// can be sent. Quiet in --json/-p, where stdout is protocol output.
pub fn learningNotice(io: Io, arena: Allocator, environ_map: anytype, out: *Io.Writer, quiet: bool) void {
    if (quiet or !main_mod.g_fleet) return;
    commands_privacy.firstRunNotice(io, arena, keys_cli.homeEnv(environ_map) orelse "", out);
}

fn reportTrialStarted(started: learn_auto.Started) void {
    std.debug.print(
        "↺ learning trial started in the background{s}{s} — `graff learn status`, log .graff/learn/{s}\n",
        .{
            if (started.resumed) " (resuming a checkpoint)" else "",
            if (started.contribute) " (contributing prompt-free aggregate grades)" else "",
            learn_auto.log_name,
        },
    );
}

/// Configure this workspace's learning store from the running binary, the same
/// way `graff learn init` would. Best effort by design: a machine with no
/// python3 or no usable credential simply does not learn, and the marker
/// learn_auto already claimed keeps that from being retried every session.
fn autoInitLearning(gpa: Allocator, arena: Allocator, io: Io, environ_map: *const std.process.Environ.Map) bool {
    std.debug.print("↺ setting this workspace up to learn from sessions like this one\n", .{});
    // learn init narrates its own progress; the session's closing lines below
    // are the useful summary, so its output goes to a buffer instead.
    var buf: [16 * 1024]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buf);
    learn_init.zeroConfig(gpa, arena, io, environ_map, .{}, &sink) catch |err| {
        std.debug.print(
            "↺ learning setup skipped ({s}) — `graff learn init` to retry\n",
            .{@errorName(err)},
        );
        return false;
    };
    std.debug.print(
        "↺ learning on for this workspace: a trial runs in the background every {d} sessions and spends real model calls — `graff learn status`, off with GRAFF_LEARN_AUTO=off\n",
        .{learn_auto.default_every_sessions},
    );
    return true;
}

/// Closing the learning loop: a session that did real model work counts toward
/// this workspace's next trial and, on cadence, starts one in the background.
/// The first such session in a workspace also creates the store it counts into.
pub fn startBackgroundLearning(gpa: Allocator, arena: Allocator, io: Io, environ_map: *const std.process.Environ.Map, budget: *const run_budget_mod.RunBudget, telemetry_allowed: bool) void {
    const options: learn_auto.Options = .{
        .model_calls = budget.used(),
        // A session launched with --no-telemetry keeps its trial local, even
        // though the child process would not inherit that flag.
        .contribute = telemetry_allowed and main_mod.g_fleet and learning_privacy.allowsAggregate(),
    };
    switch (learn_auto.maybeStart(gpa, arena, io, environ_map, options)) {
        .started => |started| reportTrialStarted(started),
        // First real session here: build the store, then count this session
        // against it so the cadence starts from this one rather than the next.
        .needs_store => {
            if (!autoInitLearning(gpa, arena, io, environ_map)) return;
            switch (learn_auto.maybeStart(gpa, arena, io, environ_map, options)) {
                .started => |started| reportTrialStarted(started),
                else => {},
            }
        },
        .skipped => {},
    }
}
