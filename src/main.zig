//! simple-harness — a minimal, dependency-free agentic loop supporting
//! Anthropic and OpenAI-compatible providers, built-in/meta/MCP tools,
//! parallel agents, strict tool-call mode, client-side compaction, and
//! run-exclusive JSONL tracing under `.graff/traces`.
const std = @import("std");
const Io = std.Io;
const http_warm = @import("http_warm.zig");
pub const prewarmCaBundle = http_warm.prewarmCaBundle;
const prewarmCaBundleTask = http_warm.prewarmCaBundleTask;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
// The interactive-REPL / --json-protocol loop lives in mainloop.zig; main() builds a Ctx of pointers into its own stack locals and calls run() once.
const mainloop = @import("mainloop.zig");
const builtin = @import("builtin");
// Agent's method bodies are split across agent_*.zig as free `pub fn method(self: *Agent, ...)` functions, aliased back into `struct Agent`; imported here only to keep their test{} blocks running.
const agent_table = @import("agent_table.zig");
const agent_argstream = @import("agent_argstream.zig");
const agent_render = @import("agent_render.zig");
const agent_steps = @import("agent_steps.zig");
const agent_compact = @import("agent_compact.zig");
const agent_compact_test = @import("agent_compact_test.zig");
const agent_ws_test = @import("agent_ws_test.zig");
const run_budget_mod = @import("run_budget.zig");
const agent_tools = @import("agent_tools.zig");
const agent_request = @import("agent_request.zig");
const agent_interrupt = @import("agent_interrupt.zig");
const agent_stream = @import("agent_stream.zig");
pub const anthropic_version = "2023-06-01";
pub const max_tokens = 16000;
pub const mcp_config_path = ".mcp.json";
// style is a live pointer-alias into ansi.style; main flips it to Style.ansi at startup once stdout is confirmed a color-capable TTY.
const ansi = @import("ansi.zig");
pub var use_color = false; // stdout is a TTY and NO_COLOR unset → enables color + markdown
// Optional displays toggled by CLI flags (--timing, --cost).
pub var show_timing = false;
pub var show_cost = false;
pub var json_mode = false; // --json: structured JSONL events on stdout instead of human text
pub var g_codex_ws = true; // root Codex turns use the WebSocket transport (Responses API over wss) with SSE fallback; GRAFF_CODEX_WS=off|0 forces SSE
pub var g_clock_sleep: bool = false; // #225: root-only clock_sleep meta tool, off by default; --clock-sleep / GRAFF_CLOCK_SLEEP=1 turns it on (gates advertising in renderRootTools, mirrors g_codex_ws)
pub var g_force_stall_once: bool = false; // #134 test seam (GRAFF_FORCE_STALL_ONCE=1): the next live turn returns error.StreamStalled — proves the stall path is never labeled a user Esc
pub var g_force_drop_once: bool = false; // #132/#133 test seam (GRAFF_FORCE_DROP_ONCE=1): the next live turn returns error.StreamDropped
pub var g_force_stall_always: bool = false; // #56 test seam (GRAFF_FORCE_STALL_ALWAYS=1): EVERY live attempt stalls, so the reconnect budget exhausts and the turn ends as a stall — exercises the give-up path offline
pub var g_force_drop_always: bool = false; // #56 test seam (GRAFF_FORCE_DROP_ALWAYS=1): EVERY live attempt drops
pub var max_tool_calls: ?u64 = null; // --max-tool-calls: hard per-turn root tool budget
pub var max_model_calls: u64 = run_budget_mod.default_max_model_calls; // invocation-wide, shared by root/children/title/judges; 0 = unlimited (default)
pub var dedupe_tool_calls = false; // --dedupe-tool-calls: reject duplicate root calls in a turn
pub var plan_mode = false; // /plan: read-only — mutating tools are denied, the model proposes
pub var unattended = false; // -p one-shot: no human to prompt; unapproved tool calls are denied
const pricing = @import("pricing.zig"); // model pricing/catalog + session cost tally
const models_cache = @import("models_cache.zig"); // graff models [refresh]: models.dev metadata cache + runtime overlay
const command_catalog = @import("command_catalog.zig");
const util = @import("util.zig"); // shared JSON ObjectMap getters (strFieldObj/intFieldObj)
const learn_store = @import("learn_store.zig");
const learn_eval = @import("learn_eval.zig");
const learn_cli = @import("learn_cli.zig");
test {
    // build.zig's unit_tests root is main.zig only — reference every split-out module so their test blocks keep running.
    _ = pricing;
    _ = models_cache;
    _ = ansi;
    _ = serve;
    _ = util;
    _ = learn_store;
    _ = learn_eval;
    _ = learn_cli;
    _ = oauth;
    _ = anim;
    _ = approvals_mod;
    _ = hooks;
    _ = schema;
    _ = fleet;
    _ = messages_mod;
    _ = http;
    _ = terminal;
    _ = scoring;
    _ = telemetry;
    _ = trace;
    _ = cards;
    _ = jobs;
    _ = title_mod;
    _ = serde;
    _ = mcp_cli;
    _ = cli;
    _ = prompts;
    _ = session;
    _ = keys_cli;
    _ = repl_glue;
    _ = vision;
    _ = providers;
    _ = pickers;
    _ = skills;
    _ = input_util;
    _ = readline_mod;
    _ = tools_mod;
    _ = subagent;
    _ = workflow;
    _ = exec;
    _ = commands_session;
    _ = commands_model;
    _ = commands_misc;
    _ = agent_table;
    _ = agent_argstream;
    _ = agent_render;
    _ = agent_steps;
    _ = agent_compact;
    _ = agent_compact_test;
    _ = agent_ws_test;
    _ = agent_tools;
    _ = agent_request;
    _ = agent_interrupt;
    _ = agent_stream;
    _ = mainloop;
    _ = args;
    _ = startup;
    _ = startup_timing;
    _ = session_start;
    _ = session_run;
    _ = provider_mod;
    _ = agent_mod;
}
// System-prompt text (main_system_prompt, strict_note, main_system_prompt_strict, sub_system_prompt, compact_instruction) lives in prompts.zig.
const prompts = @import("prompts.zig");
// Tool-schema + provider-tool JSON emission lives in schema.zig; serve.zig/startup.zig import it directly. Kept here to pull in its test{} block.
const schema = @import("schema.zig");
// The provider/keys core (ProviderSpec/provider_specs, Provider, Keys) lives in provider.zig; provider_specs/Keys stay local aliases for main()'s credential setup and tests.
const provider_mod = @import("provider.zig");
const provider_specs = provider_mod.provider_specs;
pub const Keys = provider_mod.Keys;
// Approvals (command/tool approval gate) + confinedPath/noSymlinkEscape live in approvals.zig; main() constructs one directly for the session.
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
// Operational tracing, per-run behavioral traces, and run-scoped DGM
// trajectory files live in trace.zig.
const trace = @import("trace.zig");
const Tracer = trace.Tracer;
const BehaviorTrace = trace.BehaviorTrace;
const behavior_trace = @import("behavior_trace.zig");
const behavior_upload = @import("behavior_upload.zig");
const learning_privacy = @import("learning_privacy.zig");
const Trajectory = trace.Trajectory;
const behavior_dir = trace.behavior_dir;
const trajectory_path = trace.trajectory_path;
const trace_path = trace.trace_path;
// Agent types / MAP-Elites fleet.
const fleet = @import("fleet.zig");
const joinElites = fleet.joinElites;
const scoring = @import("scoring.zig");
const cards = @import("cards.zig");
const telemetry = @import("telemetry.zig");
/// Fleet master switch; learning privacy is the independent default-local egress gate.
/// General usage telemetry is separate (GRAFF_NO_TELEMETRY).
pub var g_fleet: bool = true;
const unixMs = util.unixMs;
/// Reasoning depth for codex/responses (OpenAI Responses `reasoning.effort`).
pub const ReasoningEffort = enum { low, medium, high, xhigh, max, ultra };
pub const repl_commands = command_catalog.names;
// Lifecycle hooks (Hook/Hooks config types + settings loader + per-hook subprocess runner) live in hooks.zig; g_hooks below, dispatch, and the codedb-guard cache stay here.
const hooks = @import("hooks.zig");
pub var g_hooks: hooks.Hooks = .{};
/// Built-in codedb guard (issue #626): blocks a bash command that scans/reads a concrete source file, redirecting to the codedb tool instead —
/// without this, agents reflexively grep/cat and never touch the structural tools. Off when GRAFF_NO_CODEDB_GUARD is set; the tri-state cache
/// records whether `codedb` is actually on PATH (no redirect if it isn't).
pub var g_codedb_guard = true;
pub var g_codedb_present: ?bool = null;
// Codex-style optional skills / companion-server subsystem lives in skills.zig (companionRoute/companionNativeFallback stay in tools.zig); g_path_env/g_skill_disabled/g_companion_disabled stay pub var here, read/written live via main_mod.g_x.
const skills = @import("skills.zig");
const skills_registry = skills.skills_registry;
const companion_servers = skills.companion_servers;
const mcpServerConnected = skills.mcpServerConnected;
const probeCodedbproLicensed = skills.probeCodedbproLicensed;
/// PATH captured at startup for skill detection (PATH won't change mid-run).
pub var g_path_env: []const u8 = "";
/// Human-facing current workspace folder shown in the REPL prompt.
pub var g_cwd_display: []const u8 = ".";
pub var g_worktree_branch: ?[]const u8 = null; // -w: the worktree's scratch branch; non-null = auto-commit each turn's edits to it
pub var g_worktree_autocommit: bool = true; // --no-autocommit turns off the per-turn checkpoint commits
/// #124: allocator-level leak telemetry (GRAFF_MEM_DEBUG=1): the process-lifetime
/// session arena, queryable at turn boundaries so a per-turn `mem` event can
/// report its capacity next to the scratch arena's.
pub var g_session_arena: ?*std.heap.ArenaAllocator = null;
pub var g_mem_debug: bool = false;
/// Short task label for terminal/TUI headers (mirrors the GUI's first-prompt fallback: the user's first message as a compact tab/session title).
// Session-title + header rendering + provider-response text parsers live in title.zig.
const title_mod = @import("title.zig");
/// Opaque context handed to repl.run so the REPL can run a real agent turn — reuses the root agent's tool set, MCP registry, and system prompt
/// (built in main()); no harness internals leak into repl.zig, it only sees a callback.
// The `graff repl` bridge, steering-note assembly, steering queue drain, and /effort /fast /ultracode persistence live in repl_glue.zig. SteerEntry
// is read from here; the mutable steer/thinking globals stay here, read/written live via `main_mod.g_x` (never aliased — they're `var`s).
const repl_glue = @import("repl_glue.zig");
const fallback_config = @import("fallback_config.zig");
/// Per-skill user opt-out, persisted as {"skills": {"kuri": false}} in .harness/settings.json. A disabled skill is treated as not installed
/// anywhere — no system-prompt note, /skills shows it disabled, and webfetch never shells out to it, even when its binaries are on PATH.
pub var g_skill_disabled: [skills_registry.len]bool = @splat(false);
/// Same opt-out, for the metered companion MCP servers (codedb-pro) — they live in companion_servers, NOT skills_registry, so need their own flags.
pub var g_companion_disabled: [companion_servers.len]bool = @splat(false);
/// True when `codedb-pro probe` exits 0 (paid + usable); set once at startup after the companion connects, selecting the licensed vs conservative note.
var g_codedbpro_licensed: bool = false;
// Thinking animations: spinner animations + color themes (+ settings persistence) live in anim.zig; spinner consumers (Agent.spinnerTask, /animation, /theme) stay here.
const anim = @import("anim.zig");
// Steering (Codex-style): bytes typed while a turn streams are captured (not discarded), echoed live in dim coral, and queued to run next on Enter —
// follow-ups queue without waiting for the turn to finish. TTY-only (raw-stdin esc-watch is off in --json/GUI mode); watchdog/select arms may
// drain/echo stdin while the stream reader is blocked, so g_steer_visible pauses spinner redraws to keep the live row intact.
pub var g_steer_buf: std.ArrayList(u8) = .empty; // in-progress line (page-alloc)
const SteerEntry = repl_glue.SteerEntry; // struct { text: []const u8, force: bool }
pub var g_steer_queue: std.ArrayList(SteerEntry) = .empty; // completed lines
pub var g_steer_echoed = false; // "↳ steer ›" prefix shown for the current line
pub var g_steer_visible: std.atomic.Value(bool) = .init(false); // visible live steering row; pauses spinner redraws
pub var g_steer_lock: std.atomic.Value(bool) = .init(false); // spin-guards g_steer_queue/g_steer_buf mutations across concurrent drainers (main reader + pool esc-watch/watchdog arms) so one submit never flushes as N entries (#129); acquire via repl_glue.steerLock
pub var g_out: ?*Io.Writer = null; // stdout writer for steer echo (set in main)
pub var g_gui_mu: Io.Mutex = .init; // serializes --json stdout across pool-thread subagent emits (guiEmit + printDelta)
pub var g_force_interrupt = false; // Force-prompt path caused the last interrupt (Ctrl-F/double-enter).
pub var g_thinking_fold_request: bool = false; // Ctrl-T in escPressed → fold/unfold the live Thinking block (#92)
pub var g_thinking_open: bool = false; // a live Thinking block is on screen (gates the mouse-click fold, #92)
pub var g_5xx_body_buf: [600]u8 = undefined; // snippet of the last 5xx/429 error body
pub var g_5xx_body_len: usize = 0; // 0 = no body captured
pub var g_retry_after_ms: u64 = 0; // #retry-after: provider Retry-After (429/503) in ms, honored by request()'s throttle backoff; 0 = use our computed backoff
// fillCompletions/wrapAt/LineRender/parseDsrCol live in input_util.zig.
// Terminal primitives (Windows console shim + cross-platform raw-mode tty layer + size/poll/row-count helpers) live in term.zig; tty is aliased back so call sites stay unqualified.
const terminal = @import("term.zig");
const tty = terminal.tty;
// The rest of the line editor's input helpers live in input_util.zig; readLine()/HistoryNav live in readline.zig. binaryFileExt is aliased back for a read_file guard below.
const input_util = @import("input_util.zig");
const readline_mod = @import("readline.zig");
// Session persistence (last model, input history) + the wire-format message serializers live in serde.zig (std-only leaf).
const serde = @import("serde.zig");
const loadHistory = serde.loadHistory;
const saveHistory = serde.saveHistory;
pub const harness_version: []const u8 = @import("build_options").version;
/// OTLP endpoint baked into release builds (-Dtelemetry-endpoint); "" in dev builds means telemetry stays off unless an env var configures it.
/// Used as the lowest-precedence telemetry endpoint, below env overrides and opt-out.
const default_telemetry_endpoint: []const u8 = @import("build_options").telemetry_endpoint;
// `graff update` (release check + install.sh delegation) + --version/--help text live in cli.zig.
const cli = @import("cli.zig");
// CLI flag parsing (the Flags struct) lives in args.zig; main() calls args.parse once and reads flags.<name> throughout.
const args = @import("args.zig");
// Post-arg-parse setup (resolveKeys, buildSystemPrompt, early subcommand dispatch) lives in startup.zig; everything after credentials/http.Client exist lives in sibling session_start.zig.
const startup = @import("startup.zig");
const startup_timing = @import("startup_timing.zig");
const session_start = @import("session_start.zig");
const session_run = @import("session_run.zig");
pub fn main(init: std.process.Init) !void {
    var boot = startup_timing.Tracker.init(init.io, init.environ_map.get("GRAFF_BOOT_DEBUG") != null);
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    // #122: raise the open-file soft limit to the OS hard cap (Darwin defaults
    // to 256) so parallel tool/subagent/MCP fan-out in one turn doesn't blow up
    // shell tools with ProcessFdQuotaExceeded. Best-effort, no-op where rlimits
    // don't exist.
    std.process.raiseFileDescriptorLimit();
    // #124: a per-turn scratch arena for the root agent's transient parse garbage,
    // reset each request() so a long REPL/--json/serve session's RSS stays flat.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    defer hooks.deinitCodedbCache(gpa, io);
    g_session_arena = init.arena;
    g_mem_debug = init.environ_map.get("GRAFF_MEM_DEBUG") != null;
    // Windows: let the console interpret ANSI/VT escapes so the harness's color and cursor sequences render instead of literal text.
    if (builtin.os.tag == .windows) tty.enableVtOutput();
    // Environment supplies the default; an explicit CLI flag parsed below has
    // the usual higher precedence for this invocation.
    if (init.environ_map.get("GRAFF_MAX_MODEL_CALLS")) |raw| {
        max_model_calls = std.fmt.parseInt(u64, raw, 10) catch
            std.process.fatal("GRAFF_MAX_MODEL_CALLS needs a non-negative integer, got '{s}'", .{raw});
    }
    // CLI flags: the Flags struct + parsing loop live in args.zig; downstream code reads flags.<name> in place of ~27 locals this block used to declare.
    const flags = try args.parse(init);
    learning_privacy.init(flags.learning_privacy_flag, init.environ_map.get("GRAFF_LEARNING_PRIVACY"));
    var invocation_budget: run_budget_mod.RunBudget = .{ .max_model_calls = max_model_calls };
    boot.mark(init.io, "args");
    // GRAFF_CODEX_URL: override the codex responses endpoint (localhost mocks / integration tests). Parsed BEFORE subcommand dispatch and
    // resolveKeys — `graff models [refresh]` fetches the catalog inside runSubcommand and the initial Keys.build runs inside resolveKeys.
    // environ_map slices are process-lifetime (resolveKeys stores them into Keys the same way), so the value is kept as-is without duping.
    if (init.environ_map.get("GRAFF_CODEX_URL")) |cu| {
        if (cu.len > 0) provider_mod.g_codex_url_override = cu;
    }
    // --help / --version: handled before any subcommand dispatch, so `harness login --help` prints usage instead of starting an OAuth flow.
    if (try startup.runSubcommand(io, gpa, arena, init, flags)) return;
    // Credential/model resolution (env vars → on-disk logins → `harness key set` store, env always wins; then --model or the last-saved model) lives
    // in startup.zig as resolveKeys() — pure over env/disk/arena, safe to call outside main()'s own stack frame.
    const resolved_keys = try startup.resolveKeys(io, gpa, arena, init.environ_map, flags.model_flag);
    boot.mark(io, "credentials/model");
    var keys = resolved_keys.keys;
    const default_provider = resolved_keys.default_provider;
    const subagent_provider = startup.resolveSubagentProvider(keys, default_provider, flags.subagent_provider_flag orelse init.environ_map.get("GRAFF_SUBAGENT_PROVIDER"), flags.subagent_model_flag orelse init.environ_map.get("GRAFF_SUBAGENT_MODEL"), flags.allow_cross_provider_subagents_flag);
    const stale_saved_model = resolved_keys.stale_saved_model;
    const preferred_provider = resolved_keys.preferred_provider;
    const codex_account = resolved_keys.codex_account;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var client_ready: Io.Event = .unset;
    http.g_client_ready = &client_ready;
    var client_warm_fut = io.async(prewarmCaBundleTask, .{ &client, gpa, io, &client_ready });
    boot.mark(io, "CA warm scheduled");
    defer {
        _ = client_warm_fut.await(io);
        http.g_client_ready = null;
    }
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const in = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;
    g_out = out;

    if (try session_start.runTitleCommand(io, gpa, arena, &client, default_provider, out, flags, &invocation_budget)) return;
    // Generate identity before opening either JSONL. The score channel and both
    // files share this run id; session_id is a separate runtime correlation id.
    session_start.initScoreRunId(io);
    const runtime_session_id = trace.newSessionId(io);
    const identity: trace.Identity = .{
        .run_id = &scoring.g_run_id,
        .pid = trace.currentPid(),
        .session_id = &runtime_session_id,
    };
    const run_trace_path = try trace.tracePath(arena, identity.run_id);
    const run_trajectory_path = try trace.trajectoryPath(arena, identity.run_id);
    try session_start.setupWorktreeAndBanner(io, gpa, arena, init.environ_map, flags, out, run_trace_path, codex_account, stale_saved_model, preferred_provider, default_provider);
    session_start.loadScoreSigningKey(io, arena, init.environ_map);
    boot.mark(io, "banner");

    // Session trace (best-effort: a failed open just disables tracing).
    var trace_buf: [8 * 1024]u8 = undefined;
    var trace_open = session_start.openTraceFile(io, run_trace_path, &trace_buf);
    defer if (trace_open.file) |f| f.close(io);
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = if (trace_open.file != null) &trace_open.writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
        .identity = identity,
        .path = run_trace_path,
    };
    boot.attach(&tracer);

    // One trajectory file per run; the archive reader scans the directory.
    // Node ids restart per run and cross-run lineage threads through prompt_sha.
    var traj_buf: [8 * 1024]u8 = undefined;
    var traj_open = session_start.openTrajFile(io, run_trajectory_path, &traj_buf);
    defer if (traj_open.file) |f| f.close(io);
    var traj: Trajectory = .{
        .io = io,
        .gpa = gpa,
        .out = if (traj_open.file != null) &traj_open.writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
        .identity = identity,
        .path = run_trajectory_path,
    };
    trace.g_traj = &traj;
    defer {
        trace.g_traj = null;
        traj.deinit();
    }
    traj.node(.{ .kind = "session", .version = harness_version, .unix_ms = unixMs(io) });

    var telem = session_start.initTelemetry(io, gpa, &client, init.environ_map, flags, default_telemetry_endpoint);
    telemetry.g_telem = &telem;
    if (init.environ_map.get("GRAFF_FLEET")) |fv| {
        g_fleet = !(std.ascii.eqlIgnoreCase(fv, "off") or std.mem.eql(u8, fv, "0") or std.ascii.eqlIgnoreCase(fv, "false") or std.ascii.eqlIgnoreCase(fv, "no"));
    }
    defer {
        telemetry.g_telem = null;
        telem.flush();
        telem.deinit();
    }

    // MCP servers from .mcp.json. SECURITY: a workspace .mcp.json launches arbitrary local commands, so opening an untrusted repo could run them —
    // auto-connect only with --yolo (trusted) or explicit per-session consent; otherwise start with an empty (but live) registry so `/mcp add`
    // still works.
    const mcp_home = homeEnv(init.environ_map) orelse "";
    var registry_storage = try session_start.initRegistryConsent(io, gpa, arena, out, in, flags, mcp_config_path, mcp_home, use_color, json_mode);
    boot.mark(io, "MCP registry");
    defer registry_storage.deinit();
    const registry: ?*mcp.Registry = &registry_storage;
    // Per-skill/companion opt-outs, animation/theme settings, and the --selftest-spinner headless render live in session_start.zig. The theme/
    // limyuxi-glam reset `defer`s stay HERE (registered in main()'s own frame) so they fire when main() returns, not when the helper does.
    const theme_setup = try session_run.setupSkillsAndTheme(io, arena, init.environ_map, out, flags, use_color, json_mode, g_cwd_display);
    defer if (theme_setup.theme_on) {
        out.writeAll(anim.theme_reset) catch {};
        out.flush() catch {};
    };
    defer if (theme_setup.limyuxi_glam) {
        out.writeAll(anim.limyuxi_reset) catch {};
        out.flush() catch {};
    };
    if (theme_setup.should_exit) return;
    boot.mark(io, "settings/theme");
    try session_start.connectCompanion(io, &registry_storage, flags, out, json_mode, init.environ_map);
    const mcp_tools: []const mcp.Tool = registry_storage.tools;
    // If the metered companion connected, probe its license once so the note below can lean into paid tools (vs the conservative free-codedb note).
    if (mcpServerConnected(mcp_tools, "codedbpro")) g_codedbpro_licensed = probeCodedbproLicensed(gpa, io);
    boot.mark(io, "companion");

    var approvals: Approvals = undefined;
    try session_run.initApprovalsHooksFleet(io, gpa, arena, init.environ_map, &approvals, flags, out, json_mode);
    boot.mark(io, "approvals/hooks/fleet");
    defer {
        for (approvals.prefixes.items) |p| gpa.free(p);
        approvals.prefixes.deinit(gpa);
        for (approvals.plan_read_roots.items) |p| gpa.free(p);
        approvals.plan_read_roots.deinit(gpa);
    }

    // Root system-prompt layering (base + AGENTS.md/HARNESS.md/CLAUDE.md + --append-system-prompt + active-skill lines + connected-MCP notes) lives
    // in startup.zig as buildSystemPrompt() — pure over io/arena, returns both prompt strings by value.
    const sys_prompt = try startup.buildSystemPrompt(
        io,
        arena,
        out,
        flags.system_prompt_flag,
        flags.append_system_flag,
        json_mode or flags.oneshot_prompt != null,
        mcp_tools,
        g_codedbpro_licensed,
    );
    const sys_normal = sys_prompt.sys_normal;
    const sys_strict = sys_prompt.sys_strict;
    boot.mark(io, "system prompt");

    var snaps: Snapshots = .{ .gpa = gpa, .io = io };
    defer snaps.deinit();
    // Keep an early fallback for failures before behavioral tracing is set up.
    // A later guarded defer moves normal reaping ahead of terminal upload.
    var jobs_reaped = false;
    defer if (!jobs_reaped) jobsReap(gpa, io);
    // Background subagents (#276 P0-3) die with the session too, though not
    // killed the same way — see agentJobsReap's doc comment for why. Mirrors
    // jobsReap's early-fallback/later-guarded-defer pattern immediately above.
    var agent_jobs_reaped = false;
    defer if (!agent_jobs_reaped) agentJobsReap(gpa, io);
    // Root Agent construction + post-construction config (session name, persisted thinking/goal/eval settings, session-start trace note) + the
    // backgrounded fleet-champion pull live in session_start.zig. `root`'s pointer fields (snapshots/client/tracer/approvals/registry) all reference
    // already-stable main()-owned storage passed in by address, so returning the constructed Agent by value here is safe.
    var root = try session_run.buildRootAgent(gpa, arena, io, &client, default_provider, subagent_provider, init.environ_map, out, in, registry, &approvals, &tracer, sys_normal, sys_strict, &snaps, flags, telem.endpoint);
    root.run_budget = &invocation_budget;
    root.model_catalog = resolved_keys.model_catalog;
    root.stored_keys_loaded = resolved_keys.stored_keys_loaded;
    root.scratch_arena = &scratch_state; // #124: route the root's transient parse garbage here; reset per request()
    root.fallback_active = stale_saved_model != null;
    root.fallback_blocked = root.fallback_active and preferred_provider != null and !std.mem.eql(u8, preferred_provider.?, root.provider.id) and !fallback_config.contains(root.fallback_allow, root.provider.id);
    boot.mark(io, "root agent");

    // Behavioral tracing starts only after the root Agent exists, so utility
    // and self-test paths do not create zero-turn behavioral runs. The local
    // JSONL and the privacy-projected upload are independent sinks; the Boot
    // owns both, wired and torn down in LIFO order (behavior_trace.zig).
    var behavior_buf: [8 * 1024]u8 = undefined;
    var behavior_boot = behavior_trace.boot(io, gpa, &client, init.environ_map, telem.endpoint, telem.auth_key, telem.install_id, telem.client_name, harness_version, &behavior_buf);
    behavior_boot.link(&tracer);
    // A dead local sink must not be silent: the collision that disabled local
    // capture in every session shipped invisibly because every failure path
    // was a silent null (#246 review). stderr, so JSON/one-shot stdout stays
    // protocol-clean.
    if (behavior_boot.local_sink_failed)
        std.debug.print("warning: behavioral trace file could not be created under {s}; local capture is off for this run\n", .{behavior_dir});
    defer behavior_boot.finishAndClose(&tracer, .closed);
    // Registered after the normal defer so error unwinding records `error`
    // first; finish() is idempotent and keeps that status terminal.
    errdefer behavior_boot.behavior.finish(.failed);

    // LIFO teardown: joinElites, then background bash + subagent pumps, then
    // emit/send run_finished, then close/deinit the two behavioral sinks. The
    // earlier fallbacks remain for failures that occur before these defers
    // are registered.
    defer if (!jobs_reaped) {
        jobsReap(gpa, io);
        jobs_reaped = true;
    };
    defer if (!agent_jobs_reaped) {
        agentJobsReap(gpa, io);
        agent_jobs_reaped = true;
    };
    defer joinElites(io); // reap if the session quits before any turn joins it

    session_run.saveOrResumeSession(&root, &keys, arena, flags);
    // Load restored configuration before run_started, but defer any model-backed
    // cold-cache compaction until after lifecycle start.
    try session_run.restoreResumedSession(arena, out, &root, &keys, flags, json_mode, g_cwd_display);
    const behavior_prompt_sha = scoring.promptFingerprint(root.systemPrompt());
    behavior_boot.behavior.startWithMetadata(harness_version, telem.start_unix_ms, .{
        .provider = root.provider.id,
        .model = root.provider.model,
        .prompt_sha = &behavior_prompt_sha,
        .effort = @tagName(root.reasoning),
    });
    session_run.compactResumedSession(&root);

    // `graff repl`: interactive chat REPL on the zigzag TUI, backed by the REAL agent loop — each prompt runs a full root turn (tools + MCP) via
    // replTurnCb, reusing the root agent's tool set + registry + system prompt. Self-contained — exits after.
    if (try session_run.runReplCommand(gpa, io, init.environ_map, &root, &keys, &client, in, out, arena, flags)) return;
    // One-shot print mode: run the single prompt to completion, print the final text to stdout, exit.
    if (flags.oneshot_prompt) |prompt_text| {
        try session_run.runOneshotPrompt(gpa, io, arena, &root, &keys, &tracer, out, prompt_text);
        return;
    }

    // Input-line history (persisted to ~/.simple-harness-history) + editor buffer.
    var history: std.ArrayList([]const u8) = .empty;
    var linebuf: std.ArrayList(u8) = .empty;
    if (homeEnv(init.environ_map)) |home| loadHistory(io, gpa, home, &history);
    defer {
        if (homeEnv(init.environ_map)) |home| saveHistory(io, arena, home, history.items);
        for (history.items) |h| gpa.free(h);
        history.deinit(gpa);
        linebuf.deinit(gpa);
        root.md_buf.deinit(gpa); // streamed-markdown line buffer
        root.md_word.deinit(gpa); // streamed-markdown wrap word buffer
        for (root.md_table.items) |r| gpa.free(r);
        root.md_table.deinit(gpa);
        root.tools_used.deinit(gpa);
    }
    const interactive = use_color and !json_mode; // stdout is a TTY → enable line editing

    // The interactive-REPL / --json-protocol loop lives in mainloop.zig. main() keeps owning every piece of storage the loop touches (root, keys,
    // tracer/traj/telem via root, history, linebuf, stdin/stdout writers) — Ctx below only holds POINTERS into this stack frame, so nothing dangles
    // once run() returns and post-loop cleanup resumes.
    var loop_ctx: mainloop.Ctx = .{
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .root = &root,
        .keys = &keys,
        .out = out,
        .in = in,
        .history = &history,
        .linebuf = &linebuf,
        .interactive = interactive,
        .sys_normal = sys_normal,
        .sys_strict = sys_strict,
    };
    try mainloop.run(&loop_ctx);
    try session_run.finalizeSession(gpa, io, arena, out, &root, json_mode);
}
// The `graff mcp` CLI (list/add servers in .mcp.json) + the trusted-companion check live in mcp_cli.zig.
const mcp_cli = @import("mcp_cli.zig");
// Provider-switch core lives in providers.zig; the interactive pickers, ultracode steering, and login/auth flow live in pickers.zig.
const providers = @import("providers.zig");
const pickers = @import("pickers.zig");
// handleCommand (one if-block per slash command) is split into 3 sibling tryHandle() modules by theme: commands_session.zig (session/env), commands_model.zig (model/provider/thinking), commands_misc.zig (/todo /jobs /cost /mcp /models /yolo /trace /fleet /save /resume /sessions + unknown-command/help fallback).
const commands_session = @import("commands_session.zig");
const commands_model = @import("commands_model.zig");
const commands_misc = @import("commands_misc.zig");
pub fn handleCommand(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !void {
    if (try commands_session.tryHandle(root, keys, arena, line, out)) return;
    if (try commands_model.tryHandle(root, keys, arena, line, out)) return;
    if (try commands_misc.tryHandle(root, keys, arena, line, out)) return;
    try commands_misc.handleRest(line, out);
}
// Session persistence lives in session.zig (kept here for its test{} block).
const session = @import("session.zig");
// Provider login/credential flows live in oauth.zig.
const oauth = @import("oauth.zig");
// API-key storage + the `graff key` CLI live in keys_cli.zig.
const keys_cli = @import("keys_cli.zig");
const homeEnv = keys_cli.homeEnv;
// `harness serve` — the --json session protocol over HTTP: each session is a real `harness --json` child, one HTTP request = one protocol request
// streamed back as NDJSON until its terminal event (GET /healthz, /v1/schema, POST/DELETE /v1/sessions[/<id>]). Auth: --token/HARNESS_SERVE_TOKEN
// as a Bearer token (non-loopback bind without one is refused; CORS opens only when set). The HTTP<->NDJSON bridge lives in serve.zig.
const serve = @import("serve.zig");
// Codegraff device-code login: POST /v1/device/start → show verification_uri + user_code → poll /v1/device/poll until "ok" yields the cg_sk_ key, written to ~/.simple-harness-codegraff.json. Also used by cube.zig (`graff cube`/`graff sandboxes`) as its gateway base.
pub const codegraff_device_base = "https://gateway.codegraff.com";
// The Agent struct (fields + smallest methods) + TodoItem live in agent.zig, imported as agent_mod (not agent) since several functions here declare a local `var agent: Agent = ...` that would shadow a bare import.
const agent_mod = @import("agent.zig");
pub const Agent = agent_mod.Agent;
// Wire-format message construction lives in messages.zig, imported as messages_mod to avoid shadowing the `messages` params/fields.
const messages_mod = @import("messages.zig");
/// A base64-encoded image staged by `/image`, sent with the next user turn.
const vision = @import("vision.zig"); // staged-image type, /image·/paste stagers, macOS clipboard grab
/// User-Agent for outbound provider calls. The Kimi for Coding plan gates access by User-Agent (a graff/* or bare UA gets `access_terminated`), so
/// graff identifies as claude-code/1.0.0 — a user's Kimi Code key then works here the same as in Kimi CLI or Claude Code. Other providers keep the default.
pub const kimi_user_agent = @import("kimi_catalog.zig").user_agent;
// HTTP transport (auth headers, raw POST, 5xx-body capture, watchdogs) lives in http.zig.
const http = @import("http.zig");
// Subprocess execution (runCapped, git-worktree mgmt, background bash-job pool) lives in jobs.zig; jobsReap is aliased back for main()'s cleanup defer.
const jobs = @import("jobs.zig");
const jobsReap = jobs.jobsReap;
// Tool execution (ToolCtx, /rewind snapshots, pre/post-tool hook dispatch, codedb-guard #626, metered-companion router) lives in tools.zig, imported
// as tools_mod since Agent.request/buildBody already have a `tools` param a bare import would shadow. Snapshots is a local alias (main() constructs
// one for /rewind). Subagent/workflow-task spawning (subagent.zig/workflow.zig) and the dispatcher (exec.zig) are imported only for their test{} blocks.
const tools_mod = @import("tools.zig");
const Snapshots = tools_mod.Snapshots;
const subagent = @import("subagent.zig");
const agentJobsReap = subagent.agentJobsReap; // #276 P0-3: background subagents die with the session, mirroring jobsReap
const workflow = @import("workflow.zig");
const exec = @import("exec.zig");
// ── Unit tests (`zig build test`) ──────────────────────────────────────────

test { // pull in tests from imported modules (mcp.zig)
    _ = mcp;
    _ = @import("main_test.zig");
    // readline.zig imports HistoryNav, but a type-only reference is not enough to
    // pull the module's own `test {}` blocks into the binary — without this line
    // its two tests silently compile to nothing and the suite still reports green.
    _ = @import("readline_history.zig");
}
