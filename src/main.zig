//! simple-harness — a minimal agentic loop, no SDK, no dependencies.
//!
//! Providers:
//!   * Anthropic Messages API   (model names starting with "claude")
//!   * OpenAI chat completions  (everything else, via the codegraff gateway)
//!
//! Tools come from three places, all dispatched through one uniform loop:
//!   * built-in:  bash, read_file, edit_file, write_file, subagent, workflow
//!   * meta:      todo_write, todo_read, ask_user, attempt_completion — act
//!                on the agent's own state, handled inline by the orchestrator
//!   * MCP:       any tool from a server listed in .mcp.json (see mcp.zig)
//!
//! The workflow tool is dynamic workflows as data: sequential phases of
//! parallel subagents, with {{prev}} carrying each phase's results forward.
//!
//! Bash runs behind a permission gate: unapproved commands prompt the user
//! (yes / always / no) at the root, subagents are limited to read-only and
//! user-approved commands, and /yolo turns the gate off.
//!
//! Every API round trip and tool execution is timed and appended as one JSON
//! line to harness.trace.jsonl (see Tracer) — the system prompt tells the
//! agent about the file, so it can debug and profile the harness, and
//! itself, from its own trace. /trace toggles it.
//!
//! "Every message is a tool" (strict mode, /strict): force a tool call every
//! turn (tool_choice) and make the final answer the attempt_completion tool,
//! so the loop is perfectly uniform — text never ends a turn.
//!
//! std.http.Client for HTTPS, std.json for both wire formats, the std.Io
//! thread pool (io.async) for parallel tool + subagent execution, and
//! client-side compaction when the conversation grows long.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
// The interactive-REPL / --json-protocol turn loop lives in mainloop.zig;
// main() just builds a mainloop.Ctx of pointers into its own stack locals
// and calls run() once.
const mainloop = @import("mainloop.zig");

const builtin = @import("builtin");

// The Agent struct's method bodies are split across agent_*.zig sibling
// files as free `pub fn method(self: *Agent, ...)` functions, member-aliased
// back inside `struct Agent` (`pub const method = @import("agent_x.zig").method;`)
// so both `self.method(...)` and static `Agent.method(...)` calls resolve
// unchanged. Imported here only to keep their test blocks running (see the
// root test{} block below).
const agent_table = @import("agent_table.zig");
const agent_argstream = @import("agent_argstream.zig");
const agent_render = @import("agent_render.zig");
const agent_steps = @import("agent_steps.zig");
const agent_compact = @import("agent_compact.zig");
const agent_tools = @import("agent_tools.zig");
const agent_request = @import("agent_request.zig");
const agent_interrupt = @import("agent_interrupt.zig");
const agent_stream = @import("agent_stream.zig");

pub const anthropic_version = "2023-06-01";
pub const max_tokens = 16000;
pub const mcp_config_path = ".mcp.json";

// The terminal color palette lives in ansi.zig. `style` is a pointer alias
// into ansi.style, so the ~200 `style.field` reads across this file
// auto-deref the live palette; main flips ansi.style to Style.ansi at
// startup once it confirms stdout is a TTY with color enabled.
const ansi = @import("ansi.zig");
pub var use_color = false; // stdout is a TTY and NO_COLOR unset → enables color + markdown

// Optional displays toggled by CLI flags (--timing, --cost).
pub var show_timing = false;
pub var show_cost = false;
pub var json_mode = false; // --json: structured JSONL events on stdout instead of human text
pub var max_tool_calls: ?u64 = null; // --max-tool-calls: hard per-turn root tool budget
pub var dedupe_tool_calls = false; // --dedupe-tool-calls: reject duplicate root calls in a turn
pub var plan_mode = false; // /plan: read-only — mutating tools are denied, the model proposes
pub var unattended = false; // -p one-shot: no human to prompt; unapproved tool calls are denied

const pricing = @import("pricing.zig"); // model pricing/catalog + session cost tally
const util = @import("util.zig"); // shared JSON ObjectMap getters (strFieldObj/intFieldObj)

test {
    // build.zig's unit_tests root is main.zig only — reference every
    // split-out module here so their test blocks keep running.
    _ = pricing;
    _ = ansi;
    _ = serve;
    _ = util;
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
    _ = agent_tools;
    _ = agent_request;
    _ = agent_interrupt;
    _ = agent_stream;
    _ = mainloop;
    _ = args;
    _ = startup;
    _ = session_start;
    _ = session_run;
    _ = provider_mod;
    _ = agent_mod;
}

// System-prompt text (main_system_prompt, strict_note, main_system_prompt_strict,
// sub_system_prompt, compact_instruction) lives in prompts.zig.
const prompts = @import("prompts.zig");

// Tool-schema + provider-tool JSON emission lives in schema.zig; serve.zig
// and startup.zig import it directly. Kept here to pull in its test{} block.
const schema = @import("schema.zig");

// The provider/keys core (ProviderSpec/provider_specs, Provider, Keys) lives
// in provider.zig. provider_specs/Keys stay local aliases — main()'s own
// credential setup and tests still read them directly.
const provider_mod = @import("provider.zig");
const provider_specs = provider_mod.provider_specs;
const Keys = provider_mod.Keys;

// Approvals (command/tool approval gate) + confinedPath/noSymlinkEscape live
// in approvals.zig. main() constructs one directly for the session.
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;

// Session tracing (harness.trace.jsonl Tracer) + the DGM trajectory archive
// (harness.trajectory.jsonl Trajectory) + the per-line JSON writer live in
// trace.zig. main() constructs a Tracer/Trajectory directly; trajectory_path
// locates the archive file.
const trace = @import("trace.zig");
const Tracer = trace.Tracer;
const Trajectory = trace.Trajectory;
const trajectory_path = trace.trajectory_path;
const trace_path = trace.trace_path;

// ── Agent types / fleet (MAP-Elites niches) ───────────────────────────
// The AgentType niche registry, the backgrounded elite pull, /agents
// promote, and the niche/override resolvers live in fleet.zig, aliased back
// so call sites stay unqualified.
const fleet = @import("fleet.zig");
const joinElites = fleet.joinElites;

// Prompt/provider-class fingerprinting + DGM score signing live in scoring.zig.
const scoring = @import("scoring.zig");

// ── Subagent cards (#51) ────────────────────────────────────────
// The parallel-subagent launch/done cards + box helpers + the inspect-report
// writer live in cards.zig.
const cards = @import("cards.zig");

// ── Telemetry (OTEL) ───────────────────────────────────────────
// The Telemetry sink lives in telemetry.zig; the session-global pointer is
// reached telemetry.-qualified at its call sites.
const telemetry = @import("telemetry.zig");

/// Federated-fleet contribution toggle (docs/hyperagents.md §9). On by default;
/// GRAFF_FLEET=off or /fleet off disables propose/submit/elite_pull. General
/// usage telemetry is separate (GRAFF_NO_TELEMETRY).
pub var g_fleet: bool = true;

const unixMs = util.unixMs;

/// Reasoning depth for codex/responses (OpenAI Responses `reasoning.effort`).
pub const ReasoningEffort = enum { low, medium, high };

pub const repl_commands = [_][]const u8{ "/model", "/models", "/clear", "/new", "/rename", "/goal", "/loop", "/bash", "/plan", "/key", "/keepcontext", "/effort", "/fast", "/ultracode", "/thinking", "/title", "/reasoning", "/strict", "/yolo", "/trace", "/fleet", "/trajectory", "/agents", "/skills", "/hooks", "/compact", "/rewind", "/image", "/paste", "/save", "/resume", "/sessions", "/todo", "/jobs", "/cost", "/animation", "/theme", "/mcp", "/help" };

// Lifecycle hooks (Hook/Hooks config types + settings loader + per-hook
// subprocess runner) live in hooks.zig. g_hooks below, the pre/post/turn-end
// dispatch, and the codedb-guard file-index cache stay here.
const hooks = @import("hooks.zig");

pub var g_hooks: hooks.Hooks = .{};

/// Built-in codedb guard (issue #626): blocks a bash command that scans/reads
/// a concrete source file, redirecting to the codedb tool instead — without
/// this, agents reflexively grep/cat and never touch the structural tools.
/// Off when GRAFF_NO_CODEDB_GUARD is set; the tri-state cache records
/// whether `codedb` is actually on PATH (no redirect if it isn't).
pub var g_codedb_guard = true;
pub var g_codedb_present: ?bool = null;

// Codex-style optional skills / companion-server subsystem lives in
// skills.zig. companionRoute/companionNativeFallback stay in tools.zig
// (they take ToolCtx/ToolCall). g_path_env/g_skill_disabled/
// g_companion_disabled stay `pub var` here — skills.zig reads/writes them
// live via main_mod.g_x, never by-value.
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

/// Short task label for terminal/TUI headers. Mirrors the GUI's first-prompt
/// fallback: use the user's first message as a compact tab/session title.
// Session-title + header rendering + provider-response text parsers live in
// title.zig.
const title_mod = @import("title.zig");

/// Opaque context handed to repl.run so the REPL can run a real agent turn —
/// reuses the root agent's tool set, MCP registry, and system prompt (built in
/// main()). No harness internals leak into repl.zig; it only sees a callback.
// The `graff repl` bridge, steering-note assembly, steering queue drain, and
// /effort /fast /ultracode persistence live in repl_glue.zig. SteerEntry
// below is read from here; the mutable steer/thinking globals stay here and
// are read/written live via `main_mod.g_x` (never aliased — they're `var`s).
const repl_glue = @import("repl_glue.zig");

/// Per-skill user opt-out, persisted as {"skills": {"kuri": false}} in
/// .harness/settings.json. A disabled skill is treated as not installed
/// everywhere — no system-prompt note, /skills shows it disabled, and
/// webfetch never shells out to it — even when its binaries are on PATH.
pub var g_skill_disabled = [_]bool{false} ** skills_registry.len;

/// Same opt-out, for the metered companion MCP servers (codedb-pro) — they
/// live in companion_servers, NOT skills_registry, so need their own flags.
pub var g_companion_disabled = [_]bool{false} ** companion_servers.len;

/// True when `codedb-pro probe` exits 0 (paid + usable). Set once at startup
/// after the companion connects; selects the licensed vs conservative note.
var g_codedbpro_licensed: bool = false;

// ── thinking animations ──────────────────────────────────────────────────
// Spinner animations + color themes (and their settings persistence) live in
// anim.zig; the spinner consumers (Agent.spinnerTask, /animation, /theme)
// stay here.
const anim = @import("anim.zig");

// Steering (Codex-style): bytes typed while a turn streams are captured
// instead of discarded, echoed live in dim cyan, and on Enter queued to run
// next — so follow-ups queue up without waiting for the turn to finish.
// TTY-only (raw-stdin esc-watch is gated off in --json/GUI mode). Watchdog/
// select arms may drain/echo stdin while the stream reader is blocked;
// g_steer_visible pauses spinner redraws so the live row survives it.
pub var g_steer_buf: std.ArrayList(u8) = .empty; // in-progress line (page-alloc)
const SteerEntry = repl_glue.SteerEntry; // struct { text: []const u8, force: bool }
pub var g_steer_queue: std.ArrayList(SteerEntry) = .empty; // completed lines
pub var g_steer_echoed = false; // "↳ steer ›" prefix shown for the current line
pub var g_steer_visible: std.atomic.Value(bool) = .init(false); // visible live steering row; pauses spinner redraws
pub var g_out: ?*Io.Writer = null; // stdout writer for steer echo (set in main)
pub var g_gui_mu: Io.Mutex = .init; // serializes --json stdout across pool-thread subagent emits (guiEmit + printDelta)
pub var g_force_interrupt = false; // Force-prompt path caused the last interrupt (Ctrl-F/double-enter).
pub var g_thinking_fold_request: bool = false; // Ctrl-T in escPressed → fold/unfold the live Thinking block (#92)
pub var g_thinking_open: bool = false; // a live Thinking block is on screen (gates the mouse-click fold, #92)
pub var g_5xx_body_buf: [600]u8 = undefined; // snippet of the last 5xx/429 error body
pub var g_5xx_body_len: usize = 0; // 0 = no body captured
// fillCompletions/wrapAt/LineRender/parseDsrCol live in input_util.zig.

// Terminal primitives (Windows console shim + cross-platform raw-mode tty
// layer + size/poll/row-count helpers) live in term.zig; hooks.zig imports
// it directly for win. tty is aliased back so call sites stay unqualified.
const terminal = @import("term.zig");
const tty = terminal.tty;

// The rest of the line editor's input helpers live in input_util.zig;
// readLine() itself (+ HistoryNav) lives in readline.zig. binaryFileExt is
// aliased back (a read_file guard below calls it).
const input_util = @import("input_util.zig");
const readline_mod = @import("readline.zig");

// Session persistence (last model, input history) + the wire-format message
// serializers live in serde.zig (std-only leaf).
const serde = @import("serde.zig");
const loadHistory = serde.loadHistory;
const saveHistory = serde.saveHistory;

pub const harness_version: []const u8 = @import("build_options").version;

/// OTLP endpoint baked into release builds (-Dtelemetry-endpoint); "" in dev
/// builds → telemetry stays off unless an env var configures it. Used as the
/// lowest-precedence telemetry endpoint, below env overrides and opt-out.
const default_telemetry_endpoint: []const u8 = @import("build_options").telemetry_endpoint;

// `graff update` (release check + install.sh delegation) + --version/--help
// text live in cli.zig.
const cli = @import("cli.zig");

// CLI flag parsing (the Flags struct) lives in args.zig; main() calls
// `args.parse` once and reads `flags.<name>` throughout.
const args = @import("args.zig");

// Post-arg-parse setup (resolveKeys, buildSystemPrompt, early subcommand
// dispatch) lives in startup.zig. Everything after credentials/the
// http.Client exist (title/-w/banner, trace/traj/telemetry/MCP-connect,
// repl/one-shot early-exits) lives in its sibling session_start.zig.
const startup = @import("startup.zig");
const session_start = @import("session_start.zig");
const session_run = @import("session_run.zig");
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // Windows: let the console interpret ANSI/VT escapes so the harness's
    // color and cursor sequences render instead of printing as literal text.
    if (builtin.os.tag == .windows) tty.enableVtOutput();

    // CLI flags: the Flags struct + parsing loop live in args.zig. Downstream
    // code reads flags.<name> in place of the ~27 locals + the positional
    // args this block used to declare and populate directly.
    const flags = try args.parse(init);

    // `--help` / `--version`: handled before any subcommand dispatch, so
    // `harness login --help` prints usage instead of starting an OAuth flow.
    if (try startup.runSubcommand(io, gpa, arena, init, flags)) return;
    // Credential/model resolution (env vars → codegraff/codex/kimi on-disk
    // logins → the `harness key set` store, env always wins; then --model or
    // the last-saved model) lives in startup.zig as resolveKeys() — pure over
    // env/disk/arena, safe to call outside main()'s own stack frame.
    const resolved_keys = try startup.resolveKeys(io, gpa, arena, init.environ_map, flags.model_flag);
    var keys = resolved_keys.keys;
    const default_provider = resolved_keys.default_provider;
    const stale_saved_model = resolved_keys.stale_saved_model;
    const codex_account = resolved_keys.codex_account;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const in = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;
    g_out = out;

    if (try session_start.runTitleCommand(io, gpa, arena, &client, default_provider, out, flags)) return;
    try session_start.setupWorktreeAndBanner(io, gpa, arena, init.environ_map, flags, out, trace_path, codex_account, stale_saved_model, default_provider);

    // Session trace (best-effort: a failed open just disables tracing).
    var trace_buf: [8 * 1024]u8 = undefined;
    var trace_open = session_start.openTraceFile(io, trace_path, &trace_buf);
    defer if (trace_open.file) |f| f.close(io);
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = if (trace_open.file != null) &trace_open.writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
    };

    // Trajectory archive (DGM-style tree; best-effort like the trace).
    // Unlike the trace it is APPEND-ONLY: the file accumulates across
    // sessions — it IS the archive a DGM-style driver selects parents from.
    // Each session starts with a `kind:"session"` header (node ids restart
    // per session; cross-session lineage threads through prompt_sha).
    var traj_buf: [8 * 1024]u8 = undefined;
    var traj_open = session_start.openTrajFile(io, trajectory_path, &traj_buf);
    defer if (traj_open.file) |f| f.close(io);
    var traj: Trajectory = .{
        .io = io,
        .gpa = gpa,
        .out = if (traj_open.file != null) &traj_open.writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
    };
    trace.g_traj = &traj;
    defer {
        trace.g_traj = null;
        traj.deinit();
    }
    traj.node(.{ .kind = "session", .version = harness_version, .unix_ms = unixMs(io) });

    session_start.initScoreSigning(io, arena, init.environ_map);

    var telem = session_start.initTelemetry(io, gpa, &client, init.environ_map, flags, default_telemetry_endpoint);
    telemetry.g_telem = &telem;
    // Fleet contribution opt-out, independent of telemetry: GRAFF_FLEET=off|0|false|no.
    if (init.environ_map.get("GRAFF_FLEET")) |fv| {
        g_fleet = !(std.ascii.eqlIgnoreCase(fv, "off") or std.mem.eql(u8, fv, "0") or std.ascii.eqlIgnoreCase(fv, "false") or std.ascii.eqlIgnoreCase(fv, "no"));
    }
    defer {
        telemetry.g_telem = null;
        telem.flush();
        telem.deinit();
    }

    // MCP servers from .mcp.json. SECURITY: a workspace .mcp.json launches
    // arbitrary local commands, so opening an untrusted repo could run them.
    // Auto-connect only with --yolo (trusted) or explicit per-session consent;
    // otherwise start with an empty (but live) registry so `/mcp add` still works.
    var registry_storage = try session_start.initRegistryConsent(io, gpa, arena, out, in, flags, mcp_config_path, use_color, json_mode);
    defer registry_storage.deinit();
    const registry: ?*mcp.Registry = &registry_storage;
    // Per-skill/companion opt-outs, animation/theme settings, and the
    // --selftest-spinner headless render live in session_start.zig. The
    // theme/limyuxi-glam reset `defer`s stay HERE (registered in main()'s
    // own frame) so they fire when main() returns, not when the helper does.
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
    try session_start.connectCompanion(io, &registry_storage, flags, out, json_mode);
    const mcp_tools: []const mcp.Tool = registry_storage.tools;
    // If the metered companion connected, probe its license once so the note
    // below can lean into the paid tools (vs the conservative free-codedb note).
    if (mcpServerConnected(mcp_tools, "codedbpro")) g_codedbpro_licensed = probeCodedbproLicensed(gpa, io);

    var approvals: Approvals = undefined;
    try session_run.initApprovalsHooksFleet(io, gpa, arena, init.environ_map, &approvals, flags, out, json_mode);
    defer {
        for (approvals.prefixes.items) |p| gpa.free(p);
        approvals.prefixes.deinit(gpa);
    }

    // Root system-prompt layering (base + AGENTS.md/HARNESS.md/CLAUDE.md +
    // --append-system-prompt + active-skill capability lines + connected-MCP
    // usage notes) lives in startup.zig as buildSystemPrompt() — pure over
    // io/arena, returns both prompt strings by value.
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

    var snaps: Snapshots = .{ .gpa = gpa, .io = io };
    defer snaps.deinit();
    // Background bash jobs die with the session: kill, await pumps, free.
    defer jobsReap(gpa, io);
    // Root Agent construction + post-construction config (session name,
    // persisted thinking/goal/eval settings, the session-start trace note)
    // + the backgrounded fleet-champion pull live in session_start.zig.
    // `root`'s pointer fields (snapshots/client/tracer/approvals/registry)
    // all reference already-stable main()-owned storage passed in by
    // address, so returning the constructed Agent by value here is safe.
    var root = try session_run.buildRootAgent(gpa, arena, io, &client, default_provider, init.environ_map, out, in, registry, &approvals, &tracer, sys_normal, sys_strict, mcp_tools, &snaps, flags, telem.endpoint);
    defer joinElites(io); // reap if the session quits before any turn joins it

    session_run.saveOrResumeSession(&root, keys, arena, flags);

    // `graff repl`: interactive chat REPL on the zigzag TUI, backed by the REAL
    // agent loop — each prompt runs a full root turn (tools + MCP) via
    // replTurnCb, reusing the root agent's tool set + registry + system prompt.
    // Self-contained — exits after.
    if (try session_run.runReplCommand(gpa, io, init.environ_map, &root, &client, in, out, arena, flags)) return;
    // One-shot print mode: run the single prompt to completion, print the
    // final text to stdout, exit.
    if (flags.oneshot_prompt) |prompt_text| {
        try session_run.runOneshotPrompt(gpa, io, arena, &root, &tracer, out, prompt_text);
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
    try session_run.restoreResumedSession(io, arena, out, &root, keys, flags, json_mode, g_cwd_display);

    // The interactive-REPL / --json-protocol turn loop lives in mainloop.zig.
    // main() keeps owning every piece of storage the loop touches (root,
    // keys, tracer/traj/telem via root, history, linebuf, the stdin/stdout
    // writers) — Ctx below only holds POINTERS into this stack frame, so
    // nothing dangles once run() returns and the post-loop cleanup resumes.
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

// The `graff mcp` CLI (list/add servers in .mcp.json) + the trusted-companion
// check live in mcp_cli.zig.
const mcp_cli = @import("mcp_cli.zig");

// Provider-switch core lives in providers.zig; the interactive pickers,
// ultracode steering, and login/auth flow live in pickers.zig.
const providers = @import("providers.zig");
const pickers = @import("pickers.zig");

// handleCommand (one if-block per slash command) is split into 3 sibling
// tryHandle() modules by theme: commands_session.zig (session/env),
// commands_model.zig (model/provider/thinking), commands_misc.zig
// (/todo /jobs /cost /mcp /models /yolo /trace /fleet /save /resume
// /sessions + the unknown-command/help fallback).
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

// `harness serve` — the same --json session protocol over HTTP: each
// session is a real `harness --json` child process, and one HTTP request =
// one protocol request streamed back as NDJSON until its terminal event
// (GET /healthz, GET /v1/schema, POST/DELETE /v1/sessions[/<id>]). Auth:
// --token / HARNESS_SERVE_TOKEN as a Bearer token; a non-loopback bind
// without a token is refused; CORS opens only when a token is set. The
// HTTP <-> NDJSON child-process bridge lives in serve.zig.
const serve = @import("serve.zig");

// Codegraff device-code login: POST /v1/device/start → show
// verification_uri + user_code → poll /v1/device/poll until "ok" yields the
// cg_sk_ key, written to ~/.simple-harness-codegraff.json. Also used by
// cube.zig (`graff cube`/`graff sandboxes`) as its gateway base.
pub const codegraff_device_base = "https://gateway.codegraff.com";

// The Agent struct (fields + smallest methods) + TodoItem live in agent.zig.
// Named agent_mod (not `agent`) — several functions in this file have a
// local `var agent: Agent = ...`, which would shadow a bare `agent` import.
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

// Wire-format message construction lives in messages.zig, imported as
// messages_mod to avoid shadowing the `messages` params/fields.
const messages_mod = @import("messages.zig");

/// A base64-encoded image staged by `/image`, sent with the next user turn.
const vision = @import("vision.zig"); // staged-image type, /image·/paste stagers, macOS clipboard grab
/// User-Agent for outbound provider calls. The Kimi for Coding plan gates
/// access by User-Agent (a graff/* or bare UA gets `access_terminated`), so
/// graff identifies as one — a user's Kimi Code key then works here the same
/// as in Kimi CLI or Claude Code. Every other provider keeps the default.
pub const kimi_user_agent = "claude-code/1.0.0";
// HTTP transport (auth headers, raw POST, 5xx-body capture, watchdogs) lives
// in http.zig.
const http = @import("http.zig");

// Subprocess execution (runCapped, git-worktree mgmt, background bash-job
// pool) lives in jobs.zig; jobsReap is aliased back for main()'s cleanup defer.
const jobs = @import("jobs.zig");
const jobsReap = jobs.jobsReap;

// Tool execution (ToolCtx, /rewind snapshots, pre/post-tool hook dispatch,
// codedb-guard #626, metered-companion router) lives in tools.zig, imported
// as tools_mod — Agent.request/buildBody already have a `tools` parameter,
// which a bare `tools` import would shadow. Snapshots stays a local alias —
// main() constructs one directly for /rewind. Subagent/workflow-task
// spawning (subagent.zig/workflow.zig) and the tool dispatcher (exec.zig)
// are kept imported here only for their test{} blocks.
const tools_mod = @import("tools.zig");
const Snapshots = tools_mod.Snapshots;
const subagent = @import("subagent.zig");
const workflow = @import("workflow.zig");
const exec = @import("exec.zig");
// ── Unit tests (`zig build test`) ──────────────────────────────────────────

test "incremental markdown streaming renders like renderMdLine" {
    // style is the empty default in tests, so styled output == de-marked text.
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &aw.writer,
    };
    defer a.md_buf.deinit(std.testing.allocator);
    defer a.md_word.deinit(std.testing.allocator);
    defer {
        for (a.md_table.items) |r| std.testing.allocator.free(r);
        a.md_table.deinit(std.testing.allocator);
    }

    // Prose is visible word-by-word, before any newline arrives (the
    // word in flight is held for wrap decisions).
    a.streamMarkdown("Hey! I'm her");
    try std.testing.expectEqualStrings("Hey! I'm ", aw.writer.buffered());
    a.streamMarkdown("e and ready\n");
    try std.testing.expectEqualStrings("Hey! I'm here and ready\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Bullets stream too: marker styled up front, text word-by-word, and a
    // split **bold** span styles eagerly (markers dropped as in renderInline).
    a.streamMarkdown("- has **bo");
    try std.testing.expectEqualStrings("• has ", aw.writer.buffered());
    a.streamMarkdown("ld** spans\n");
    try std.testing.expectEqualStrings("• has bold spans\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Numbered items, headers, inline code.
    a.streamMarkdown("12) point\n## Title\nuse `zig build` here\n");
    try std.testing.expectEqualStrings("12. point\nTitle\nuse zig build here\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Fences: open/close render as labeled dim rules, body streams unprefixed.
    a.streamMarkdown("```zig\nconst x = 1;\n```\nafter\n");
    try std.testing.expectEqualStrings("── zig " ++ ("─" ** 33) ++ "\nconst x = 1;\n" ++ ("─" ** 40) ++ "\nafter\n", aw.writer.buffered());
    try std.testing.expect(!a.md_fence);
    aw.clearRetainingCapacity();

    // Horizontal rule renders at line end.
    a.streamMarkdown("---\n");
    try std.testing.expectEqualStrings("────────────\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Tables buffer until the first non-row line, then render aligned:
    // column widths from the widest cell, header above a ─┼─ rule.
    a.streamMarkdown("| Item | Desc |\n| --- | --- |\n| 1 | Inspect files |\n");
    try std.testing.expectEqualStrings("", aw.writer.buffered()); // still buffering
    a.streamMarkdown("| 22 | Edit |\ndone\n");
    try std.testing.expectEqualStrings("Item │ Desc\n" ++
        "─────┼──────────────\n" ++
        "1    │ Inspect files\n" ++
        "22   │ Edit\n" ++
        "done\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // A table pending at stream end flushes from the tail path.
    a.streamMarkdown("| x | y |");
    a.flushStreamTail();
    try std.testing.expectEqualStrings("x │ y\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Stream tail: a partial prose line flushes whatever is pending.
    a.streamMarkdown("tail without newline");
    a.flushStreamTail();
    try std.testing.expectEqualStrings("tail without newline", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Long lines wrap at the terminal edge on word boundaries; bullet
    // continuations align under the text (hanging indent).
    a.md_width = 12; // pinned for the line — mdFinishLine re-reads after
    a.streamMarkdown("- alpha beta gamma\n");
    try std.testing.expectEqualStrings("• alpha beta\n  gamma\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Plain prose wraps at column 0; the break replaces the joining space.
    a.md_width = 10;
    a.streamMarkdown("word1 word2 word3\n");
    try std.testing.expectEqualStrings("word1 \nword2 \nword3\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // A word too wide for any line is not torn — the terminal wraps it.
    a.md_width = 6;
    a.streamMarkdown("abc defghijklm\n");
    try std.testing.expectEqualStrings("abc defghijklm\n", aw.writer.buffered());
}

test { // pull in tests from imported modules (mcp.zig)
    _ = mcp;
}

test "/bash slash command runs the bash tool and frees its gpa-allocated result" {
    // Regression guard for PR #38: the /bash slash handler routes through
    // execTool, whose result.text is gpa-owned (NOT arena-owned — every other
    // caller frees it). Forgetting `defer root.gpa.free(result.text)` in
    // handleCommand leaks on every /bash invocation; std.testing.allocator
    // catches that here.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = .{
            .id = "test",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "",
            .model = "m",
            .context = 100_000,
        },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
    var keys: Keys = .{ .values = [_]?[]const u8{null} ** provider_specs.len };

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    defer root.tools_used.deinit(gpa);
    try handleCommand(&root, &keys, arena, "/bash echo leak-guard-XYZ", &aw.writer);

    const written = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "leak-guard-XYZ") != null);
}
