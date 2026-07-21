//! Agent-boot + run-loop entry helpers, split out of session_start.zig
//! (600-line goal — session_start.zig itself crossed the line goal once
//! this content grew). Covers everything from approvals/hooks/fleet-type
//! loading through Agent construction, the `graff repl`/one-shot early-exit
//! paths, session resume/finalize, and the skills/theme/PTY self-tests
//! setup.
//!
//! Same dangling-pointer discipline as session_start.zig: `buildRootAgent`
//! returns `agent_mod.Agent` by value — safe because its pointer fields
//! (snapshots/client/tracer/approvals/registry) all reference storage the
//! CALLER already placed at a stable, final address (passed in by pointer),
//! not anything local to this function. `runReplCommand`/`runOneshotPrompt`/
//! `restoreResumedSession`/`finalizeSession` take `root: *agent_mod.Agent` —
//! by the time any of these run, `root` is already stable main()-owned
//! storage, so passing its address around is ordinary pointer-passing.
//! `setupSkillsAndTheme` hands back which reset `defer`s main() needs to
//! register itself (registering a `defer` in here would fire it when THIS
//! function returns, not when main() does).
//!
//! Back-imports main (as main_mod) for Agent/the mutable globals it sets.
//! Sibling-imports everything else directly.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const approvals_mod = @import("approvals.zig");
const tools_mod = @import("tools.zig");
const http = @import("http.zig");
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig"); // codex_ws_idle_ms override (#codex-ws)
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const pricing = @import("pricing.zig");
const skills = @import("skills.zig");
const anim = @import("anim.zig");
const mcp = @import("mcp.zig");
const jobs = @import("jobs.zig");
const trace = @import("trace.zig");
const scoring = @import("scoring.zig");
const recipe = @import("recipe.zig");
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");
const ansi = @import("ansi.zig");
const title_mod = @import("title.zig");
const repl = @import("repl.zig");
const pickers = @import("pickers.zig");
const repl_glue = @import("repl_glue.zig");
const providers = @import("providers.zig");
const messages_mod = @import("messages.zig");
const session = @import("session.zig");
const fleet = @import("fleet.zig");
const hooks = @import("hooks.zig");

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
    main_mod.unattended = true;
    root.in = null; // gate: deny instead of prompt; ask_user: self-decide
    root.out = null; // tool progress → stderr; stdout carries only the answer
    root.stream_quiet = true;
    const ultracode_msg = try pickers.applyUltracodeSteering(arena, prompt_text, prompt_text, root.ultracode_mode or root.reasoning == .ultra);
    if (ultracode_msg.explicit) {
        tracer.note("ultracode", prompt_text[0..@min(prompt_text.len, 120)]);
        if (telemetry.g_telem) |t| t.ultracode();
    }
    const goal_note = try repl_glue.goalSteeringNote(arena, root.goal, if (root.todos.items.len > 0) root.renderTodos() else "");
    const eval_note = try repl_glue.evalSteeringNote(arena, root.eval_cmd, root.eval_target, root.eval_judge != null);
    var oneshot_user = if (goal_note.len > 0) try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ ultracode_msg.text, goal_note }) else ultracode_msg.text;
    if (eval_note.len > 0) oneshot_user = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ oneshot_user, eval_note });
    try root.messages.append(try messages_mod.textMessage(arena, "user", oneshot_user));
    if (telemetry.g_telem) |t| t.countTurn();
    const final_text = providers.runTurnWithFallback(root, keys, arena, null) catch |err| {
        // std.process.fatal does not unwind main's defers. Mirror their normal
        // order here: join the fleet worker, reap background jobs and pumps,
        // then emit/upload the terminal behavioral event.
        fleet.joinElites(io);
        jobs.jobsReap(gpa, io);
        // Mirror main's teardown fully: flush buffered OTLP telemetry too,
        // not just the behavioral batch, so a fatal one-shot is not invisible
        // in ordinary telemetry while visible in behavioral data.
        if (telemetry.g_telem) |t| t.flush();
        if (tracer.behavior) |behavior| behavior.finish(.failed);
        switch (err) {
            error.FallbackConsentRequired => std.process.fatal("saved model unavailable; provider '{s}' is not allowlisted — run graff interactively, then /fallback allow {s}", .{ root.provider.id, root.provider.id }),
            error.ApiError => std.process.fatal("{s}", .{root.last_api_error orelse "api error"}),
            else => |e| std.process.fatal("turn failed: {t}", .{e}),
        }
    };
    try out.print("{s}\n", .{final_text});
    try out.flush();
    // Usage summary → stderr, so stdout stays exactly the answer.
    var ubuf: [256]u8 = undefined;
    var uw: Io.Writer = .fixed(&ubuf);
    if (pricing.CostTally.render(pricing.g_cost.snap(io), &uw)) {
        std.debug.print("[usage] {s}\n", .{uw.buffered()});
    } else |_| {}
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
}

/// Loads persisted command/tool approvals + lifecycle hooks + the MAP-Elites
/// agent-type registry (builtins + .harness/agents/*.md), and prints the
/// startup status lines for both. Moved out of main() (600-line goal).
/// `approvals` is an out-param: main() declares it (`var approvals: Approvals
/// = undefined;`) and this fills it in place, so main() can still register
/// its own `defer` for `approvals.prefixes` right after the call (a `defer`
/// registered inside this helper would fire at the WRONG time — when this
/// function returns, not when main() does).
pub fn initApprovalsHooksFleet(io: Io, gpa: Allocator, arena: Allocator, environ_map: anytype, approvals: *approvals_mod.Approvals, flags: args.Flags, out: *Io.Writer, json_mode: bool) !void {
    approvals.* = .{ .yolo = flags.yolo_flag };
    const persisted_approvals = approvals.loadPersisted(io, gpa, arena);

    // Agent types: builtins + .harness/agents/*.md (the MAP-Elites niches).
    fleet.g_home = keys_cli.homeEnv(environ_map); // for /agents promote's personal tier
    fleet.g_agent_types = fleet.loadAgentTypes(io, arena, fleet.g_home); // builtin < ~/.harness/agents (personal) < ./.harness/agents (private)
    if (persisted_approvals > 0 and !json_mode and flags.oneshot_prompt == null) {
        try out.print("{s}loaded {d} saved approval(s) from {s}{s}\n", .{ ansi.style.dim, persisted_approvals, approvals_mod.Approvals.settings_path, ansi.style.reset });
        try out.flush();
    }
    // Lifecycle hooks (pre_tool/post_tool/turn_end) from the same file.
    // (Per-skill opt-outs were loaded earlier, before the muonry auto-connect.)
    main_mod.g_hooks = hooks.loadHooks(io, arena);
    if (main_mod.g_hooks.total() > 0 and !json_mode and flags.oneshot_prompt == null) {
        try out.print("{s}loaded {d} lifecycle hook(s) from {s} — /hooks lists them{s}\n", .{ ansi.style.dim, main_mod.g_hooks.total(), approvals_mod.Approvals.settings_path, ansi.style.reset });
        try out.flush();
    }
}

/// Constructs the root Agent: snapshots/client/tracer/approvals/registry are
/// all ALREADY stable main()-owned storage by the time this is called (the
/// caller passes their addresses in), so this returns `agent_mod.Agent` by
/// value safely — its pointer fields reference external, already-placed
/// storage, not anything local to this function (see this file's header).
/// Also does the post-construction config (session name, persisted
/// thinking/goal/eval settings, the session-start trace note) and kicks off
/// the backgrounded fleet-champion pull, all moved out of main() verbatim
/// (600-line goal).
pub fn buildRootAgent(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *std.http.Client,
    default_provider: provider_mod.Provider,
    environ_map: anytype,
    out: *Io.Writer,
    in: *Io.Reader,
    registry: ?*mcp.Registry,
    approvals: *approvals_mod.Approvals,
    tracer: *trace.Tracer,
    sys_normal: []const u8,
    sys_strict: []const u8,
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
        .home = keys_cli.homeEnv(environ_map) orelse "",
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "main",
        .out = out,
        .in = in,
        .registry = registry,
        .approvals = approvals,
        .tracer = tracer,
        .sys_normal = sys_normal,
        .sys_strict = sys_strict,
        .tools_anthropic = "",
        .tools_openai = "",
        .tools_responses = "",
    };
    // Startup pays for one provider format, not all three. Other formats are
    // rendered on first switch with the same built-in + live MCP inputs.
    try root.ensureRootTools(default_provider.kind);
    const fresh_session_name = try std.fmt.allocPrint(arena, "session-{d}", .{util.unixMs(io)});
    root.session_name = if (flags.resume_flag) |name| (if (!flags.new_session_flag and !flags.no_resume_flag) name else fresh_session_name) else fresh_session_name;
    repl_glue.loadThinkingSettings(io, arena, &root); // {"effort":...,"fast":...} persisted by /effort and /fast
    if (flags.goal_flag) |g| root.goal = .{ .objective = try arena.dupe(u8, g), .status = .active, .created_ms = util.unixMs(io), .updated_ms = util.unixMs(io) }; // --goal applies to every turn (incl. --json/-p/SDK)
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
    if (!json_mode and root.messages.items.len > 0) {
        session.saveSession(root, arena, root.session_name) catch |err| {
            out.print("{s}⚠ session save failed: {t}{s}\n", .{ ansi.style.yellow, err, ansi.style.reset }) catch {};
            out.flush() catch {};
        };
        out.print("{s}↩ session saved → {s}{s}{s}\n", .{ ansi.style.dim, root.session_name, ansi.style.reset, session.session_ext }) catch {};
        out.flush() catch {};
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

pub const ThemeSetup = struct {
    theme_on: bool,
    limyuxi_glam: bool,
    /// True when a PTY self-test already ran + printed its render — main()
    /// should return immediately without going any
    /// further (but AFTER registering the theme/limyuxi reset defers below,
    /// exactly like the original inline code did).
    should_exit: bool,
};

/// Per-skill/companion opt-outs, animation + terminal-theme settings, the
/// headless PTY render self-tests, and the
/// yxlyx-birthday cosmetic theme. Moved out of main() verbatim (600-line
/// goal). Returns which reset defers main() needs to register — the
/// escape-code RESETS must fire when main() itself returns (not when this
/// helper returns), so the `defer`s stay in main(), gated on the booleans
/// this returns; main() registers them in the same order as the original
/// inline code so LIFO defer-firing order is unchanged.
pub fn setupSkillsAndTheme(io: Io, arena: Allocator, environ_map: anytype, out: *Io.Writer, flags: args.Flags, use_color: bool, json_mode: bool, cwd_display: []const u8) !ThemeSetup {
    // Companion auto-activation: if the metered code-intelligence companion
    // (codedb-pro, formerly muonry) is installed but nothing connected it (no
    // workspace .mcp.json entry, or consent declined), spawn it directly — a
    // user-installed companion at the same trust level as the skills
    // auto-detection above it, NOT arbitrary workspace config.
    main_mod.g_path_env = try arena.dupe(u8, environ_map.get("PATH") orelse "");
    main_mod.g_codedb_guard = environ_map.get("GRAFF_NO_CODEDB_GUARD") == null; // issue #626 guard, opt-out via env
    main_mod.g_force_stall_once = environ_map.get("GRAFF_FORCE_STALL_ONCE") != null; // #134 test seam
    main_mod.g_force_drop_once = environ_map.get("GRAFF_FORCE_DROP_ONCE") != null; // #132/#133 test seam
    main_mod.g_force_stall_always = environ_map.get("GRAFF_FORCE_STALL_ALWAYS") != null; // #56 test seam (exhaust the reconnect budget)
    main_mod.g_force_drop_always = environ_map.get("GRAFF_FORCE_DROP_ALWAYS") != null; // #56 test seam
    // #134: let a provider that buffers a long reasoning phase in total silence
    // raise the mid-stream idle-stall cutoff (default 120s). Seconds; ignored if
    // unparseable or 0. A stall is never a user interrupt regardless of the value.
    if (environ_map.get("GRAFF_STREAM_STALL_SECS")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |secs| {
            if (secs > 0) http.stream_stall_ms = @min(secs, 86_400) * 1000; // clamp: <=1 day, no u64 overflow
        } else |_| {}
    }
    // #codex-ws: GRAFF_CODEX_WS=off|0|false|no (case-insensitive, the
    // GRAFF_FLEET predicate) forces the SSE transport for codex;
    // GRAFF_WS_DEBUG=1 dumps the ws handshake + frames to stderr. This is the
    // SOLE parse site for the codex transport knobs — a copy in main() would
    // be silently overwritten here, since setupSkillsAndTheme runs later.
    if (environ_map.get("GRAFF_CODEX_WS")) |v| {
        main_mod.g_codex_ws = !(std.ascii.eqlIgnoreCase(v, "off") or std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no"));
    }
    // #225: GRAFF_CLOCK_SLEEP=1|true|on|yes arms the root-only clock_sleep
    // meta tool (in addition to --clock-sleep). Affirmative-only, like
    // GRAFF_WS_FORCE_FAIL_ONCE below — OR'd onto the CLI flag so a
    // conflicting/absent env value never silently turns --clock-sleep back
    // off; default stays off.
    if (environ_map.get("GRAFF_CLOCK_SLEEP")) |v| {
        main_mod.g_clock_sleep = main_mod.g_clock_sleep or std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes");
    }
    // (#codex-ws) GRAFF_CODEX_WS_IDLE_SECS raises/lowers the held-WS idle limit
    // (default 4 min — the backend killed ours within 8.5 min idle; opencode
    // pools at 5). Mirrors GRAFF_STREAM_STALL_SECS above: seconds, ignored if
    // unparseable or 0, clamped to <=1 day.
    if (environ_map.get("GRAFF_CODEX_WS_IDLE_SECS")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |secs| {
            if (secs > 0) agent_ws.codex_ws_idle_ms = @intCast(@min(secs, 86_400) * 1000);
        } else |_| {}
    }
    // #203: GRAFF_CONTEXT / GRAFF_CONTEXT_WINDOW declares the context window (in
    // tokens) for an unknown/local model whose real window graff can't look up,
    // replacing the conservative 200k fallback so the compaction gate + per-output
    // cap are sized correctly. Only affects models that fall back to the default
    // (see provider.contextWindowFor). Ignored if unparseable or 0.
    if (environ_map.get("GRAFF_CONTEXT") orelse environ_map.get("GRAFF_CONTEXT_WINDOW")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |n| {
            if (n > 0) provider_mod.g_context_override = n;
        } else |_| {}
    }
    // #204: GRAFF_COMPACT_PCT overrides the auto-compaction threshold as a percent
    // of the window (default 80). Clamped to 1..100; ignored if unparseable or 0.
    if (environ_map.get("GRAFF_COMPACT_PCT")) |v| {
        if (std.fmt.parseInt(u8, std.mem.trim(u8, v, " \t"), 10)) |pct| {
            if (pct > 0) provider_mod.g_compact_pct_override = @min(pct, 100);
        } else |_| {}
    }
    ws.g_debug = environ_map.get("GRAFF_WS_DEBUG") != null;
    // GRAFF_WS_FORCE_FAIL_ONCE proves a clean retry; the counted sibling proves
    // that two consecutive failures latch the SSE fallback. Test seams only.
    if (environ_map.get("GRAFF_WS_FORCE_FAIL_ONCE")) |v| {
        ws.g_force_connect_failure_once = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes");
    }
    if (environ_map.get("GRAFF_WS_FORCE_FAIL_COUNT")) |v| {
        ws.g_force_connect_failure_count = std.fmt.parseInt(u8, std.mem.trim(u8, v, " \t"), 10) catch 0;
    }
    skills.loadSkillSettings(io, arena); // per-skill opt-outs, also gates the auto-connect
    anim.loadAnimationSetting(io, arena); // {"animation": "..."} → thinking spinner choice
    anim.loadThemeSetting(io, arena); // {"theme": "<name>"} → opt-in terminal color theme
    const theme_on = anim.g_theme != null and use_color and !json_mode;
    if (theme_on) {
        out.writeAll(anim.themes[anim.g_theme.?].seq) catch {};
        out.flush() catch {};
    }
    // 🎂 yxlyx's birthday glam — when graff runs from her home dir, dress her
    // Ghostty in the pastel-pink theme (limyuxi_theme: light pink bg, dark plum
    // text, pink-leaning palette) and switch the spinner to glittery sparkles.
    // Cosmetic, flagged, gated to her cwd; resets everything on exit.
    const limyuxi_glam = anim.limyuxi_birthday_white and use_color and !json_mode and
        (std.mem.eql(u8, cwd_display, "/Users/limyuxi") or std.mem.startsWith(u8, cwd_display, "/Users/limyuxi/"));
    if (limyuxi_glam) {
        out.writeAll(anim.limyuxi_theme) catch {};
        out.flush() catch {};
        if (anim.animIndex("dragon")) |gi| {
            anim.g_anim_index = gi;
            anim.g_anim_off = false;
            anim.g_anim_random = false;
        }
    }
    if (flags.selftest_spinner_flag) {
        // Headless render of the real thinking-spinner pool for the PTY anti-stealth
        // test (scripts/test-pty-spinner.py): runs the real selection (so a cwd-gated
        // pick surfaces) and prints every frame fn's output to stdout, where the test
        // scans for the U+1F4A9 / supplementary-plane glyph class the poop hid in.
        anim.selectSpinner(io);
        out.print("selected: {s}\n", .{anim.anims[anim.g_anim_current].name}) catch {};
        for (anim.anims) |a| {
            var i: usize = 0;
            while (i < 48) : (i += 1) {
                a.frame(out, i) catch {};
                out.writeByte('\n') catch {};
            }
        }
        out.flush() catch {};
        return .{ .theme_on = theme_on, .limyuxi_glam = limyuxi_glam, .should_exit = true };
    }
    if (flags.selftest_markdown_flag) {
        var probe: agent_mod.Agent = .{
            .gpa = arena,
            .arena = arena,
            .io = io,
            .client = undefined,
            .provider = undefined,
            .messages = undefined,
            .sub = false,
            .label = "markdown-selftest",
            .out = out,
        };
        probe.streamMarkdown(
            \\## Gaps
            \\- No bot-specific route tests exist.
            \\- Pin `install.sh` and verify its checksum.
            \\
            \\## Recommended implementation order
            \\1. **Immediately:** require collaborator permission.
            \\2) **Next:** deduplicate `X-GitHub-Delivery`.
            \\- [ ] Add a Daytona credential preflight.
            \\- [x] Sanitize public errors.
            \\  - Preserve private incident detail.
            \\> Public errors must never expose secrets.
        );
        probe.flushStreamTail();
        out.writeByte('\n') catch {};
        out.flush() catch {};
        return .{ .theme_on = theme_on, .limyuxi_glam = limyuxi_glam, .should_exit = true };
    }
    anim.loadDevSpinnerOptOut(io, arena, environ_map);
    return .{ .theme_on = theme_on, .limyuxi_glam = limyuxi_glam, .should_exit = false };
}
