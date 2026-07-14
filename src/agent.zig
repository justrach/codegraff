//! The Agent struct itself: one agent's fields (message history, streaming/
//! markdown-render state, thinking-block state, eval-loop state, ...) plus
//! its smallest methods (prompt/say/sayApiError/emit/systemPrompt/
//! effortApplies/toolsJson/runTurn/renderTodos). Every other Agent method is
//! a free `pub fn method(self: *Agent, ...)` in an agent_*.zig sibling file,
//! member-aliased back inside this struct (`pub const method =
//! @import("agent_x.zig").method;`) so both `self.method(...)` and static
//! `Agent.method(...)` test calls resolve unchanged regardless of which
//! physical file a method's body lives in. Split out of main.zig (600-line
//! goal). Back-imports main (as main_mod, since a request()/etc. param is
//! conventionally named `root` elsewhere and to avoid the `agent`/`Agent`
//! self-name clash) for Provider/ReasoningEffort/the json_mode/plan_mode/
//! show_cost/g_cwd_display/g_gui_mu live globals. Sibling-imports mcp
//! (Registry), approvals (Approvals), trace (Tracer/ToolSink), tools
//! (Snapshots), vision (PendingImage), prompts (the system-prompt text),
//! schema (the per-wire-format tool JSON + providerTakesEffort), pricing
//! (priceFor/g_cost), and ansi (the color palette) directly instead of
//! going back through main's private aliases for them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const ReasoningEffort = main_mod.ReasoningEffort;

const ws = @import("ws.zig"); // codex Responses WS transport (delta continuation held across a turn)
const mcp = @import("mcp.zig");
const approvals_mod = @import("approvals.zig");
const trace = @import("trace.zig");
const tools_mod = @import("tools.zig");
const vision = @import("vision.zig");
const prompts = @import("prompts.zig");
const schema = @import("schema.zig");
const pricing = @import("pricing.zig");

const ansi = @import("ansi.zig");
const style = &ansi.style;
const terminal = @import("term.zig");

fn reasoningPromptLabel(effort: ReasoningEffort) []const u8 {
    return switch (effort) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .xhigh => "Extra high",
        .max => "Max",
        .ultra => "Ultra",
    };
}

fn reasoningPromptColor(effort: ReasoningEffort) []const u8 {
    return switch (effort) {
        .low => style.green,
        .medium => style.cyan,
        .high => style.yellow,
        .xhigh => style.magenta,
        .max => style.red,
        .ultra => style.magenta,
    };
}

fn writePromptBadge(w: *Io.Writer, color: []const u8, label: []const u8) !void {
    try w.print("{s} · {s}{s}{s}{s}", .{ style.dim, style.reset, color, label, style.reset });
}

/// Include a status-line segment only if its display width still fits the
/// remaining budget, charging it against `used` when it does. Lets prompt()
/// drop low-priority metadata instead of soft-wrapping mid-badge in a narrow
/// pane (#209).
fn fitsSegment(used: *usize, avail: usize, seg_width: usize) bool {
    if (used.* + seg_width <= avail) {
        used.* += seg_width;
        return true;
    }
    return false;
}

fn compactTokenCount(buf: []u8, tokens: u64) []const u8 {
    return if (tokens >= 1000)
        std.fmt.bufPrint(buf, "{d}k", .{tokens / 1000}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "?";
}

pub const TodoItem = struct {
    content: []const u8,
    status: []const u8,
};

/// One agent: a message history plus the POST/tool-dispatch loop. The root
/// agent prints to stdout; subagents (sub = true) run on pool threads and
/// log through std.debug.print, which locks stderr and is thread-safe.
pub const Agent = struct {
    gpa: Allocator,
    arena: Allocator,
    /// #124: per-turn transient parse garbage (per-SSE-event envelope parses,
    /// isStreamEnd) allocates here and is reset each request(), so the long-lived
    /// ROOT agent's session arena stops growing unboundedly. Optional — null on
    /// subagents/one-shots (they free their own arena per task); scratchAlloc()
    /// then falls back to arena, so their behavior is unchanged.
    scratch_arena: ?*std.heap.ArenaAllocator = null,
    io: Io,
    client: *std.http.Client,
    provider: Provider,
    messages: std.json.Array,
    // Codex Responses WS delta transport: one WS held across a turn's tool loop,
    // sending previous_response_id + only the new items instead of the full
    // history each step. Reset per turn by runTurn via closeCodexWs.
    codex_ws: ?*ws.WsClient = null,
    codex_prev_id: ?[]const u8 = null, // last response.id (gpa-owned); null = re-anchor with full input
    codex_sent_upto: usize = 0, // messages the server already holds; delta = messages[codex_sent_upto..]
    codex_ws_used_ms: i64 = 0, // .awake-clock ms of the WS's last successful use; gates the idle preemptive re-anchor (#codex-ws)
    sub: bool,
    label: []const u8,
    out: ?*Io.Writer,
    in: ?*Io.Reader = null, // stdin, root only — backs the ask_user tool
    registry: ?*mcp.Registry = null,
    approvals: ?*approvals_mod.Approvals = null, // shared bash-approval state, set by main()
    tracer: ?*trace.Tracer = null, // shared JSONL event trace, set by main()
    last_cache_read: u64 = 0, // KV-cache read tokens from the latest response
    sys_normal: []const u8 = prompts.main_system_prompt, // root system prompt (+ project instructions)
    sys_override: ?[]const u8 = null, // subagent-only: per-child system prompt (swarm prompt variants)
    tools_used: trace.ToolSink = .{}, // external tool calls this agent made (per turn for the root)
    tool_calls_this_turn: u64 = 0, // root-only hard budget counter (--max-tool-calls)
    seen_tool_keys: std.ArrayList([]const u8) = .empty, // root-only per-turn dedupe keys
    md_buf: std.ArrayList(u8) = .empty, // current incomplete streamed line (markdown rendering)
    md_fence: bool = false, // inside a ``` code fence while streaming
    md_kind: MdKind = .classify, // incremental renderer: current line's classification
    md_span: MdSpan = .normal, // incremental renderer: inline **bold**/`code` span state
    md_table: std.ArrayList([]const u8) = .empty, // buffered table rows (gpa-duped), aligned+rendered when the table ends
    md_word: std.ArrayList(u8) = .empty, // prose wrap: pending word (incl. style bytes)
    md_word_vis: usize = 0, // its visible width
    md_col: usize = 0, // visible column on the current prose line
    md_indent: usize = 0, // hanging indent for wrapped continuation lines
    md_width: usize = 0, // cached termCols() for the current line (0 = unset)
    snapshots: ?*tools_mod.Snapshots = null, // file-edit history for /rewind (root only)
    pending_image: ?vision.PendingImage = null, // staged by /image, sent with the next turn
    home: []const u8 = "", // $HOME, for /key persistence (set by main)
    keep_context: bool = true, // carry the conversation across wire-format model switches (/keepcontext)
    reasoning: ReasoningEffort = .medium, // reasoning/thinking depth — codex, deepseek, codegraff (/effort, /reasoning)
    fast: bool = false, // codex "fast" mode → priority service_tier (/fast)
    fallback_allow: []const []const u8 = &.{}, // explicit cross-provider allowlist from .harness/settings.json
    fallback_active: bool = false, // current provider/model is a temporary fallback, not the saved preference
    fallback_blocked: bool = false, // startup found a cross-provider fallback that is not allowlisted yet
    ultracode_mode: bool = false, // persistent ultracode (multi-agent workflow) mode (/ultracode)
    show_thinking: bool = true, // stream the model's reasoning live in the TUI (/thinking); off = spinner only
    ai_title: bool = true, // AI-generate the tab/session title from the first prompt (/title)
    goal: ?[]const u8 = null, // persistent objective steering (/goal)
    session_name: []const u8 = "last", // autosave/resume target (<name>.session.json)
    session_title: ?[]const u8 = null, // human-readable title/rename metadata
    sys_strict: []const u8 = prompts.main_system_prompt_strict,
    tools_anthropic: []const u8 = schema.tools_anthropic_sub,
    tools_openai: []const u8 = schema.tools_openai_sub,
    tools_responses: []const u8 = schema.tools_responses_sub,
    todos: std.ArrayList(TodoItem) = .empty,
    eval_cmd: ?[]const u8 = null, // --eval: shell command that scores the current output (eval-driven loop)
    eval_target: u8 = 90, // --until: stop when the score reaches this (0-100)
    eval_niche: []const u8 = "", // --niche: fleet niche this eval session optimizes; tags submitted scores into a promotable (niche × tier × suite) cell
    eval_judge: ?[]const u8 = null, // --judge: LLM-as-judge rubric, min()-blended with the --eval score (runJudge). Dormant until a CLI flag sets it.
    eval_iter: u32 = 0, // eval-loop iteration counter (scores log)
    eval_best: f64 = -1, // best score seen this session (-1 = none yet)
    strict: bool = false,
    completed: ?[]const u8 = null,
    last_context_tokens: u64 = 0,
    /// Detail of the most recent API error — carried into the --json `error`
    /// event, which otherwise only knows "api error".
    last_api_error: ?[]const u8 = null,
    /// Text streamed so far in the current request — on Esc-interrupt this is
    /// what survives into history (with an "[interrupted]" marker appended).
    partial_text: std.ArrayList(u8) = .empty,
    stream_quiet: bool = false, // suppress live streaming (compaction summary)
    ws_off: bool = false, // codex ws transport disabled for this session after a handshake/transport fallback to SSE (#codex-ws)
    streamed_text: bool = false, // the last request printed its text live
    thinking_open: bool = false, // a live "Thinking" reasoning block is currently streaming (/thinking)
    thinking_rows: usize = 0, // on-screen rows the live Thinking block spans (#75 collapse)
    thinking_col: usize = 0, // running column within the block, for soft-wrap counting
    thinking_overflow: bool = false, // block scrolled past the screen -> don't erase on collapse
    thinking_folded: bool = false, // user folded the live Thinking block (#92)
    thinking_text: std.ArrayList(u8) = .empty, // buffered reasoning, so a fold can unfold (#92)
    ai_title_done: bool = false, // the one-time AI tab-title call has run this session
    arg_live: ArgLive = .{}, // live attempt_completion/ask_user argument text
    streamed_args: ArgTool = .none, // which meta tool's prose streamed live this request
    streamed_args_len: usize = 0, // raw bytes emitted for it (gates re-print suppression)
    cap_new: bool = false, // provider rejected max_tokens → use max_completion_tokens
    effort_rejected: bool = false, // model rejected reasoning_effort → drop it (e.g. gpt-5.5 on chat/completions wants /v1/responses)
    next_ask_id: u64 = 1,
    tui_header_shown: bool = false,

    pub fn prompt(self: *Agent) !void {
        if (main_mod.json_mode) return; // SDK drives turns; no human prompt
        const w = self.out orelse return;
        var cbuf: [40]u8 = undefined;
        const cost: []const u8 = if (!main_mod.show_cost) "" else blk: {
            if (std.mem.eql(u8, self.provider.id, "codex"))
                break :blk " · sub";
            if (pricing.priceFor(self.provider.model) == null) break :blk " · $?";
            break :blk std.fmt.bufPrint(&cbuf, " · ${d:.4}", .{pricing.g_cost.snap(self.io).usd}) catch "";
        };
        // Prompt-cache hit from the last response — proof caching is working.
        var kbuf: [32]u8 = undefined;
        var kval: [24]u8 = undefined;
        const cached: []const u8 = if (self.last_context_tokens > 0 and self.last_cache_read > 0)
            (std.fmt.bufPrint(&kbuf, " · ⚡{s} cached", .{compactTokenCount(&kval, self.last_cache_read)}) catch "")
        else
            "";
        var ctxbuf: [80]u8 = undefined;
        var used_buf: [24]u8 = undefined;
        const ctx: []const u8 = if (self.last_context_tokens > 0) blk: {
            const threshold = self.provider.compactAt();
            const pct = if (self.provider.context > 0) self.last_context_tokens * 100 / self.provider.context else 0;
            break :blk std.fmt.bufPrint(&ctxbuf, " · {s}/{d}k ctx ({d}% · compact@{d}k)", .{
                compactTokenCount(&used_buf, self.last_context_tokens),
                self.provider.context / 1000,
                pct,
                threshold / 1000,
            }) catch "";
        } else "";

        // Budget the status line against terminal width so a narrow pane never
        // soft-wraps mid-badge (splitting e.g. `codex`) or strands the cursor.
        // The model plus the settings that disambiguate the cursor (effort,
        // provider, mode badges) are offered first; cwd/context/cache/cost are
        // the first to be dropped when they no longer fit. readline.zig then
        // gives the input its own row if what remains is still cramped. #209
        //
        // Reserve the fixed frame ('[' + '] › ' = 5 cols) plus 1 column of slack
        // so a width miscount on an exotic glyph can't tip the line into a wrap.
        const cols = terminal.termCols();
        const avail = if (cols > 6) cols - 6 else 0;
        var used: usize = terminal.dispWidth(self.provider.model);
        // A leading " · " separator is 3 columns; cwd's " · cwd " label is 7.
        const show_fast = self.fast and self.provider.kind == .responses and
            fitsSegment(&used, avail, 3 + terminal.dispWidth("Fast"));
        const show_effort = self.effortApplies() and
            fitsSegment(&used, avail, 3 + terminal.dispWidth(reasoningPromptLabel(self.reasoning)));
        const show_provider = fitsSegment(&used, avail, 3 + terminal.dispWidth(self.provider.id));
        const show_fallback = self.fallback_active and
            fitsSegment(&used, avail, 3 + terminal.dispWidth("Fallback"));
        const show_plan = main_mod.plan_mode and fitsSegment(&used, avail, 3 + terminal.dispWidth("Plan"));
        const show_strict = self.strict and fitsSegment(&used, avail, 3 + terminal.dispWidth("Strict"));
        const show_ultra = self.ultracode_mode and fitsSegment(&used, avail, 3 + terminal.dispWidth("Ultracode"));
        // The context meter outranks cwd for the budget (it is the urgent,
        // changing signal near the compaction threshold) but still renders after
        // cwd below, preserving the familiar left-to-right order when both fit.
        const show_ctx = ctx.len > 0 and fitsSegment(&used, avail, terminal.dispWidth(ctx));
        const show_cwd = fitsSegment(&used, avail, 7 + terminal.dispWidth(main_mod.g_cwd_display));
        const show_cached = cached.len > 0 and fitsSegment(&used, avail, terminal.dispWidth(cached));
        const show_cost = cost.len > 0 and fitsSegment(&used, avail, terminal.dispWidth(cost));

        try w.print("\n{s}[{s}{s}{s}{s}", .{ style.dim, style.reset, style.cyan, self.provider.model, style.reset });
        // Fast is the most operationally important model setting, so keep it
        // immediately beside the model instead of letting permission modes
        // push it deeper into the status line.
        if (show_fast) try writePromptBadge(w, style.green, "Fast");
        if (show_effort) try writePromptBadge(w, reasoningPromptColor(self.reasoning), reasoningPromptLabel(self.reasoning));
        if (show_provider) try writePromptBadge(w, style.cyan, self.provider.id);
        if (show_fallback) try writePromptBadge(w, style.yellow, "Fallback");
        if (show_plan) try writePromptBadge(w, style.yellow, "Plan");
        if (show_strict) try writePromptBadge(w, style.red, "Strict");
        if (show_ultra) try writePromptBadge(w, style.magenta, "Ultracode");
        try w.print("{s}", .{style.dim});
        if (show_cwd) try w.print(" · cwd {s}{s}{s}", .{ style.reset, main_mod.g_cwd_display, style.dim });
        if (show_ctx) try w.print("{s}", .{ctx});
        if (show_cached) try w.print("{s}", .{cached});
        if (show_cost) try w.print("{s}", .{cost});
        try w.print("{s}]{s} {s}›{s} ", .{ style.reset, style.reset, style.bold, style.reset });
        try w.flush();
    }

    pub fn say(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
        if (self.out) |w| {
            try w.print(fmt, args);
            try w.flush();
        } else {
            std.debug.print("  [{s}] " ++ fmt, .{self.label} ++ args);
        }
    }

    /// Report an API error: remember the formatted message so the --json
    /// `error` event can carry the detail, then print it like say().
    pub fn sayApiError(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
        self.last_api_error = std.fmt.allocPrint(self.arena, fmt, args) catch null;
        try self.say(fmt ++ "\n", args);
    }

    /// Emit one structured JSONL event to stdout (--json mode). `ev` is any
    /// struct/anonymous struct; field names become JSON keys (a std.json.Value
    /// field, e.g. tool input, serializes correctly). Best-effort.
    pub fn emit(self: *Agent, ev: anytype) void {
        const w = self.out orelse return;
        // --json: the GUI stream is shared with pool-thread subagent emits
        // (guiEmit), so serialize + flush under the lock — a raw line must never
        // land mid-buffer and two writers must never interleave on stdout.
        if (main_mod.json_mode) main_mod.g_gui_mu.lockUncancelable(self.io);
        defer if (main_mod.json_mode) main_mod.g_gui_mu.unlock(self.io);
        var s: std.json.Stringify = .{ .writer = w };
        s.write(ev) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch return;
    }
    pub fn systemPrompt(self: *const Agent) []const u8 {
        if (self.sub) return self.sys_override orelse prompts.sub_system_prompt;
        return if (self.strict) self.sys_strict else self.sys_normal;
    }

    /// Whether the active provider honors a reasoning-effort hint: the
    /// Responses API (codex) via reasoning.effort, and the OpenAI-compatible
    /// providers we know normalize a top-level reasoning_effort — the
    /// codegraff gateway and deepseek. Everything else ignores it.
    pub fn effortApplies(self: *const Agent) bool {
        return schema.providerTakesEffort(self.provider.kind, self.provider.id, self.provider.model);
    }

    pub fn toolsJson(self: *const Agent) []const u8 {
        return switch (self.provider.kind) {
            .anthropic => if (self.sub) schema.tools_anthropic_sub else self.tools_anthropic,
            .openai => if (self.sub) schema.tools_openai_sub else self.tools_openai,
            .responses => if (self.sub) schema.tools_responses_sub else self.tools_responses,
        };
    }

    /// Run until the model stops (or, in strict mode, calls
    /// attempt_completion). Returns the final assistant text (arena-owned).
    /// Close the held codex Responses WS session and reset the delta state. Called
    /// at both ends of runTurn so each turn gets a fresh connection and re-anchors
    /// with full input (the server only holds state within one live connection).
    pub fn closeCodexWs(self: *Agent) void {
        if (self.codex_ws) |c| {
            c.deinit(self.gpa);
            self.codex_ws = null;
        }
        if (self.codex_prev_id) |p| {
            self.gpa.free(p);
            self.codex_prev_id = null;
        }
        self.codex_sent_upto = 0;
    }

    pub fn runTurn(self: *Agent) anyerror![]const u8 {
        self.closeCodexWs(); // fresh codex WS session per turn
        defer self.closeCodexWs();
        self.completed = null;
        if (!self.sub) esc_cancel.store(false, .release); // fresh turn, no stale cancel
        while (true) {
            // Esc during a tool join (set by escWatchTask) lands here: the
            // root consumes the flag and aborts before the next request;
            // subagents see it too and bail without consuming.
            if (esc_cancel.load(.acquire)) {
                if (!self.sub) esc_cancel.store(false, .release);
                return error.Interrupted;
            }
            // #193: pre-send overflow gate. A single turn's tool-output burst can
            // push the input past the model's wall before the between-turns 80%
            // meter (last_context_tokens, server-reported) catches up. Estimate the
            // full input locally and compact BEFORE sending so we never ship an
            // over-cap request (codex run_pre_sampling_compact / opencode isOverflow).
            if (self.inputOverCompactThreshold()) {
                // Bracket the compaction with codex-WS resets, mirroring how every
                // other compactOrRecover call site is bookended by runTurn's
                // closeCodexWs (299 + defer 300). Mid-turn the WS can be live with a
                // prev_id / codex_sent_upto watermark keyed to the pre-trim history:
                // (1) the first reset lets compact()'s own summary request (it calls
                // request() at agent_compact.zig:267, after shrinking history at
                // 259-260) run against a clean session — a stale prev_id makes the
                // server re-prepend the full pre-trim context, defeating or
                // overflowing the summary itself; (2) the second re-anchors so the
                // next in-turn request() re-sends the trimmed full input, not a delta
                // keyed to dropped messages (same closeCodexWs-after-trim reason as
                // the in-turn recovery at agent_request.zig:273).
                self.closeCodexWs();
                self.compactOrRecover(true);
                self.closeCodexWs();
            }
            const root = try self.request(self.toolsJson());
            const done = switch (self.provider.kind) {
                .anthropic => try self.stepAnthropic(root),
                .openai => try self.stepOpenAI(root),
                .responses => try self.stepResponses(root),
            };
            if (done) |final_text| return final_text;
        }
    }

    // The provider round trip (request/buildBody + usage/cost recording +
    // Codex/Responses SSE reassembly) lives in agent_request.zig (#123,
    // 600-line goal). Member-aliased so self.request(...)/etc. resolve
    // unchanged.
    pub const request = @import("agent_request.zig").request;
    pub const inputOverCompactThreshold = @import("agent_request.zig").inputOverCompactThreshold;
    pub const recordUsage = @import("agent_request.zig").recordUsage;
    pub const usageInt = @import("agent_request.zig").usageInt;
    pub const recordCost = @import("agent_request.zig").recordCost;
    pub const ResponsesResult = @import("agent_request.zig").ResponsesResult;
    pub const parseResponses = @import("agent_request.zig").parseResponses;
    pub const errorMessage = @import("agent_request.zig").errorMessage;
    pub const recordUsageResponses = @import("agent_request.zig").recordUsageResponses;
    pub const buildBody = @import("agent_request.zig").buildBody;
    // Non-streaming response parsing (step*) + SSE-stream reassembly
    // (assemble*) live in agent_steps.zig (#123, 600-line goal).
    // Member-aliased so self.stepAnthropic(...)/etc. resolve unchanged.
    pub const stepResponses = @import("agent_steps.zig").stepResponses;
    pub const stepAnthropic = @import("agent_steps.zig").stepAnthropic;
    pub const stepOpenAI = @import("agent_steps.zig").stepOpenAI;
    pub const assembleStream = @import("agent_steps.zig").assembleStream;
    pub const assembleAnthropic = @import("agent_steps.zig").assembleAnthropic;
    pub const assembleOpenAI = @import("agent_steps.zig").assembleOpenAI;

    // Tool-call dispatch (runTools, the human-approval gate, meta-tool
    // handling, tool-call/result UX lines) lives in agent_tools.zig (#123,
    // 600-line goal). Member-aliased so self.runTools(...)/etc. resolve
    // unchanged.
    pub const runTools = @import("agent_tools.zig").runTools;
    pub const rejectToolCall = @import("agent_tools.zig").rejectToolCall;
    pub const toolDedupeKey = @import("agent_tools.zig").toolDedupeKey;
    pub const emitToolRejected = @import("agent_tools.zig").emitToolRejected;
    pub const gateTool = @import("agent_tools.zig").gateTool;
    pub const firstWord = @import("agent_tools.zig").firstWord;
    pub const handleMeta = @import("agent_tools.zig").handleMeta;
    pub const askUser = @import("agent_tools.zig").askUser;
    pub const emitAskUser = @import("agent_tools.zig").emitAskUser;
    pub const sayToolUse = @import("agent_tools.zig").sayToolUse;
    pub const sayToolResult = @import("agent_tools.zig").sayToolResult;
    pub fn renderTodos(self: *Agent) []const u8 {
        if (self.todos.items.len == 0) return "(no todos)";
        var aw: Io.Writer.Allocating = .init(self.arena);
        const w = &aw.writer;
        for (self.todos.items) |t| {
            const mark = if (std.mem.eql(u8, t.status, "completed"))
                "[x]"
            else if (std.mem.eql(u8, t.status, "in_progress"))
                "[~]"
            else
                "[ ]";
            w.print("{s} {s}\n", .{ mark, t.content }) catch break;
        }
        return std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
    }

    // Context management (compaction/emergency-trim) and the --eval/--until
    // eval-driven loop (+ optional LLM-as-judge) live in agent_compact.zig
    // (#123, 600-line goal). Member-aliased so self.compact(...)/etc.
    // resolve unchanged.
    pub const runEval = @import("agent_compact.zig").runEval;
    pub const appendEvalLog = @import("agent_compact.zig").appendEvalLog;
    pub const runJudge = @import("agent_compact.zig").runJudge;
    pub const compact = @import("agent_compact.zig").compact;
    pub const cleanUserTurn = @import("agent_compact.zig").cleanUserTurn;
    pub const emergencyCutIndex = @import("agent_compact.zig").emergencyCutIndex;
    pub const emergencyTrim = @import("agent_compact.zig").emergencyTrim;
    pub const compactOrRecover = @import("agent_compact.zig").compactOrRecover;

    // The live streaming path (thinking spinner, live "Thinking" reasoning
    // block, and postStream itself — the root agent's streaming POST) lives
    // in agent_stream.zig (#123, 600-line goal). Member-aliased so
    // self.postStream(...)/etc. resolve unchanged. g_spin_stop/g_spin_future
    // below stay here (never alias a `var`).
    // ── thinking spinner ────────────────────────────────────────────────
    // An animated indicator on the root agent's line while the model is
    // silent: from request send, through connect + time-to-first-token,
    // and through reasoning-model thinking deltas (which print nothing) —
    // cleared the moment the first visible text byte streams (printDelta)
    // or the stream ends (postStream's defer). Root + interactive TTY only;
    // single-threaded start/stop (root thread), the task itself is on the
    // pool and polls the stop flag every 20ms so stopping is near-instant.
    // The animation is picked via /animation (ported in spirit from
    // arpagon/pi-animations, MIT) and persists in .harness/settings.json.
    pub var g_spin_stop: std.atomic.Value(bool) = .init(true);
    pub var g_spin_future: ?Io.Future(void) = null;
    pub const spinnerTask = @import("agent_stream.zig").spinnerTask;
    pub const spinnerStart = @import("agent_stream.zig").spinnerStart;
    pub const spinnerStop = @import("agent_stream.zig").spinnerStop;
    pub const streamThinking = @import("agent_stream.zig").streamThinking;
    pub const closeThinkingBlock = @import("agent_stream.zig").closeThinkingBlock;
    pub const toggleThinkingFold = @import("agent_stream.zig").toggleThinkingFold;
    pub const postStream = @import("agent_stream.zig").postStream;
    pub const postStreamWithClient = @import("agent_stream.zig").postStreamWithClient;
    pub const printDelta = @import("agent_stream.zig").printDelta;
    // Codex Responses-over-WebSocket transport (+ its fresh-client SSE fallback
    // wrapper postLive) lives in agent_ws.zig (#codex-ws). Member-aliased.
    pub const postResponsesWs = @import("agent_ws.zig").postResponsesWs;
    pub const postLive = @import("agent_ws.zig").postLive;
    pub const wsEligible = @import("agent_ws.zig").wsEligible;
    /// Esc-during-tools cancellation. postStream only watches stdin while an
    /// HTTP stream is live, so a long tool join (bash, a subagent fan-out, a
    /// whole workflow) used to be Esc-deaf — exactly when turns feel longest.
    /// While the root awaits tool futures, escWatchTask polls stdin from the
    /// pool; Esc sets esc_cancel, which subagents poll between SSE lines and
    /// turn iterations, and the root consumes at its next loop head as
    /// error.Interrupted.
    pub var esc_cancel: std.atomic.Value(bool) = .init(false);
    pub var esc_watch_done: std.atomic.Value(bool) = .init(true);

    // Esc-cancel handling (the stdin scanner + steering-buffer capture +
    // interruptible sleep) lives in agent_interrupt.zig (#123, 600-line
    // goal). Member-aliased so self.sleepInterruptible(...)/etc. resolve
    // unchanged. esc_cancel/esc_watch_done above stay here (never alias a
    // `var`); ssePayload/sseIndex live there too since they're only
    // consumed alongside the interrupt-watch plumbing in postStream.
    /// Allocator for per-turn transient scratch (#124): the reset-per-request
    /// scratch arena when set (root), else the session arena (subagents/one-shot).
    pub fn scratchAlloc(self: *Agent) Allocator {
        return if (self.scratch_arena) |sa| sa.allocator() else self.arena;
    }

    pub const escWatchTask = @import("agent_interrupt.zig").escWatchTask;
    pub const escPressed = @import("agent_interrupt.zig").escPressed;
    pub const drainSteerStdin = @import("agent_interrupt.zig").drainSteerStdin;
    pub const drainStdin = @import("agent_interrupt.zig").drainStdin;
    pub const rawNonblockStdin = @import("agent_interrupt.zig").rawNonblockStdin;
    pub const sleepInterruptible = @import("agent_interrupt.zig").sleepInterruptible;
    pub const ssePayload = @import("agent_interrupt.zig").ssePayload;
    pub const sseIndex = @import("agent_interrupt.zig").sseIndex;

    // Live streaming of attempt_completion/ask_user tool-argument prose (the
    // ArgLive byte-scanner) lives in agent_argstream.zig (#123, 600-line
    // goal). Member-aliased so self.arg_live's type + the streaming callbacks
    // resolve unchanged regardless of physical file.
    pub const ArgTool = @import("agent_argstream.zig").ArgTool;
    pub const ArgLive = @import("agent_argstream.zig").ArgLive;
    pub const argToolFor = @import("agent_argstream.zig").argToolFor;
    pub const argField = @import("agent_argstream.zig").argField;
    pub const outputIndex = @import("agent_argstream.zig").outputIndex;
    pub const argLiveDelta = @import("agent_argstream.zig").argLiveDelta;
    pub const emitArgText = @import("agent_argstream.zig").emitArgText;
    pub const argStreamedFully = @import("agent_argstream.zig").argStreamedFully;

    // The incremental streaming markdown renderer (byte-at-a-time line
    // classifier + non-streaming renderMdLine) lives in agent_render.zig
    // (#123, 600-line goal). Member-aliased so `self.streamMarkdown(...)`
    // and the field types below resolve unchanged regardless of physical
    // file.
    pub const MdKind = @import("agent_render.zig").MdKind;
    pub const MdSpan = @import("agent_render.zig").MdSpan;
    pub const streamMarkdown = @import("agent_render.zig").streamMarkdown;
    pub const inlineVisibleLen = @import("agent_render.zig").inlineVisibleLen;
    pub const codepointCount = @import("agent_render.zig").codepointCount;
    pub const flushStreamTail = @import("agent_render.zig").flushStreamTail;
    pub const renderMdLine = @import("agent_render.zig").renderMdLine;
    pub const renderInline = @import("agent_render.zig").renderInline;
    pub const mdByte = @import("agent_render.zig").mdByte;
    pub const mdTryClassify = @import("agent_render.zig").mdTryClassify;
    pub const mdStartProse = @import("agent_render.zig").mdStartProse;
    pub const mdSpanByte = @import("agent_render.zig").mdSpanByte;
    pub const mdWrapByte = @import("agent_render.zig").mdWrapByte;
    pub const mdStyle = @import("agent_render.zig").mdStyle;
    pub const mdFlushWord = @import("agent_render.zig").mdFlushWord;
    pub const mdWrapBreak = @import("agent_render.zig").mdWrapBreak;
    pub const mdWidth = @import("agent_render.zig").mdWidth;
    pub const mdSpanEnd = @import("agent_render.zig").mdSpanEnd;
    pub const mdFinishLine = @import("agent_render.zig").mdFinishLine;
    // Streamed-markdown table rendering (buffered rows -> aligned columns,
    // word-wrapped to termCols()) lives in agent_table.zig (#123, 600-line
    // goal). Member-aliased so `self.flushTable(...)`/`Agent.isTableSeparator(...)`
    // resolve unchanged regardless of physical file.
    pub const flushTable = @import("agent_table.zig").flushTable;
    pub const fitWidths = @import("agent_table.zig").fitWidths;
    pub const atomEnd = @import("agent_table.zig").atomEnd;
    pub const wrapCell = @import("agent_table.zig").wrapCell;
    pub const isTableSeparator = @import("agent_table.zig").isTableSeparator;
};

test "reasoning prompt label uses picker wording" {
    try std.testing.expectEqualStrings("Low", reasoningPromptLabel(.low));
    try std.testing.expectEqualStrings("Medium", reasoningPromptLabel(.medium));
    try std.testing.expectEqualStrings("High", reasoningPromptLabel(.high));
    try std.testing.expectEqualStrings("Extra high", reasoningPromptLabel(.xhigh));
    try std.testing.expectEqualStrings("Max", reasoningPromptLabel(.max));
    try std.testing.expectEqualStrings("Ultra", reasoningPromptLabel(.ultra));
}

test "compact token counts keep prompt usage readable" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("999", compactTokenCount(&buf, 999));
    try std.testing.expectEqualStrings("138k", compactTokenCount(&buf, 138_082));
}
