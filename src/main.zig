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
// The interactive-REPL / --json-protocol turn loop that used to be the tail
// of main() lives in mainloop.zig (600-line goal); main() just builds a
// mainloop.Ctx of pointers into its own stack locals and calls run() once.
const mainloop = @import("mainloop.zig");

const builtin = @import("builtin");

// The Agent struct's method bodies are split across agent_*.zig sibling
// files (#123, 600-line goal) as free `pub fn method(self: *Agent, ...)`
// functions, member-aliased back inside `struct Agent` (`pub const method =
// @import("agent_x.zig").method;`) so both `self.method(...)` and static
// `Agent.method(...)` test calls resolve unchanged. Referenced here only to
// keep their test blocks running (see the root test{} block below).
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

// The terminal color palette lives in ansi.zig (a std-only leaf) so the
// spinner, streaming markdown renderer, and other UI code share one palette
// (#123). `style` is a pointer alias into ansi.style, so the ~200 `style.field`
// reads across this file auto-deref the live palette; main flips ansi.style to
// Style.ansi at startup once it confirms stdout is a TTY with color enabled.
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

// Model pricing/catalog + the session cost tally live in pricing.zig (#123).
// Aliased here so the existing call sites read unchanged; later split slices
// can migrate call sites to `pricing.` and drop these.
const pricing = @import("pricing.zig");

// Pure shared helpers (JSON ObjectMap getters) live in util.zig (#123). Aliased
// so the ~50 existing strFieldObj/intFieldObj call sites stay unqualified.
const util = @import("util.zig");

test {
    // build.zig's unit_tests root is main.zig only — reference split-out
    // modules here so their test blocks keep running (#123 watch-out).
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

pub const provider_specs = provider_mod.provider_specs;

// System-prompt text (main_system_prompt, strict_note,
// main_system_prompt_strict, sub_system_prompt, compact_instruction) lives in
// prompts.zig (600-line goal, #123). All aliased back — the Agent struct's
// default field values and main()'s prompt-selection logic read unchanged.
// compact_instruction is repointed to a direct prompts.zig import at its
// one remaining consumer, agent_compact.zig.
const prompts = @import("prompts.zig");

// -------------------------------------------------------------------------
// Tool-schema + provider-tool JSON emission (the ToolSpec catalog, per-provider
// tool renderers, and emitSchema) lives in schema.zig (#123). Aliased back so
// the existing call sites stay unqualified; emitSchema + schema_version are
// re-exported (pub) for serve.zig's back-import.
const schema = @import("schema.zig");
pub const emitSchema = schema.emitSchema;
pub const schema_version = schema.schema_version;
// -------------------------------------------------------------------------

// The provider/keys core (ProviderSpec/provider_specs, Provider, Keys) lives
// in provider.zig (600-line goal). Re-exported so the ~everywhere
// `main_mod.Provider`/`main_mod.Keys`/`main_mod.provider_specs` back-imports
// across the other split files keep resolving unchanged regardless of
// physical file.
const provider_mod = @import("provider.zig");
pub const Provider = provider_mod.Provider;
pub const Keys = provider_mod.Keys;

// Approvals (command/tool approval gate) + confinedPath/noSymlinkEscape live in
// approvals.zig (#123). Re-exported here so `Approvals.*`, the two path-gate
// helpers, and anim.zig's `root.Approvals` back-import resolve unchanged.
const approvals_mod = @import("approvals.zig");
pub const Approvals = approvals_mod.Approvals;

// Session tracing (harness.trace.jsonl Tracer) + the DGM trajectory archive
// (harness.trajectory.jsonl Trajectory) + the per-line JSON writer live in
// trace.zig (600-line goal). Types aliased back; trajectory_path re-exported
// (fleet.zig back-imports it); the session trajectory pointer is trace.-qualified.
const trace = @import("trace.zig");
pub const Tracer = trace.Tracer;
pub const Trajectory = trace.Trajectory;
pub const trajectory_path = trace.trajectory_path;
pub const ToolSink = trace.ToolSink;
const trace_path = trace.trace_path;

// ── Agent types / fleet (MAP-Elites niches) ───────────────────────────
// The AgentType niche registry, the backgrounded elite pull, /agents promote,
// and the niche/override resolvers live in fleet.zig (#123). The functions are
// aliased back so call sites stay unqualified; the session agent-type globals
// (the session agent-type state) moved with it and are
// reached fleet.-qualified.
const fleet = @import("fleet.zig");
const joinElites = fleet.joinElites;

// Prompt/provider-class fingerprinting + DGM score signing live in scoring.zig
// (600-line goal). Pure fns aliased back; the signing globals are
// scoring.-qualified at their call sites.
const scoring = @import("scoring.zig");

// ── Subagent cards (#51) ────────────────────────────────────────
// The parallel-subagent launch/done cards + box helpers + the inspect-report
// writer live in cards.zig (600-line goal). Renderers aliased back; the
// subagent-ordinal counter is reached cards.-qualified.
const cards = @import("cards.zig");

// Score-channel signing (DGM fitness integrity) + the session signing globals
// live in scoring.zig (600-line goal); reached scoring.-qualified.

// ToolSink (the per-agent tool-call log) lives in trace.zig (600-line goal).

// utf8Prefix moved to util.zig (600-line goal); re-exported since
// it's back-imported nearly everywhere as main_mod.utf8Prefix.
pub const utf8Prefix = util.utf8Prefix;

// ── Telemetry (OTEL) ───────────────────────────────────────────
// The Telemetry sink + its session-global pointer live in telemetry.zig
// (600-line goal). Telemetry is re-exported (fleet.zig back-imports it); the
// sink pointer is reached telemetry.-qualified at its call sites.
const telemetry = @import("telemetry.zig");
pub const Telemetry = telemetry.Telemetry;

/// Federated-fleet contribution toggle (docs/hyperagents.md §9). On by default;
/// GRAFF_FLEET=off or /fleet off disables propose/submit/elite_pull. General
/// usage telemetry is separate (GRAFF_NO_TELEMETRY).
pub var g_fleet: bool = true;

// unixMs moved to util.zig (600-line goal), re-exported since it's
// back-imported nearly everywhere as main_mod.unixMs. loadOrCreateId moved
// to keys_cli.zig instead; its only caller is the telemetry-init block
// below, which calls keys_cli.loadOrCreateId directly.
pub const unixMs = util.unixMs;

/// Reasoning depth for codex/responses (OpenAI Responses `reasoning.effort`).
pub const ReasoningEffort = enum { low, medium, high };

pub const repl_commands = [_][]const u8{ "/model", "/models", "/clear", "/new", "/rename", "/goal", "/loop", "/bash", "/plan", "/key", "/keepcontext", "/effort", "/fast", "/ultracode", "/thinking", "/title", "/reasoning", "/strict", "/yolo", "/trace", "/fleet", "/trajectory", "/agents", "/skills", "/hooks", "/compact", "/rewind", "/image", "/paste", "/save", "/resume", "/sessions", "/todo", "/jobs", "/cost", "/animation", "/theme", "/mcp", "/help" };

// isSlashCommandLine moved to repl_glue.zig (600-line goal); re-exported
// since mainloop.zig back-imports it as main_mod.isSlashCommandLine.
pub const isSlashCommandLine = repl_glue.isSlashCommandLine;

// Lifecycle hooks (Hook/Hooks config types + settings loader + per-hook
// subprocess runner) live in hooks.zig (#123). g_hooks below, the
// pre/post/turn-end dispatch, and the codedb-guard file-index cache stay here.
const hooks = @import("hooks.zig");

pub var g_hooks: hooks.Hooks = .{};

/// Built-in codedb guard (issue #626): when a repo is codedb-indexed, agents
/// reflexively grep/sed/cat source files and never touch the structural tools,
/// so codedb degrades to "ripgrep with smaller output." When on, a bash command
/// that scans/reads a concrete source file is blocked with a redirect to the
/// codedb tool. Off when GRAFF_NO_CODEDB_GUARD is set; the tri-state cache
/// records whether `codedb` is actually on PATH (no redirect if it isn't).
pub var g_codedb_guard = true;
pub var g_codedb_present: ?bool = null;

// Codex-style optional skills / companion-server subsystem (skills_registry,
// companion_servers, mcp_notes, install-status + opt-out helpers, the
// companion tool-name classifiers, and the codedbpro license probe + note
// picker) lives in skills.zig (600-line goal). companionRoute and
// companionNativeFallback moved to tools.zig (they take ToolCtx/ToolCall —
// the tools/exec region). g_path_env/g_skill_disabled/g_companion_disabled
// stay `pub var` here (main's own /skills command handler + startup code
// read/write them directly too); skills.zig reads/writes them live via
// main_mod.g_x, never by-value.
const skills = @import("skills.zig");
const skills_registry = skills.skills_registry;
pub const companion_servers = skills.companion_servers;
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
// title.zig (600-line goal). All 9 helpers aliased back so call sites (incl.
// the Agent-coupled titleTask below) stay unqualified.
const title_mod = @import("title.zig");

// titleTask moved to title.zig (600-line goal); re-exported since main()'s
// own `graff title` subcommand and mainloop.zig both call it unqualified /
// as main_mod.titleTask.
pub const titleTask = title_mod.titleTask;

/// Opaque context handed to repl.run so the REPL can run a real agent turn —
/// reuses the root agent's tool set, MCP registry, and system prompt (built in
/// main()). No harness internals leak into repl.zig; it only sees a callback.
// The `graff repl` bridge (ReplCtx/ReplStreamSink + replTurnCb/ModelCb/
// CancelCb), the goal/eval steering-note assembly, the Codex-style steering
// queue drain (popSteer/resetSteerPartial/steerEcho), and the /effort /fast
// /ultracode persistence (save/loadThinkingSettings) live in repl_glue.zig
// (600-line goal, #123). parseEvalScore/steerEcho/saveThinkingSettings stay
// pub — subagent.zig, agent_compact.zig, agent_interrupt.zig, and
// commands_model.zig already back-import them as `main_mod.X`. The mutable
// steer/thinking globals below (g_steer_buf, g_steer_queue, g_steer_echoed,
// g_steer_visible, g_out) stay here and are read/written live via
// `main_mod.g_x` from repl_glue.zig (never aliased — they're `var`s).
const repl_glue = @import("repl_glue.zig");
pub const parseEvalScore = repl_glue.parseEvalScore;
pub const steerEcho = repl_glue.steerEcho;
// saveThinkingSettings repointed to repl_glue.zig directly at commands_model.zig.

/// Per-skill user opt-out, persisted as {"skills": {"kuri": false}} in
/// .harness/settings.json. A disabled skill is treated as not installed
/// everywhere — no system-prompt note, /skills shows it disabled, and
/// webfetch never shells out to it — even when its binaries are on PATH.
pub var g_skill_disabled = [_]bool{false} ** skills_registry.len;

/// Same opt-out, for the metered companion MCP servers (codedb-pro). They live
/// in companion_servers, NOT skills_registry, so they need their own flags —
/// this is the bug fix: {"skills": {"codedbpro": false}} now actually disables
/// the auto-connect (skillDisabled() never matched a companion server name).
pub var g_companion_disabled = [_]bool{false} ** companion_servers.len;

/// True when `codedb-pro probe` exits 0 (paid + usable). Set once at startup
/// after the companion connects; selects the licensed vs conservative note.
var g_codedbpro_licensed: bool = false;

// ── thinking animations ──────────────────────────────────────────────────
// Spinner animations + color themes (and their settings persistence) live in
// anim.zig (#123); it imports ansi and back-imports main for Approvals paths.
// The spinner consumers (Agent.spinnerTask, /animation, /theme) stay here.
const anim = @import("anim.zig");

// Steering (Codex-style): bytes typed while a turn streams are captured
// instead of discarded, echoed live in dim cyan, and on Enter queued to
// run as the next turn — so you can line up follow-ups one after the
// other without waiting for the current turn to finish. TTY-only (the
// raw-stdin esc-watch path is gated off in --json/GUI mode), so the queue
// stays empty there. Watchdog/select arms may drain and echo stdin while the
// stream reader is blocked; g_steer_visible pauses spinner redraws so the live
// steering row is not cleared out from under the user.
pub var g_steer_buf: std.ArrayList(u8) = .empty; // in-progress line (page-alloc)
const SteerEntry = repl_glue.SteerEntry; // struct { text: []const u8, force: bool }; moved to repl_glue.zig
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
// fillCompletions/wrapAt/LineRender/parseDsrCol moved to input_util.zig
// (see the breadcrumb below the term.zig import block for the aliases
// this file still needs).

// Terminal primitives (Windows console shim + cross-platform raw-mode tty layer
// + size/poll/row-count helpers) live in term.zig (600-line goal). win is
// re-exported (hooks.zig back-imports it); the rest are aliased back so call
// sites stay unqualified.
const terminal = @import("term.zig");
pub const win = terminal.win;
const tty = terminal.tty;

// The rest of the line editor's input helpers (ultracode wave palette, the
// `@` picker's binary/dir filters + file collection, drag-and-drop path
// cleanup, and the redraw/setLine/delRange/prevWord/nextWord/addMark buffer
// helpers hoisted out of readLine) live in input_util.zig; readLine() itself
// (+ HistoryNav, #101) lives in readline.zig — both split out of main.zig
// (600-line goal). isImagePath is repointed to a direct input_util.zig
// import at its one remaining consumer, vision.zig; binaryFileExt is
// aliased back (a read_file guard below calls it).
const input_util = @import("input_util.zig");
const readline_mod = @import("readline.zig");

// Session persistence (last model, input history) + the wire-format message
// serializers live in serde.zig (600-line goal, std-only leaf). Aliased back.
const serde = @import("serde.zig");
const loadHistory = serde.loadHistory;
const saveHistory = serde.saveHistory;

pub const harness_version: []const u8 = @import("build_options").version;

/// OTLP endpoint baked into release builds (-Dtelemetry-endpoint); "" in dev
/// builds → telemetry stays off unless an env var configures it. Used as the
/// lowest-precedence telemetry endpoint, below env overrides and opt-out.
const default_telemetry_endpoint: []const u8 = @import("build_options").telemetry_endpoint;

/// A parsed `MAJOR.MINOR.PATCH` (no pre-release/build suffix). Used to compare
/// the running version against a GitHub release tag without the exact-string
/// mismatch that `git describe` suffixes ("-3-gabc", "-dirty", "-dev") cause.
// `graff update` (latest-release check + SemVer compare + install.sh delegation)
// + the changelog_text/usage_text (--version/--help) blocks live in cli.zig
// (600-line goal, #123). All three aliased back.
const cli = @import("cli.zig");

// CLI flag parsing (the Flags struct + main()'s former ~130-line flag loop)
// lives in args.zig (600-line goal, #123 follow-up — the last file over the
// line goal). Not aliased: main() calls `args.parse` once and reads
// `flags.<name>` throughout, so there is no bare call-site to preserve.
const args = @import("args.zig");

// Post-arg-parse setup helpers (resolveKeys, buildSystemPrompt, the early
// subcommand dispatch) live in startup.zig (600-line goal, #123 follow-up).
// Everything after credentials/the http.Client exist (title/-w/banner,
// trace/traj/telemetry/MCP-connect, repl/one-shot early-exits) lives in its
// sibling session_start.zig — startup.zig itself crossed the line goal once
// that content grew, so it moved out into its own file.
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

    // CLI flags: the Flags struct + parsing loop live in args.zig (600-line
    // goal, #123 follow-up — the last file over the line goal). Downstream
    // code reads flags.<name> in place of the ~27 locals + the positional
    // args this block used to declare and populate directly.
    const flags = try args.parse(init);

    // `--help` / `--version`: handled before any subcommand dispatch, so
    // `harness login --help` prints usage instead of starting an OAuth flow.
    if (try startup.runSubcommand(io, gpa, arena, init, flags)) return;
    // Credential/model resolution (env vars → codegraff/codex/kimi on-disk
    // logins → the `harness key set` store, env always wins; then --model or
    // the last-saved model) lives in startup.zig (600-line goal, #123
    // follow-up) as resolveKeys() — pure over env/disk/arena, safe to call
    // outside main()'s own stack frame (no address-of-local storage).
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
    // --selftest-spinner headless render live in session_start.zig
    // (600-line goal). The theme/limyuxi-glam reset `defer`s stay HERE
    // (registered in main()'s own frame, same order as before) so they fire
    // when main() returns, not when the helper does.
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
    // usage notes) lives in startup.zig (600-line goal, #123 follow-up) as
    // buildSystemPrompt() — pure over io/arena, returns both prompt strings
    // by value.
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
    // + the backgrounded fleet-champion pull live in session_start.zig
    // (600-line goal). `root`'s pointer fields (snapshots/client/tracer/
    // approvals/registry) all reference already-stable main()-owned storage
    // passed in by address, so returning the constructed Agent by value here
    // is safe (see session_start.zig's header).
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

    // The interactive-REPL / --json-protocol turn loop lives in mainloop.zig
    // (600-line goal). main() keeps owning every piece of storage the loop
    // touches (root, keys, tracer/traj/telem via root, history, linebuf, the
    // stdin/stdout writers) — Ctx below only holds POINTERS into this
    // stack frame, so nothing dangles once run() returns and the post-loop
    // cleanup below (unchanged) resumes.
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

/// Is this .mcp.json entry one the harness would auto-connect anyway? A
/// companion entry running its own binary (codedb-pro/muonry) with no args
/// (or just `--mcp`) carries the same trust as the PATH auto-activation — but
/// ONLY exactly that shape: a repo putting `{"codedbpro": {"command": "evil"}}`
/// (or extra args) in its config still hits the consent gate.
// The `graff mcp` CLI (list/add servers in .mcp.json) + the trusted-companion
// check + startup untrusted-server count live in mcp_cli.zig (600-line goal).
// The 3 externally-called entry points are aliased back.
const mcp_cli = @import("mcp_cli.zig");

// extractText moved to providers.zig (600-line goal); repointed to a direct
// providers.zig import at its one remaining consumer, title.zig.

// Provider-switch core (translateHistory, applyProvider, resolveProvider*,
// setModelRequestLabel, switchProvider) lives in providers.zig; the
// interactive pickers, ultracode steering, and login/auth flow live in
// pickers.zig — both split out of main.zig (600-line goal, #123).
const providers = @import("providers.zig");

const pickers = @import("pickers.zig");

// The ~1,200-line body of handleCommand (one if-block per slash command) is
// split into 3 sibling tryHandle() modules by theme (600-line goal, #123):
// commands_session.zig (session/env: /clear /new /rename /goal /loop /bash
// /agents /animation /theme /hooks /skills /trajectory /plan), commands_model.zig
// (model/provider/thinking: /model /compact /rewind /fast /thinking /title
// /ultracode /effort /keepcontext /key /login /image /paste /strict), and
// commands_misc.zig (/todo /jobs /cost /mcp /models /yolo /trace /fleet
// /save /resume /sessions + the unknown-command/help terminal fallback).
const commands_session = @import("commands_session.zig");
const commands_model = @import("commands_model.zig");
const commands_misc = @import("commands_misc.zig");

pub fn handleCommand(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !void {
    if (try commands_session.tryHandle(root, keys, arena, line, out)) return;
    if (try commands_model.tryHandle(root, keys, arena, line, out)) return;
    if (try commands_misc.tryHandle(root, keys, arena, line, out)) return;
    try commands_misc.handleRest(line, out);
}

// Session persistence (save/load/list/rename/age + the .graff/sessions path
// helpers) lives in session.zig (600-line goal, #123). session_ext/
// saveSession stay pub — commands_session.zig, commands_misc.zig, and
// readline.zig already back-import them as `main_mod.saveSession` etc.
// sessionAge/listSavedSessions/loadSession are repointed to a direct
// session.zig import at their one remaining consumer, commands_misc.zig.
const session = @import("session.zig");
pub const session_ext = session.session_ext;
pub const saveSession = session.saveSession;

// Provider login/credential flows (Codex PKCE, Kimi + Codegraff device-code)
// live in oauth.zig (#123); it imports ansi + util and back-imports main for
// unixMs/kimi_user_agent/the codegraff base.
const oauth = @import("oauth.zig");

// API-key storage + the `graff key` CLI + OpenAI-compatible model listing
// live in keys_cli.zig (600-line goal, #123). storeKey stays pub
// (commands_model.zig + pickers.zig back-import it as `main_mod.storeKey`);
// isLocalUrl/openAiModelsUrl/fetchOpenAIModels are repointed to a direct
// keys_cli.zig import at their one remaining consumer, commands_model.zig.
// homeEnv/loadStoredKey/keyCommand are used only from within main() here,
// so their aliases stay bare.
const keys_cli = @import("keys_cli.zig");
const homeEnv = keys_cli.homeEnv;
pub const storeKey = keys_cli.storeKey;

// ---------------------------------------------------------------------------
// `harness serve` — the same --json session protocol, served over HTTP so
// clients that cannot spawn a local process (edge runtimes, browsers, other
// machines) can still drive agents. The server is a thin bridge: each session
// is a real `harness --json` child process (the tested stdio path), and one
// HTTP request = one protocol request, streamed back as NDJSON until that
// request's terminal event. Endpoints:
//
//   GET    /healthz              → {"ok":true,...} (no auth)
//   GET    /v1/schema            → the `harness --schema` document
//   POST   /v1/sessions          → {"session_id":"<16 hex>"}; body may set
//                                  {"model","yolo","system_prompt","append_system_prompt"}
//   POST   /v1/sessions/<id>     → body is one protocol request object
//                                  ({"type":"user","text":...} etc); response
//                                  streams NDJSON events until turn/error/ack
//   DELETE /v1/sessions/<id>     → close the session (graceful: stdin EOF)
//
// Auth: --token / HARNESS_SERVE_TOKEN as a Bearer token. Binding a
// non-loopback host without a token is refused. CORS is fully open ONLY
// when a token is set (the token is then the actual gate); on token-less
// loopback no CORS headers are sent, so browsers stay same-origin.

// The `graff serve` HTTP bridge (HTTP <-> NDJSON child-process pool) lives in
// serve.zig (#123); it back-imports main for emitSchema + the version consts.
const serve = @import("serve.zig");

// ---------------------------------------------------------------------------

// Codegraff device-code login — mirrors graff's CodegraffDeviceStrategy:
// POST /v1/device/start → show verification_uri + user_code → poll
// /v1/device/poll until status "ok" yields the cg_sk_ key. Base derived from
// the codegraff provider URL (gateway.codegraff.com). The key is written to
// ~/.simple-harness-codegraff.json, which loadCodegraffKey reads at startup.
pub const codegraff_device_base = "https://gateway.codegraff.com";

// `graff cube` / `graff sandboxes` + the gateway REST helpers live in cube.zig
// (#123); it back-imports main for strFieldObj/intFieldObj + the gateway base.

// ToolCall moved to tools.zig (600-line goal); re-exported since several
// agent_*.zig files + commands_session.zig still back-import it as
// main_mod.ToolCall. (ExecResult/AnswerRequest/answerParseError/
// parseAnswerRequest also live there but are all repointed to a direct
// tools.zig import at their remaining consumers.)
pub const ToolCall = tools_mod.ToolCall;

// The Agent struct itself (fields + smallest methods) + TodoItem live in
// agent.zig (600-line goal). Re-exported so the ~everywhere
// `main_mod.Agent`/`main_mod.TodoItem` back-imports across the other split
// files keep resolving unchanged regardless of physical file. Named
// agent_mod (not `agent`) — several functions in this file have a local
// `var agent: Agent = ...`, which would shadow a bare `agent` import.
const agent_mod = @import("agent.zig");
pub const Agent = agent_mod.Agent;
pub const TodoItem = agent_mod.TodoItem;

// Wire-format message construction + UTF-8/history normalization live in
// messages.zig (600-line goal). Aliased back so call sites stay unqualified;
// imported as messages_mod to avoid shadowing the `messages` params/fields.
const messages_mod = @import("messages.zig");

/// A base64-encoded image staged by `/image`, sent with the next user turn.
// Image/vision support (staged-image type, per-provider vision check, image
// message builder, /image·/paste stagers, macOS clipboard grab) lives in
// vision.zig (600-line goal). Public surface aliased back.
const vision = @import("vision.zig");
/// Auth + provider-specific headers shared by post() and Agent.postStream().
/// User-Agent for an outbound provider call. The Kimi for Coding plan gates
/// access to recognized coding-agent clients by User-Agent (a graff/* or bare
/// UA gets `access_terminated`), so graff identifies as one — a user's Kimi
/// Code key then works here the same as in Kimi CLI or Claude Code. Every
/// other provider keeps the http client default.
pub const kimi_user_agent = "claude-code/1.0.0";
// HTTP transport (auth headers, raw POST, 5xx-body capture, request watchdogs)
// lives in http.zig (600-line goal). Aliased back so Agent's model-call and
// streaming select-arms stay unqualified.
const http = @import("http.zig");

// Subprocess execution: the capped runner (runCapped), git-worktree management,
// and the background bash-job pool live in jobs.zig (600-line goal). runCapped
// is re-exported (hooks.zig back-imports it); the worktree + job entry points
// are aliased back.
const jobs = @import("jobs.zig");
pub const runCapped = jobs.runCapped;
const jobsReap = jobs.jobsReap;
// Tool execution: the tool-call context (ToolCtx), file-edit snapshots for
// /rewind, pre/post-tool lifecycle-hook dispatch, the codedb-guard (#626)
// and metered-companion router, and small per-tool helpers live in tools.zig
// (600-line goal; imported as tools_mod — Agent.request/buildBody already
// have a `tools` parameter, which a bare `tools` import would shadow).
// Subagent/workflow-task spawning (execSubagent/runSub/workflowTask/
// judgeTask + the ultracode/DGM variant judge) lives in subagent.zig —
// judgeTask is aliased back (Agent.runJudge, above, spawns it directly via
// io.async). Dynamic workflows-as-data (phases + pipeline mode) live in
// workflow.zig. The tool dispatcher itself (execTool/execToolInner) lives in
// exec.zig, importing the three as siblings; execTool is aliased back
// (Agent.runTools' io.async spawn + the /bash slash-command handler above).
const tools_mod = @import("tools.zig");
pub const ToolOutput = tools_mod.ToolOutput;
pub const ToolCtx = tools_mod.ToolCtx;
pub const Snapshots = tools_mod.Snapshots;
pub const bash_stdout_cap = tools_mod.bash_stdout_cap; // input_util.zig back-imports this for its file-collection caps

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

// table-cell-wrapping/isTableSeparator tests moved to agent_table.zig;
// ArgLive test to agent_argstream.zig; assembleOpenAI test to
// agent_steps.zig; utf8Prefix test to telemetry.zig; resolveModelName test
// to pricing.zig; scoreSigMessage test to scoring.zig; parseAnswerRequest
// tests to tools.zig — all moved alongside the functions they test.

test { // pull in tests from imported modules (mcp.zig)
    _ = mcp;
}

// Agent.firstWord/cleanUserTurn/emergencyCutIndex/codepointCount/
// inlineVisibleLen/isTableSeparator tests moved with their functions to
// agent_tools.zig/agent_compact.zig/agent_render.zig/agent_table.zig.
// Provider.compactAt + Keys.providerFor/providerById/defaultProvider tests
// moved to provider.zig. extractText's test moved to providers.zig.
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
