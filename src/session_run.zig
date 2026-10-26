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
const session_branch = @import("session_branch.zig");
const session_settings = @import("session_settings.zig");
const presence = @import("presence.zig");
const proc_identity = @import("proc_identity.zig");
const goal_flow = @import("goal_flow.zig");
const fleet = @import("fleet.zig");
const hooks = @import("hooks.zig");
const learn_auto = @import("learn_auto.zig");
const run_budget_mod = @import("run_budget.zig");
const learning_privacy = @import("learning_privacy.zig");
const commands_privacy = @import("commands_privacy.zig");
const prompts = @import("prompts.zig");
const local_tools = @import("local_tools.zig");

/// `graff repl`: TTY stdin falls through to the ordinary line REPL.
/// Piped/non-TTY stdin drives the scripted Model so CI
/// (`printf ... | graff repl`) keeps a stable headless path.
/// Self-contained — exits after. Moved out of main() (600-line goal).
/// `root` is already a stable, fully-constructed main()-owned Agent by the
/// time this is called, so taking its address here is safe (this helper
/// only reads through the pointer, it never owns or returns Agent storage).
pub fn runReplCommand(gpa: Allocator, io: Io, environ_map: anytype, root: *agent_mod.Agent, keys: *provider_mod.Keys, client: *std.http.Client, in: *Io.Reader, out: *Io.Writer, arena: Allocator, flags: args.Flags) !bool {
    if (!(flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "repl"))) return false;
    if (Io.File.stdin().isTty(io) catch true) return false;
    root.ensureStoredKeys(keys);
    providers.ensureModelQueryCatalogs(root, keys.*, "");
    // The standalone chat REPL can switch wire formats inside its own model
    // picker, so materialize every catalog only when this surface is entered.
    try root.ensureRootTools(.anthropic);
    try root.ensureRootTools(.openai);
    try root.ensureRootTools(.responses);
    var convo = repl_glue.Conversation.init(gpa);
    defer convo.deinit();
    try convo.seed(root.messages);
    convo.compaction_window = root.compaction_window;
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
        // Use the base: each turn's setSystemPrompts composes the
        // constraint block onto it, so root.sys_normal would stack a second copy.
        .sys_normal = if (root.sys_base.len > 0) root.sys_base else root.sys_normal,
        .tools_anthropic = root.tools_anthropic,
        .tools_openai = root.tools_openai,
        .tools_responses = root.tools_responses,
        .convo = &convo,
        .root = root,
    };
    var models_buf = std.array_list.Managed(u8).init(arena);
    for (pricing.models()) |mi| {
        if (mi.name.len == 0) continue;
        if (models_buf.items.len != 0) models_buf.appendSlice(", ") catch {};
        models_buf.appendSlice(mi.name) catch {};
    }
    repl_glue.bindHostCommands();
    defer repl_glue.unbindHostCommands();
    // ADR 0215: nothing wakes a scripted repl after its last line, so each
    // turn waits for the background work it started, as `-p` does.
    @import("run_idle.zig").enabled = true;
    defer @import("run_idle.zig").enabled = false;
    try repl.runScripted(gpa, io, environ_map, in, out, &repl_ctx, repl_glue.replTurnCb, repl_glue.replModelCb, repl_glue.replCancelCb, root.provider.model, models_buf.items);
    // Same stderr footer as `-p`, so evals can score the scripted REPL the
    // same way. TTY `graff repl` uses the main loop's footer.
    pricing.printUsageFooter(io);
    root.messages = try convo.cloneInto(root.arena);
    root.compaction_window = convo.compaction_window;
    return true;
}

pub fn runFrontendCommands(gpa: Allocator, io: Io, environ_map: anytype, root: *agent_mod.Agent, keys: *provider_mod.Keys, client: *std.http.Client, in: *Io.Reader, out: *Io.Writer, arena: Allocator, flags: args.Flags, json_mode: bool, _: []const u8, final_io: Io) !bool {
    if (try runReplCommand(gpa, io, environ_map, root, keys, client, in, out, arena, flags)) {
        try finalizeSession(gpa, final_io, arena, out, root, json_mode);
        return true;
    }
    if (try @import("acp.zig").runAcpCommand(gpa, io, environ_map, root, keys, client, in, out, arena, flags)) {
        try finalizeSession(gpa, final_io, arena, out, root, json_mode);
        return true;
    }
    return false;
}

/// One-shot print mode (`-p`/bare positional prompt): run the single prompt
/// to completion, print the final text to stdout, exit. Tool progress goes
/// to stderr (say() with no out writer), paint stays quiet, and the gate
/// denies anything not pre-approved instead of prompting (there's no one to
/// ask). Moved out of main() verbatim (600-line goal); `root`/`tracer` are
/// already stable main()-owned storage by the time this runs.
pub const runOneshotPrompt = @import("oneshot.zig").runOneshotPrompt;

/// Loads persisted command/tool approvals + lifecycle hooks + the MAP-Elites
/// agent-type registry (builtins + .harness/agents/*.{md,toml}), and prints the
/// startup status lines for both. Moved out of main() (600-line goal).
/// `approvals` is an out-param: main() declares it (`var approvals: Approvals
/// = undefined;`) and this fills it in place, so main() can still register
/// its own `defer` for `approvals.prefixes` right after the call (a `defer`
/// registered here would fire when THIS returns, not when main() does).
pub fn initApprovalsHooksFleet(io: Io, gpa: Allocator, arena: Allocator, environ_map: anytype, approvals: *Approvals, flags: args.Flags, out: *Io.Writer, json_mode: bool) !void {
    approvals.* = .{ .yolo = flags.effectiveYolo() }; // -p implies yolo unless --safe
    const persisted_approvals = approvals.loadPersisted(io, gpa, arena);

    // Agent types: builtins + .harness/agents/*.{md,toml} (the MAP-Elites niches).
    fleet.g_home = keys_cli.homeEnv(environ_map); // for /agents promote's personal tier
    fleet.g_agent_types = fleet.loadAgentTypes(io, arena, fleet.g_home); // builtin < ~/.harness/agents (personal) < ./.harness/agents (private)
    const sink = engine_sink.writerSink(out);
    const speak = !json_mode and flags.oneshot_prompt == null and environ_map.get("GRAFF_REPL_DEBUG") != null;
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
    root.session_name = if (flags.resume_flag != null and !flags.new_session_flag and !flags.no_resume_flag) (flags.branch_flag orelse flags.resume_flag.?) else fresh_session_name;
    root.session_parent = if (flags.branch_flag != null) flags.resume_flag else null;
    try prompts.setRootSystemPrompts(&root, sys_normal, arena); // #381: same funnel + the live .graff/playbook.jsonl constraint block
    local_tools.load(io, arena);
    // Startup pays for one provider format, not all three. Other formats are
    // rendered on first switch with the same built-in + live MCP inputs.
    try root.ensureRootTools(default_provider.kind);
    repl_glue.loadThinkingSettings(io, arena, &root); // {"effort":...,"fast":...} persisted by /effort and /fast
    if (flags.goal_flag) |g| { // --goal is STANDING (#318): every turn (incl. --json/-p/SDK), never model-retired
        root.goal_flag = try arena.dupe(u8, g); // kept: re-applied over every loadSession, incl. /resume
        root.goal = goal_flow.standingGoalFromFlag(root.goal_flag.?, null, root.todos.items, util.unixMs(io));
        prompts.pinStandingGoal(&root, arena); // ADR 0005: prefix, not an 8-turn user-message refresh
    }
    // #469: register this root session so co-resident graffs see it (and it
    // them) BEFORE anyone touches the shared tree — a live co-owner is named
    // at birth here, not discovered mid-collision.
    if (presence.announce(io, gpa, arena, root.home, root.session_name, if (root.goal) |g| g.objective else "")) |owner| {
        if (!main_mod.json_mode and flags.oneshot_prompt == null) {
            const age_ms = util.unixMs(io) - owner.last_seen_ms;
            engine_sink.writerSink(out).emit(io, .{ .shared_worktree_owner = .{
                .session_id = owner.session_id,
                .pid = owner.pid,
                .active_minutes = @divTrunc(if (age_ms > 0) age_ms else 0, std.time.ms_per_min),
                .goal = owner.goal,
            } });
        }
    }
    presence.noteLabelsFrom(io, gpa, arena, root.session_title, root.session_name);
    @import("presence_accord.zig").listen(io, gpa, presence.registryPath());
    if (flags.eval_cmd_flag) |c| root.eval_cmd = try arena.dupe(u8, c);
    // #502: --output-schema (inline JSON or @file) → structured outputs.
    if (flags.output_schema_flag) |schema_arg| {
        const trimmed = std.mem.trim(u8, schema_arg, " \t");
        root.output_schema = if (std.mem.startsWith(u8, trimmed, "@"))
            std.Io.Dir.cwd().readFileAlloc(io, trimmed[1..], arena, .limited(1024 * 1024)) catch |e| blk: {
                if (!main_mod.json_mode) try out.print("warning: --output-schema {s}: {t} — ignored\n", .{ trimmed[1..], e });
                break :blk null;
            }
        else
            try arena.dupe(u8, trimmed);
    }
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
    if (flags.oneshot_prompt != null and will_resume) {
        const source = flags.resume_flag.?;
        _ = session_branch.restore(root, keys, arena, source, flags.branch_flag, if (flags.model_flag != null) root.provider else null) catch |err| std.process.fatal("cannot resume/branch from '{s}': {t}", .{ source, err });
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
    const source = flags.resume_flag.?;
    if (session_branch.restore(root, keys, arena, source, flags.branch_flag, if (flags.model_flag != null) root.provider else null)) |_| {
        if (root.messages.items.len > 0) {
            if (!json_mode) {
                // Prefer the saved AI summary; fall back to the first user
                // message only for older sessions that have no saved title.
                const restored_title = root.session_title orelse title_mod.firstUserTitle(arena, root.messages);
                const cwd_now = @import("main.zig").g_cwd_display;
                const cwd_shown = if (cwd_now.len > 0) cwd_now else cwd_display;
                title_mod.setTerminalTitle(out, restored_title, cwd_shown);
                try title_mod.printSessionHeader(out, restored_title, cwd_shown);
                root.tui_header_shown = true;
                if (flags.branch_flag) |dest|
                    try out.print("↩ branched {s}{s} → {s}{s} — {d} message(s) on {s}\n", .{ source, session.session_ext, dest, session.session_ext, root.messages.items.len, root.provider.model })
                else
                    try out.print("↩ resumed {s}{s} — {d} message(s) on {s} · /new or /clear for a fresh start\n", .{ source, session.session_ext, root.messages.items.len, root.provider.model });
                try out.flush();
            }
        }
    } else |err| {
        if (flags.branch_flag != null) std.process.fatal("cannot branch from '{s}': {t}", .{ source, err });
    }
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
        root.autocompactResumed();
    }
}

/// Final save-on-exit (also captures command-driven edits since the last
/// turn — /clear, /rewind — so the next start resumes the true end state)
/// + the worktree checkpoint commit for any edits an interrupted/aborted
/// final turn left uncommitted. Moved out of main() verbatim (600-line
/// goal); `root` is already stable main()-owned storage.
pub fn finalizeSession(gpa: Allocator, io: Io, arena: Allocator, out: *Io.Writer, root: *agent_mod.Agent, json_mode: bool) !void {
    // Live children still use the session's presence/activity storage and
    // must publish their final ledger rows before the last session save.
    @import("subagent.zig").agentJobsReap(gpa, io);
    // Task-outcome telemetry: a working goal that never completed counts as
    // abandoned. Before presence.retire so the event can't outlive the flush.
    @import("task_outcome.zig").noteSessionEnd(root);
    @import("session_globals.zig").release(gpa, io); // retire presence, free gpa-owned globals
    // #1193: deferred past the final save, which writes g_cwd_display.
    defer @import("workspace_switch.zig").deinitDisplay(gpa);
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
    if (!json_mode) try out.writeAll("\n"); // TTY restore; ACP's writer is JSON-RPC
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

/// Start a detached `graff learn init` of this binary. Best effort: a machine
/// that cannot spawn simply does not learn, and the marker learn_auto already
/// claimed keeps that from being retried every session. Suite generation
/// (~38s) must not sit on `-p` / REPL / TUI teardown.
fn autoInitLearning(gpa: Allocator, io: Io) bool {
    std.debug.print("↺ setting this workspace up to learn from sessions like this one\n", .{});
    const exe_path = std.process.executablePathAlloc(io, gpa) catch {
        std.debug.print("↺ learning setup skipped — `graff learn init` to retry\n", .{});
        return false;
    };
    defer gpa.free(exe_path);
    if (!learn_auto.startInit(io, exe_path)) {
        std.debug.print("↺ learning setup skipped — `graff learn init` to retry\n", .{});
        return false;
    }
    std.debug.print(
        "↺ learning setup started in the background — `graff learn status`, off with GRAFF_LEARN_AUTO=off\n",
        .{},
    );
    return true;
}

/// One-shots and `--json` are not a workspace opting into a spending cadence.
/// `-p` evals land on exactly 5 model calls (the bootstrap floor) and then
/// copy 132M `graff-pinned` + generate suites (~38s CPU). Interactive
/// REPL/TUI/ACP still auto-init. Off with `GRAFF_LEARN_AUTO=off`.
pub fn shouldAutoLearn(unattended: bool, json_mode: bool) bool {
    return !unattended and !json_mode;
}

/// Closing the learning loop: a session that did real model work counts toward
/// this workspace's next trial and, on cadence, starts one in the background.
/// The first such session also starts `graff learn init` detached so teardown
/// does not wait on suite generation; the next session that finds a store
/// starts the cadence.
pub fn startBackgroundLearning(gpa: Allocator, arena: Allocator, io: Io, environ_map: *const std.process.Environ.Map, budget: *const run_budget_mod.RunBudget, telemetry_allowed: bool) void {
    if (comptime !@import("build_options").learn) return;
    if (!shouldAutoLearn(main_mod.unattended, main_mod.json_mode)) return;
    const options: learn_auto.Options = .{
        .model_calls = budget.used(),
        // A session launched with --no-telemetry keeps its trial local, even
        // though the child process would not inherit that flag.
        .contribute = telemetry_allowed and main_mod.g_fleet and learning_privacy.allowsAggregate(),
    };
    switch (learn_auto.maybeStart(gpa, arena, io, environ_map, options)) {
        .started => |started| reportTrialStarted(started),
        .needs_store => _ = autoInitLearning(gpa, io),
        .skipped => {},
    }
}
