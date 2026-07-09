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
const repl = @import("repl.zig");
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
const Style = ansi.Style;
const style = &ansi.style;
pub var use_color = false; // stdout is a TTY and NO_COLOR unset → enables color + markdown

// Optional displays toggled by CLI flags (--timing, --cost).
pub var show_timing = false;
pub var show_cost = false;
pub var json_mode = false; // --json: structured JSONL events on stdout instead of human text
pub var max_tool_calls: ?u64 = null; // --max-tool-calls: hard per-turn root tool budget
pub var dedupe_tool_calls = false; // --dedupe-tool-calls: reject duplicate root calls in a turn
pub var plan_mode = false; // /plan: read-only — mutating tools are denied, the model proposes
var unattended = false; // -p one-shot: no human to prompt; unapproved tool calls are denied

// Model pricing/catalog + the session cost tally live in pricing.zig (#123).
// Aliased here so the existing call sites read unchanged; later split slices
// can migrate call sites to `pricing.` and drop these.
const pricing = @import("pricing.zig");
const ModelPrice = pricing.ModelPrice;
const price_table = pricing.price_table;
const priceFor = pricing.priceFor;

// Pure shared helpers (JSON ObjectMap getters) live in util.zig (#123). Aliased
// so the ~50 existing strFieldObj/intFieldObj call sites stay unqualified.
const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const intFieldObj = util.intFieldObj;
const Billing = pricing.Billing;
const billingFor = pricing.billingFor;
const usdFor = pricing.usdFor;
const CostTally = pricing.CostTally;
const g_cost = &pricing.g_cost;
const ModelInfo = pricing.ModelInfo;
const codex_context_window = pricing.codex_context_window;
const model_table = pricing.model_table;
const default_context = pricing.default_context;
const contextFor = pricing.contextFor;
const normalizeModelAlias = pricing.normalizeModelAlias;
const modelAliasEquals = pricing.modelAliasEquals;
const resolveModelName = pricing.resolveModelName;
const modelInTable = pricing.modelInTable;
const providerModelInTable = pricing.providerModelInTable;

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
    _ = provider_mod;
    _ = agent_mod;
}

pub const provider_specs = provider_mod.provider_specs;

// System-prompt text (main_system_prompt, strict_note,
// main_system_prompt_strict, sub_system_prompt, compact_instruction) lives in
// prompts.zig (600-line goal, #123). All aliased back — the Agent struct's
// default field values and main()'s prompt-selection logic read unchanged.
// compact_instruction stays pub (agent_compact.zig back-imports it).
const prompts = @import("prompts.zig");
const main_system_prompt = prompts.main_system_prompt;
const strict_note = prompts.strict_note;
const main_system_prompt_strict = prompts.main_system_prompt_strict;
const sub_system_prompt = prompts.sub_system_prompt;
pub const compact_instruction = prompts.compact_instruction;

// -------------------------------------------------------------------------
// Tool-schema + provider-tool JSON emission (the ToolSpec catalog, per-provider
// tool renderers, and emitSchema) lives in schema.zig (#123). Aliased back so
// the existing call sites stay unqualified; emitSchema + schema_version are
// re-exported (pub) for serve.zig's back-import.
const schema = @import("schema.zig");
const renderRootTools = schema.renderRootTools;
const root_specs = schema.root_specs;
const isMetaName = schema.isMetaName;
const tools_anthropic_sub = schema.tools_anthropic_sub;
const tools_openai_sub = schema.tools_openai_sub;
const tools_responses_sub = schema.tools_responses_sub;
const providerTakesEffort = schema.providerTakesEffort;
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
const confinedPath = approvals_mod.confinedPath;
const noSymlinkEscape = approvals_mod.noSymlinkEscape;

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
const loadAgentTypes = fleet.loadAgentTypes;
const promoteAgents = fleet.promoteAgents;
const agentTypePrompt = fleet.agentTypePrompt;
const pullElites = fleet.pullElites;
const joinElites = fleet.joinElites;
const resolveOverride = fleet.resolveOverride;
const resolveNiche = fleet.resolveNiche;

// Prompt/provider-class fingerprinting + DGM score signing live in scoring.zig
// (600-line goal). Pure fns aliased back; the signing globals are
// scoring.-qualified at their call sites.
const scoring = @import("scoring.zig");
const promptFingerprint = scoring.promptFingerprint;
const providerClass = scoring.providerClass;
const scoreSigMessage = scoring.scoreSigMessage;
const signScore = scoring.signScore;
const loadScoreKey = scoring.loadScoreKey;

// ── Subagent cards (#51) ────────────────────────────────────────
// The parallel-subagent launch/done cards + box helpers + the inspect-report
// writer live in cards.zig (600-line goal). Renderers aliased back; the
// subagent-ordinal counter is reached cards.-qualified.
const cards = @import("cards.zig");
const subagentSprite = cards.subagentSprite;
const subagentId = cards.subagentId;
const subagentLaunchCard = cards.subagentLaunchCard;
const subagentDoneCard = cards.subagentDoneCard;
const writeSubagentDetail = cards.writeSubagentDetail;

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

// CodedbFileCheck + codedbFileIndexed (the per-file index cache) moved to
// hooks.zig (600-line goal); re-exported since tools.zig back-imports
// codedbFileIndexed as main_mod.codedbFileIndexed.
pub const CodedbFileCheck = hooks.CodedbFileCheck;
pub const codedbFileIndexed = hooks.codedbFileIndexed;

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
const mcp_notes = skills.mcp_notes;
pub const companion_servers = skills.companion_servers;
const companionToolName = skills.companionToolName;
const companionTrusted = skills.companionTrusted;
const companionReadOnly = skills.companionReadOnly;
const mcpServerConnected = skills.mcpServerConnected;
const binOnPath = skills.binOnPath;
const skillInstalled = skills.skillInstalled;
const skillIndex = skills.skillIndex;
const skillDisabled = skills.skillDisabled;
const companionDisabled = skills.companionDisabled;
const probeCodedbproLicensed = skills.probeCodedbproLicensed;
const codedbproNote = skills.codedbproNote;
const skillActive = skills.skillActive;
const loadSkillSettings = skills.loadSkillSettings;
const saveSkillSetting = skills.saveSkillSetting;

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
const titleFromPrompt = title_mod.titleFromPrompt;
const folderBasename = title_mod.folderBasename;
const firstUserTitle = title_mod.firstUserTitle;
const setTerminalTitle = title_mod.setTerminalTitle;
const printSessionHeader = title_mod.printSessionHeader;
const reasoningDelta = title_mod.reasoningDelta;
const assistantText = title_mod.assistantText;
const stripWrappingQuotes = title_mod.stripWrappingQuotes;
const cleanTitle = title_mod.cleanTitle;

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
const ReplCtx = repl_glue.ReplCtx;
const ReplStreamSink = repl_glue.ReplStreamSink;
const goalSteeringNote = repl_glue.goalSteeringNote;
pub const parseEvalScore = repl_glue.parseEvalScore;
const evalSteeringNote = repl_glue.evalSteeringNote;
const replTurnCb = repl_glue.replTurnCb;
const replModelCb = repl_glue.replModelCb;
const replCancelCb = repl_glue.replCancelCb;
const popSteer = repl_glue.popSteer;
const resetSteerPartial = repl_glue.resetSteerPartial;
pub const steerEcho = repl_glue.steerEcho;
pub const saveThinkingSettings = repl_glue.saveThinkingSettings;
const loadThinkingSettings = repl_glue.loadThinkingSettings;

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
const termCols = terminal.termCols;
const termRows = terminal.termRows;
const advanceThinkingRows = terminal.advanceThinkingRows;
const inputPending = terminal.inputPending;
const inputPendingTimed = terminal.inputPendingTimed;

// The rest of the line editor's input helpers (ultracode wave palette, the
// `@` picker's binary/dir filters + file collection, drag-and-drop path
// cleanup, and the redraw/setLine/delRange/prevWord/nextWord/addMark buffer
// helpers hoisted out of readLine) live in input_util.zig; readLine() itself
// (+ HistoryNav, #101) lives in readline.zig — both split out of main.zig
// (600-line goal). isImagePath is re-exported (vision.zig back-imports it)
// and binaryFileExt is aliased back (a read_file guard below calls it).
const input_util = @import("input_util.zig");
pub const isImagePath = input_util.isImagePath;
const binaryFileExt = input_util.binaryFileExt;
const readline_mod = @import("readline.zig");
const readLine = readline_mod.readLine;

// Session persistence (last model, input history) + the wire-format message
// serializers live in serde.zig (600-line goal, std-only leaf). Aliased back.
const serde = @import("serde.zig");
const saveModel = serde.saveModel;
const loadModel = serde.loadModel;
const loadHistory = serde.loadHistory;
const saveHistory = serde.saveHistory;
const writeAnthropicMessages = serde.writeAnthropicMessages;
const writeOpenAIMessageNormalized = serde.writeOpenAIMessageNormalized;

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
const updateCommand = cli.updateCommand;
const changelog_text = cli.changelog_text;
const usage_text = cli.usage_text;

// CLI flag parsing (the Flags struct + main()'s former ~130-line flag loop)
// lives in args.zig (600-line goal, #123 follow-up — the last file over the
// line goal). Not aliased: main() calls `args.parse` once and reads
// `flags.<name>` throughout, so there is no bare call-site to preserve.
const args = @import("args.zig");

// Post-arg-parse setup helpers (resolveKeys, buildSystemPrompt) that are
// safely separable from main()'s stack-owned storage live in startup.zig
// (600-line goal, #123 follow-up). See its header comment for why the rest
// of main()'s setup (tracer/traj/telem construction, the MCP/approvals/
// hooks/theme block) stays inline instead.
const startup = @import("startup.zig");

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
    if (flags.help_flag or flags.version_flag) {
        var hbuf: [4096]u8 = undefined;
        var hw = Io.File.stdout().writer(io, &hbuf);
        if (flags.help_flag) try hw.interface.writeAll(usage_text) else try hw.interface.print("graff {s}\n\n{s}", .{ harness_version, changelog_text });
        try hw.interface.flush();
        return;
    }

    // `harness key set <provider> <key>` / `harness key list`: safe key store
    // (macOS Keychain, else a 0600 file). Exits after.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "key")) {
        const home = homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        try keyCommand(io, gpa, arena, home, flags.positionals.items[1..]);
        return;
    }

    // `harness mcp add <name> -- <command> [args...]`: write workspace MCP config.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "mcp")) {
        try mcpCommand(io, arena, flags.positionals.items[1..]);
        return;
    }

    // `harness login [codex] [--refresh]`: OAuth login. Default target is
    // codegraff (device-code flow, writes ~/.simple-harness-codegraff.json);
    // `codex` (or --refresh) runs the ChatGPT PKCE/refresh flow → ~/.codex/auth.json.
    if (flags.login_flag) {
        const home = homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        if (flags.kimi_login) try oauth.kimiLogin(io, gpa, arena, home) else if (flags.codex_login or flags.refresh_flag) try oauth.codexLogin(io, gpa, arena, home, flags.refresh_flag) else try oauth.codegraffLogin(io, gpa, arena, home);
        return;
    }

    // `harness serve`: HTTP/NDJSON bridge over the --json protocol — each
    // session is a `harness --json` child of this same binary. Keys are
    // loaded by the children, not here.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "serve")) {
        const token = flags.token_flag orelse init.environ_map.get("HARNESS_SERVE_TOKEN") orelse init.environ_map.get("GRAFF_SERVE_TOKEN");
        const exe = std.process.executablePathAlloc(io, arena) catch
            std.process.fatal("serve: cannot resolve own executable path", .{});
        try serve.serveMain(gpa, io, .{
            .host = flags.host_flag,
            .port = flags.port_flag,
            .token = token,
            .yolo = flags.yolo_flag,
            .model = flags.model_flag,
            .system_prompt = flags.system_prompt_flag,
            .append_system_prompt = flags.append_system_flag,
        }, exe);
        return;
    }

    // `harness update [--force|--check]`: self-update to the latest GitHub
    // release. Version-checked (skips if already current), reuses install.sh
    // for the actual download/codesign/atomic swap. Exits after.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "update")) {
        // --check never installs, so --force has no effect on it — reject the
        // contradictory combination up front rather than silently ignoring one.
        if (flags.update_force and flags.update_check)
            std.process.fatal("--force and --check are mutually exclusive — use `graff update` (without --check) to install", .{});
        try updateCommand(io, gpa, arena, init.environ_map, flags.update_force, flags.update_check);
        return;
    }

    // `graff worktree list` / `graff worktree merge <name>`: manage the per-tab
    // scratch worktrees that -w creates. merge squash-lands a tab's work as one
    // clean commit on the current branch, then removes the worktree + branch.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "worktree")) {
        try worktreeCommand(gpa, io, arena, flags.positionals.items[1..]);
        return;
    }

    // `graff sandboxes [stop <id>]`: list the account's gateway sandboxes or
    // spin one down. Key resolution mirrors a normal run: CODEGRAFF_API_KEY
    // env first, else the `graff login` file via loadCodegraffKey.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "sandboxes")) {
        const cg_key = init.environ_map.get("CODEGRAFF_API_KEY") orelse
            (if (homeEnv(init.environ_map)) |home| oauth.loadCodegraffKey(io, arena, home) else null) orelse
            std.process.fatal("sandboxes: no codegraff key — run `graff login` first", .{});
        try cube.sandboxesCommand(io, gpa, arena, cg_key, flags.positionals.items[1..]);
        return;
    }

    // `graff cube [new|status|stop]`: a personal cloud graff — a gateway
    // sandbox running `graff serve` behind a Daytona preview URL. This is the
    // broker the iOS app mirrors; any serve client can attach with the
    // printed base + token.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "cube")) {
        const cg_key = init.environ_map.get("CODEGRAFF_API_KEY") orelse
            (if (homeEnv(init.environ_map)) |home| oauth.loadCodegraffKey(io, arena, home) else null) orelse
            std.process.fatal("cube: no codegraff key — run `graff login` first", .{});
        try cube.cubeCommand(io, gpa, arena, cg_key, flags.positionals.items[1..]);
        return;
    }

    // `--schema`: print the machine-readable interface and exit. No keys,
    // network, or MCP — so it works anywhere (CI codegen calls this).
    if (flags.schema_flag) {
        var sbuf: [8 * 1024]u8 = undefined;
        var sw = Io.File.stdout().writer(io, &sbuf);
        try emitSchema(&sw.interface);
        return;
    }
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

    // `graff title <prompt>` — print the tab-title the model would generate for
    // that prompt (one title call, no session). For A/B-ing title prompts/styles.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "title")) {
        if (flags.positionals.items.len < 2) std.process.fatal("usage: graff title <prompt>", .{});
        const tprompt = try std.mem.join(arena, " ", flags.positionals.items[1..]);
        if (titleTask(gpa, io, &client, default_provider, tprompt)) |t| {
            defer gpa.free(t);
            try out.print("{s}\n", .{t});
        } else try out.writeAll("(title generation failed — check your model/key)\n");
        try out.flush();
        return;
    }

    // Color only on an interactive terminal, and honor NO_COLOR.
    if (init.environ_map.get("NO_COLOR") == null and (Io.File.stdout().isTty(io) catch false)) {
        ansi.style = Style.ansi;
        use_color = true;
    }
    // --worktree/-w: run this session in an isolated git worktree so parallel
    // agents don't collide on files. Creates .graff/worktrees/<name> on branch
    // worktree-<name> (from HEAD) and enters it; reuses it if it already exists.
    if (flags.worktree_flag) |wt| {
        // POSIX-only: the chdir below goes through libc's `chdir`, which Windows
        // builds don't link. -w is a parallel-agent dev workflow (mac/linux); on
        // Windows we bail with a clear message rather than break the cross-build.
        // The comptime `if` elides the chdir branch entirely on Windows.
        if (builtin.os.tag == .windows) {
            std.process.fatal("--worktree is not yet supported on Windows (POSIX-only chdir) — run without -w", .{});
        } else {
            const wt_path = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{wt});
            const wt_branch = try std.fmt.allocPrint(arena, "worktree-{s}", .{wt});
            if (runCapped(gpa, io, &.{ "git", "worktree", "add", wt_path, "-b", wt_branch }, 8192, 8192, 60_000)) |r| {
                gpa.free(r.stdout);
                gpa.free(r.stderr);
            } else |_| {}
            const wt_z = arena.dupeZ(u8, wt_path) catch std.process.fatal("--worktree: out of memory", .{});
            if (std.posix.system.chdir(wt_z.ptr) != 0)
                std.process.fatal("--worktree '{s}': could not enter {s} (is this a git repository?)", .{ wt, wt_path });
            g_worktree_branch = wt_branch; // non-null = auto-commit each turn to this scratch branch
            if (!json_mode) {
                const ac: []const u8 = if (g_worktree_autocommit) " · auto-committing each turn (`graff worktree merge` to land it)" else "";
                out.print("{s}worktree:{s} {s}{s}{s} (branch {s}) — edits isolated from the main checkout{s}\n", .{ style.dim, style.reset, style.cyan, wt_path, style.reset, wt_branch, ac }) catch {};
                out.flush() catch {};
            }
        }
    }
    var cwd_buf: [4096]u8 = undefined;
    g_cwd_display = if (flags.worktree_flag) |wt|
        // After chdir into the worktree, realPath(AT_FDCWD) is unreliable; derive from the launch dir.
        std.fmt.allocPrint(arena, "{s}/.graff/worktrees/{s}", .{ init.environ_map.get("PWD") orelse ".", wt }) catch try arena.dupe(u8, init.environ_map.get("PWD") orelse ".")
    else if (Io.Dir.cwd().realPath(io, &cwd_buf)) |n|
        try arena.dupe(u8, cwd_buf[0..n])
    else |_|
        try arena.dupe(u8, init.environ_map.get("PWD") orelse ".");

    if (!json_mode and flags.oneshot_prompt == null) {
        try out.print("{s}codegraff{s} · folder: {s}{s}{s} · / for commands · @ picks a file · esc interrupts · ↑/↓ history · tab completes · ctrl-d quits · trace → {s}\n", .{ style.bold, style.reset, style.cyan, g_cwd_display, style.reset, trace_path });
        try out.flush();
        if (codex_account) |acct| {
            try out.print("logged into Codex (ChatGPT account {s}…) — /model gpt-5.5\n", .{acct[0..@min(acct.len, 8)]});
            try out.flush();
        }
        if (flags.yolo_flag) {
            try out.print("⚠ yolo mode (--yolo): all bash/tool/MCP permission prompts are skipped\n", .{});
            try out.flush();
        }
        if (stale_saved_model) |nm| {
            try out.print("{s}note: remembered model '{s}' isn't in the model table — starting on {s} instead{s}\n", .{ style.dim, nm, default_provider.model, style.reset });
            try out.flush();
        }
        if (show_timing or show_cost) {
            try out.print("{s}displays on:{s}{s}{s}\n", .{
                style.dim,
                if (show_timing) " per-tool timing" else "",
                if (show_cost) " session cost" else "",
                style.reset,
            });
            try out.flush();
        }
    }

    // Session trace (best-effort: a failed open just disables tracing).
    const trace_file: ?Io.File = Io.Dir.cwd().createFile(io, trace_path, .{}) catch null;
    defer if (trace_file) |f| f.close(io);
    var trace_buf: [8 * 1024]u8 = undefined;
    var trace_writer = if (trace_file) |f| f.writer(io, &trace_buf) else undefined;
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = if (trace_file != null) &trace_writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
    };

    // Trajectory archive (DGM-style tree; best-effort like the trace).
    // Unlike the trace it is APPEND-ONLY: the file accumulates across
    // sessions — it IS the archive a DGM-style driver selects parents from.
    // Each session starts with a `kind:"session"` header (node ids restart
    // per session; cross-session lineage threads through prompt_sha).
    const traj_file: ?Io.File = Io.Dir.cwd().createFile(io, trajectory_path, .{ .truncate = false }) catch null;
    defer if (traj_file) |f| f.close(io);
    var traj_buf: [8 * 1024]u8 = undefined;
    var traj_writer = if (traj_file) |f| f.writer(io, &traj_buf) else undefined;
    if (traj_file != null) {
        if (Io.Dir.cwd().statFile(io, trajectory_path, .{})) |st| {
            traj_writer.pos = st.size; // append after prior sessions
        } else |_| {}
    }
    var traj: Trajectory = .{
        .io = io,
        .gpa = gpa,
        .out = if (traj_file != null) &traj_writer.interface else null,
        .start = Io.Timestamp.now(io, .awake),
    };
    trace.g_traj = &traj;
    defer {
        trace.g_traj = null;
        traj.deinit();
    }
    traj.node(.{ .kind = "session", .version = harness_version, .unix_ms = unixMs(io) });

    // Score-channel signing (Step 0): a per-session run_id and, if
    // GRAFF_SCORE_KEY_FILE is set, the HMAC key — so score records written
    // this session are signed and forged trajectory rows are detectable.
    {
        var raw: [8]u8 = undefined;
        io.random(&raw);
        scoring.g_run_id = std.fmt.bytesToHex(raw, .lower);
    }
    scoring.g_score_key = loadScoreKey(io, arena, init.environ_map);

    // Telemetry endpoint precedence: opt-out always wins → else an
    // env-configured endpoint (dev / override) → else the release build's
    // baked-in default (build_options.telemetry_endpoint, empty in dev). The
    // install id file is only created when an endpoint is live.
    const telem_endpoint: []const u8 = if (flags.no_telemetry_flag or init.environ_map.get("GRAFF_NO_TELEMETRY") != null)
        ""
    else
        init.environ_map.get("OTEL_EXPORTER_OTLP_ENDPOINT") orelse
            init.environ_map.get("GRAFF_OTEL_ENDPOINT") orelse
            default_telemetry_endpoint;
    const telem_home = homeEnv(init.environ_map) orelse "";
    var telem: Telemetry = .{
        .io = io,
        .gpa = gpa,
        .client = &client,
        .endpoint = telem_endpoint,
        .install_id = if (telem_endpoint.len > 0) keys_cli.loadOrCreateId(io, gpa, telem_home, ".simple-harness-install-id") else @splat('0'),
        .client_name = init.environ_map.get("HARNESS_CLIENT") orelse "harness",
        .sdk_install_id = init.environ_map.get("HARNESS_SDK_INSTALL_ID") orelse "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = unixMs(io),
    };
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
    const mcp_count = countMcpServers(io, arena);
    var connect_mcp = flags.yolo_flag or mcp_count == 0;
    if (mcp_count > 0 and !flags.yolo_flag and !json_mode and use_color) {
        try out.print("{s}⚠ this workspace's .mcp.json defines {d} MCP server(s) that run local commands. Connect them this session? [y/N] {s}", .{ style.bold, mcp_count, style.reset });
        try out.flush();
        const ans = in.takeDelimiter('\n') catch null;
        connect_mcp = ans != null and ans.?.len > 0 and (ans.?[0] == 'y' or ans.?[0] == 'Y');
    }
    var registry_storage: mcp.Registry = if (connect_mcp) ((mcp.Registry.init(gpa, io, mcp_config_path) catch |err| inner: {
        try out.print("[mcp] init failed: {t} — continuing without MCP\n", .{err});
        if (telemetry.g_telem) |t| t.errorEvent("mcp", @errorName(err));
        break :inner null;
    }) orelse mcp.Registry.empty(gpa, io)) else outer: {
        if (mcp_count > 0) try out.print("{s}skipped {d} workspace MCP server(s) — /mcp trust to connect them now (or re-run with --yolo){s}\n", .{ style.dim, mcp_count, style.reset });
        break :outer mcp.Registry.empty(gpa, io);
    };
    defer registry_storage.deinit();
    const registry: ?*mcp.Registry = &registry_storage;
    // Companion auto-activation: if the metered code-intelligence companion
    // (codedb-pro, formerly muonry) is installed but nothing connected it (no
    // workspace .mcp.json entry, or consent declined), spawn it directly — a
    // user-installed companion at the same trust level as the skills
    // auto-detection above it, NOT arbitrary workspace config. Failure just
    // means native tools; the mcp_notes usage line below only enters context
    // when the connect actually succeeded. Opt out like a skill:
    // {"skills": {"codedbpro": false}}.
    g_path_env = try arena.dupe(u8, init.environ_map.get("PATH") orelse "");
    g_codedb_guard = init.environ_map.get("GRAFF_NO_CODEDB_GUARD") == null; // issue #626 guard, opt-out via env
    loadSkillSettings(io, arena); // per-skill opt-outs, also gates the auto-connect
    anim.loadAnimationSetting(io, arena); // {"animation": "..."} → thinking spinner choice
    anim.loadThemeSetting(io, arena); // {"theme": "<name>"} → opt-in terminal color theme
    const theme_on = anim.g_theme != null and use_color and !json_mode;
    if (theme_on) {
        out.writeAll(anim.themes[anim.g_theme.?].seq) catch {};
        out.flush() catch {};
    }
    defer if (theme_on) {
        out.writeAll(anim.theme_reset) catch {};
        out.flush() catch {};
    };
    // 🎂 yxlyx's birthday glam — when graff runs from her home dir, dress her
    // Ghostty in the pastel-pink theme (limyuxi_theme: light pink bg, dark plum
    // text, pink-leaning palette) and switch the spinner to glittery sparkles.
    // Cosmetic, flagged, gated to her cwd; resets everything on exit.
    const limyuxi_glam = anim.limyuxi_birthday_white and use_color and !json_mode and
        (std.mem.eql(u8, g_cwd_display, "/Users/limyuxi") or std.mem.startsWith(u8, g_cwd_display, "/Users/limyuxi/"));
    if (limyuxi_glam) {
        out.writeAll(anim.limyuxi_theme) catch {};
        out.flush() catch {};
        if (anim.animIndex("dragon")) |gi| {
            anim.g_anim_index = gi;
            anim.g_anim_off = false;
            anim.g_anim_random = false;
        }
    }
    defer if (limyuxi_glam) {
        out.writeAll(anim.limyuxi_reset) catch {};
        out.flush() catch {};
    };
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
        return;
    }
    anim.loadDevSpinnerOptOut(io, arena, init.environ_map);
    connect: {
        for (companion_servers) |c| if (mcpServerConnected(registry_storage.tools, c.server)) break :connect;
        for (companion_servers) |c| {
            if (companionDisabled(c.server) or !binOnPath(io, c.bin)) continue;
            if (registry_storage.addServer(c.server, c.bin, &.{"--mcp"})) |_| {
                break;
            } else |err| {
                if (!json_mode and flags.oneshot_prompt == null) {
                    try out.print("{s}[mcp:{s}] auto-connect failed ({t}) — native tools only{s}\n", .{ style.dim, c.server, err, style.reset });
                    try out.flush();
                }
            }
        }
    }
    const mcp_tools: []const mcp.Tool = registry_storage.tools;
    // If the metered companion connected, probe its license once so the note
    // below can lean into the paid tools (vs the conservative free-codedb note).
    if (mcpServerConnected(mcp_tools, "codedbpro")) g_codedbpro_licensed = probeCodedbproLicensed(gpa, io);

    var approvals: Approvals = .{ .yolo = flags.yolo_flag };
    defer {
        for (approvals.prefixes.items) |p| gpa.free(p);
        approvals.prefixes.deinit(gpa);
    }
    const persisted_approvals = approvals.loadPersisted(io, gpa, arena);

    // Agent types: builtins + .harness/agents/*.md (the MAP-Elites niches).
    fleet.g_home = homeEnv(init.environ_map); // for /agents promote's personal tier
    fleet.g_agent_types = loadAgentTypes(io, arena, fleet.g_home); // builtin < ~/.harness/agents (personal) < ./.harness/agents (private)
    if (persisted_approvals > 0 and !json_mode and flags.oneshot_prompt == null) {
        try out.print("{s}loaded {d} saved approval(s) from {s}{s}\n", .{ style.dim, persisted_approvals, Approvals.settings_path, style.reset });
        try out.flush();
    }
    // Lifecycle hooks (pre_tool/post_tool/turn_end) from the same file.
    // (Per-skill opt-outs were loaded earlier, before the muonry auto-connect.)
    g_hooks = hooks.loadHooks(io, arena);
    if (g_hooks.total() > 0 and !json_mode and flags.oneshot_prompt == null) {
        try out.print("{s}loaded {d} lifecycle hook(s) from {s} — /hooks lists them{s}\n", .{ style.dim, g_hooks.total(), Approvals.settings_path, style.reset });
        try out.flush();
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
    var root: Agent = .{
        .snapshots = &snaps,
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = default_provider,
        .home = homeEnv(init.environ_map) orelse "",
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "main",
        .out = out,
        .in = in,
        .registry = registry,
        .approvals = &approvals,
        .tracer = &tracer,
        .sys_normal = sys_normal,
        .sys_strict = sys_strict,
        .tools_anthropic = try renderRootTools(arena, .anthropic, &root_specs, mcp_tools),
        .tools_openai = try renderRootTools(arena, .openai, &root_specs, mcp_tools),
        .tools_responses = try renderRootTools(arena, .responses, &root_specs, mcp_tools),
    };
    const fresh_session_name = try std.fmt.allocPrint(arena, "session-{d}", .{unixMs(io)});
    root.session_name = if (flags.resume_flag) |name| (if (!flags.new_session_flag and !flags.no_resume_flag) name else fresh_session_name) else fresh_session_name;
    loadThinkingSettings(io, arena, &root); // {"effort":...,"fast":...} persisted by /effort and /fast
    if (flags.goal_flag) |g| root.goal = try arena.dupe(u8, g); // --goal applies to every turn (incl. --json/-p/SDK)
    if (flags.eval_cmd_flag) |c| root.eval_cmd = try arena.dupe(u8, c);
    if (flags.eval_target_flag) |t| root.eval_target = t;
    if (flags.eval_niche_flag) |n| root.eval_niche = try arena.dupe(u8, n);
    tracer.note("session", root.provider.model);
    // Distribute (docs §9.E): pull this tier's live fleet champions and prefer
    // them over the baked builtins. Best-effort + bounded; emits fleet:elite_pull.
    var esh_pull: [16]u8 = undefined;
    const pull_esh: []const u8 = if (root.eval_cmd) |c| pblk: {
        esh_pull = promptFingerprint(c);
        break :pblk &esh_pull;
    } else ""; // pull the champion for our eval suite (if any)
    // Background the fleet-champion pull: a ~0.3s TLS round-trip that used to block
    // the first prompt. Spawn it now; joinElites() reaps it on the main thread at the
    // first turn, so the user's typing hides the fetch (prompt paints ~0.3s sooner).
    fleet.g_elites_future = io.async(pullElites, .{ io, arena, &client, telemetry.g_telem, telem_endpoint, providerClass(root.provider.model), arena.dupe(u8, pull_esh) catch pull_esh, fleet.g_agent_types });
    defer joinElites(io); // reap if the session quits before any turn joins it

    // Save from the start: if the harness is killed (Ctrl+C / SIGINT) before
    // any turn completes, the session file is already on disk with the initial
    // state (provider, model, settings) so nothing is lost. EXCEPT when
    // resuming: the resume target already holds the real conversation and
    // loadSession below restores it — writing the empty initial state here
    // would clobber the very session we're about to read back (data loss).
    const will_resume = flags.resume_flag != null and !flags.new_session_flag and !flags.no_resume_flag;
    if (!will_resume) saveSession(&root, arena, root.session_name) catch {};

    if (flags.oneshot_prompt != null and flags.resume_flag != null and !flags.new_session_flag and !flags.no_resume_flag) {
        loadSession(&root, keys, arena, root.session_name) catch {};
    }

    // `graff repl`: interactive chat REPL on the zigzag TUI, backed by the REAL
    // agent loop — each prompt runs a full root turn (tools + MCP) via
    // replTurnCb, reusing the root agent's tool set + registry + system prompt.
    // Self-contained — exits after.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "repl")) {
        var repl_ctx = ReplCtx{
            .io = io,
            .client = &client,
            .provider = root.provider,
            .registry = root.registry,
            .sys_normal = root.sys_normal,
            .tools_anthropic = root.tools_anthropic,
            .tools_openai = root.tools_openai,
            .tools_responses = root.tools_responses,
        };
        var models_buf = std.array_list.Managed(u8).init(arena);
        for (model_table) |mi| {
            if (mi.name.len == 0) continue;
            if (models_buf.items.len != 0) models_buf.appendSlice(", ") catch {};
            models_buf.appendSlice(mi.name) catch {};
        }
        if (Io.File.stdin().isTty(io) catch true)
            try repl.run(gpa, io, init.environ_map, &repl_ctx, replTurnCb, replModelCb, replCancelCb, root.provider.model, models_buf.items)
        else
            try repl.runScripted(gpa, io, init.environ_map, in, out, &repl_ctx, replTurnCb, replModelCb, replCancelCb, root.provider.model, models_buf.items);
        return;
    }
    // One-shot print mode: run the single prompt to completion, print the
    // final text to stdout, exit. Tool progress goes to stderr (say() with no
    // out writer), streaming stays quiet, and the gate denies anything not
    // pre-approved instead of prompting (there's no one to ask).
    if (flags.oneshot_prompt) |prompt_text| {
        unattended = true;
        root.in = null; // gate: deny instead of prompt; ask_user: self-decide
        root.out = null; // tool progress → stderr; stdout carries only the answer
        root.stream_quiet = true;
        const ultracode_msg = try applyUltracodeSteering(arena, prompt_text, root.ultracode_mode);
        if (ultracode_msg.explicit) {
            tracer.note("ultracode", prompt_text[0..@min(prompt_text.len, 120)]);
            if (telemetry.g_telem) |t| t.ultracode();
        }
        const goal_note = try goalSteeringNote(arena, root.goal, if (root.todos.items.len > 0) root.renderTodos() else "");
        const eval_note = try evalSteeringNote(arena, root.eval_cmd, root.eval_target, root.eval_judge != null);
        var oneshot_user = if (goal_note.len > 0) try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ ultracode_msg.text, goal_note }) else ultracode_msg.text;
        if (eval_note.len > 0) oneshot_user = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ oneshot_user, eval_note });
        try root.messages.append(try textMessage(arena, "user", oneshot_user));
        if (telemetry.g_telem) |t| t.countTurn();
        const final_text = root.runTurn() catch |err| switch (err) {
            error.ApiError => std.process.fatal("{s}", .{root.last_api_error orelse "api error"}),
            else => |e| std.process.fatal("turn failed: {t}", .{e}),
        };
        try out.print("{s}\n", .{final_text});
        try out.flush();
        // Usage summary → stderr, so stdout stays exactly the answer.
        var ubuf: [256]u8 = undefined;
        var uw: Io.Writer = .fixed(&ubuf);
        if (CostTally.render(g_cost.snap(io), &uw)) {
            std.debug.print("[usage] {s}\n", .{uw.buffered()});
        } else |_| {}
        saveSession(&root, arena, root.session_name) catch |err| {
            std.debug.print("⚠ session save failed: {s}\n", .{@errorName(err)});
        };

        // --worktree: checkpoint the one-shot's edits to the scratch branch too.
        // Headless swarm agents (graff -w name -p "task") are the main -w use
        // case — they must not exit with their work left uncommitted.
        worktreeAutoCommit(gpa, io, std.fmt.allocPrint(arena, "wip: {s}", .{titleFromPrompt(prompt_text)}) catch "wip: graff oneshot");
        // One-shot returns here, before the REPL cleanup defer below is even
        // registered, so free the root's gpa-backed buffers explicitly (else a
        // tool-using one-shot leaks its tool log / render buffers on exit).
        root.md_buf.deinit(gpa);
        root.md_word.deinit(gpa);
        for (root.md_table.items) |r| gpa.free(r);
        root.md_table.deinit(gpa);
        root.tools_used.deinit(gpa);
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
    // Explicit resume only: bare `graff` starts fresh, while `--resume <name>`
    // restores that autosave target. Best-effort: a missing/keyless/corrupt
    // file silently starts fresh.
    if (flags.oneshot_prompt == null and flags.resume_flag != null and !flags.new_session_flag and !flags.no_resume_flag) {
        if (loadSession(&root, keys, arena, root.session_name)) |_| {
            if (root.messages.items.len > 0) {
                // Estimate the restored context from the file size (~4 bytes/token).
                const est_path = try sessionPath(arena, root.session_name);
                const est: u64 = if (Io.Dir.cwd().statFile(io, est_path, .{})) |st| @as(u64, @intCast(st.size)) / 4 else |_| 0;
                if (!json_mode) {
                    // Prefer the saved AI summary; fall back to the first user
                    // message only for older sessions that have no saved title.
                    const restored_title = root.session_title orelse firstUserTitle(arena, root.messages);
                    setTerminalTitle(out, restored_title, g_cwd_display);
                    try printSessionHeader(out, restored_title, g_cwd_display);
                    root.tui_header_shown = true;
                    try out.print("↩ resumed {s}{s} — {d} message(s) on {s} · /new or /clear for a fresh start\n", .{ root.session_name, session_ext, root.messages.items.len, root.provider.model });
                    try out.flush();
                }
                // Cold cache: if the restored context is as large as what would
                // trigger live compaction, the first turn would re-bill the whole
                // thing — summarize up front instead.
                if (est >= root.provider.compactAt()) {
                    root.last_context_tokens = est;
                    root.compactOrRecover(true);
                }
            }
        } else |_| {}
    }

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
    // Final save on exit also captures command-driven edits since the last turn
    // (/clear, /rewind) so the next start resumes the true end state.
    if (!json_mode and root.messages.items.len > 0) {
        saveSession(&root, arena, root.session_name) catch |err| {
            out.print("{s}⚠ session save failed: {t}{s}\n", .{ style.yellow, err, style.reset }) catch {};
            out.flush() catch {};
        };
        out.print("{s}↩ session saved → {s}{s}{s}\n", .{ style.dim, root.session_name, style.reset, session_ext }) catch {};
        out.flush() catch {};
    } else {
        saveSession(&root, arena, root.session_name) catch {};
    }

    // Capture edits from an interrupted/aborted final turn (those `continue`
    // before the per-turn checkpoint) so a worktree never quits with work left
    // uncommitted on its scratch branch.
    worktreeAutoCommit(gpa, io, "wip: session end");
    try out.writeAll("\n");
    try out.flush();
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
const countMcpServers = mcp_cli.countMcpServers;
const persistMcpServer = mcp_cli.persistMcpServer;
const mcpCommand = mcp_cli.mcpCommand;

// extractText moved to providers.zig (600-line goal); re-exported since
// title.zig and others already back-import it as main_mod.extractText.
pub const extractText = providers.extractText;

// Provider-switch core (translateHistory, applyProvider, resolveProvider*,
// setModelRequestLabel, switchProvider) lives in providers.zig; the
// interactive pickers, ultracode steering, and login/auth flow live in
// pickers.zig — both split out of main.zig (600-line goal, #123).
const providers = @import("providers.zig");
const applyProvider = providers.applyProvider;
const resolveProviderControlRequest = providers.resolveProviderControlRequest;
const setModelRequestLabel = providers.setModelRequestLabel;
const switchProvider = providers.switchProvider;

const pickers = @import("pickers.zig");
const modelPicker = pickers.modelPicker;
const PickItem = pickers.PickItem;
const listPicker = pickers.listPicker;
const applyUltracodeSteering = pickers.applyUltracodeSteering;
const pickUltracodeMode = pickers.pickUltracodeMode;
const command_menu = pickers.command_menu;
const reloadLoginKey = pickers.reloadLoginKey;
const offerProviderAuth = pickers.offerProviderAuth;

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
// saveSession/loadSession/listSavedSessions/sessionAge stay pub —
// commands_session.zig, commands_misc.zig, and readline.zig already
// back-import them as `main_mod.saveSession` etc.
const session = @import("session.zig");
pub const session_ext = session.session_ext;
const sessionPath = session.sessionPath;
const SessionMeta = session.SessionMeta;
const sessionMetaFromBytes = session.sessionMetaFromBytes;
const sessionMeta = session.sessionMeta;
pub const sessionAge = session.sessionAge;
const SessionEntry = session.SessionEntry;
pub const listSavedSessions = session.listSavedSessions;
const slugifyTitle = session.slugifyTitle;
const renameSession = session.renameSession;
const sessionTitle = session.sessionTitle;
pub const saveSession = session.saveSession;
pub const loadSession = session.loadSession;

// Provider login/credential flows (Codex PKCE, Kimi + Codegraff device-code)
// live in oauth.zig (#123); it imports ansi + util and back-imports main for
// unixMs/kimi_user_agent/the codegraff base.
const oauth = @import("oauth.zig");
const CodexAuth = oauth.CodexAuth;

// API-key storage + the `graff key` CLI + OpenAI-compatible model listing
// live in keys_cli.zig (600-line goal, #123). isLocalUrl/openAiModelsUrl/
// fetchOpenAIModels/storeKey stay pub (commands_model.zig + pickers.zig
// back-import them as `main_mod.X`); homeEnv/loadStoredKey/keyCommand are
// used only from within main() here, so their aliases stay bare.
const keys_cli = @import("keys_cli.zig");
pub const isLocalUrl = keys_cli.isLocalUrl;
pub const openAiModelsUrl = keys_cli.openAiModelsUrl;
pub const fetchOpenAIModels = keys_cli.fetchOpenAIModels;
const homeEnv = keys_cli.homeEnv;
pub const storeKey = keys_cli.storeKey;
const loadStoredKey = keys_cli.loadStoredKey;
const keyCommand = keys_cli.keyCommand;

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
const cube = @import("cube.zig");

// ToolCall/ExecResult/AnswerRequest/answerParseError/parseAnswerRequest
// moved to tools.zig (600-line goal); re-exported since agent_tools.zig,
// agent_steps.zig, exec.zig, and others already back-import them as
// main_mod.X.
pub const ToolCall = tools_mod.ToolCall;
pub const ExecResult = tools_mod.ExecResult;
pub const AnswerRequest = tools_mod.AnswerRequest;
pub const answerParseError = tools_mod.answerParseError;
pub const parseAnswerRequest = tools_mod.parseAnswerRequest;

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
const textMessage = messages_mod.textMessage;
const toolResultMessage = messages_mod.toolResultMessage;
const sanitizeMessagesUtf8 = messages_mod.sanitizeMessagesUtf8;
const normalizeResponsesHistory = messages_mod.normalizeResponsesHistory;
const normalizeOpenAIHistory = messages_mod.normalizeOpenAIHistory;

/// A base64-encoded image staged by `/image`, sent with the next user turn.
// Image/vision support (staged-image type, per-provider vision check, image
// message builder, /image·/paste stagers, macOS clipboard grab) lives in
// vision.zig (600-line goal). Public surface aliased back.
const vision = @import("vision.zig");
const PendingImage = vision.PendingImage;
const visionModel = vision.visionModel;
const visionCapable = vision.visionCapable;
const imageMediaType = vision.imageMediaType;
const imageMessage = vision.imageMessage;
const StageResult = vision.StageResult;
const stageImagePath = vision.stageImagePath;
const stageGuiImageAttachment = vision.stageGuiImageAttachment;
const grabClipboardImage = vision.grabClipboardImage;
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
const providerUserAgent = http.providerUserAgent;
const providerHeaders = http.providerHeaders;
const capture5xxBodyStream = http.capture5xxBodyStream;
const WatchdogFired = http.WatchdogFired;
const RetryPlan = http.RetryPlan;
const sendHeadTask = http.sendHeadTask;
const streamLineTask = http.streamLineTask;
const streamStallTask = http.streamStallTask;
const headStallTask = http.headStallTask;
const postWatched = http.postWatched;

// Subprocess execution: the capped runner (runCapped), git-worktree management,
// and the background bash-job pool live in jobs.zig (600-line goal). runCapped
// is re-exported (hooks.zig back-imports it); the worktree + job entry points
// are aliased back.
const jobs = @import("jobs.zig");
pub const runCapped = jobs.runCapped;
const worktreeAutoCommit = jobs.worktreeAutoCommit;
const worktreeCommand = jobs.worktreeCommand;
const spawnJob = jobs.spawnJob;
const jobOutput = jobs.jobOutput;
const jobKill = jobs.jobKill;
const jobsReap = jobs.jobsReap;
const shellArgv = jobs.shellArgv;
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
const apiErrorMessage = tools_mod.apiErrorMessage;
const mentionsReasoningEffort = tools_mod.mentionsReasoningEffort;

const subagent = @import("subagent.zig");
const judgeTask = subagent.judgeTask;

const workflow = @import("workflow.zig");

const exec = @import("exec.zig");
const execTool = exec.execTool;
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
