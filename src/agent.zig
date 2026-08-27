//! The Agent struct, its state, and its smallest methods. Larger methods are
//! split into `agent_*.zig` siblings and member-aliased back into the struct.
//! Live process/session globals are reached through main_mod; focused helpers
//! are imported directly from their owning modules.

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
/// The shared approval state, re-exported: a module that only passes one
/// through (session_run's startup helpers) can name the type off the Agent
/// that owns it instead of importing approvals.zig itself (#429).
pub const Approvals = approvals_mod.Approvals;
const trace = @import("trace.zig");
const tools_mod = @import("tools.zig");
const vision = @import("vision.zig");
const prompts = @import("prompts.zig");
const tool_render = @import("agent_tool_render.zig");
const schema = @import("schema.zig");
const no_local_tools = @import("no_local_tools.zig"); // #330: --no-local-tools picks the gated subagent catalogs
const models_cache = @import("models_cache.zig");
const keys_cli = @import("keys_cli.zig");
const run_budget_mod = @import("run_budget.zig");

// agent_prompt.zig owns the width-budgeted status line (#209); aliased below.
const prompt_ui = @import("agent_prompt.zig");
const agent_tests = @import("agent_tests.zig");
const empty_completion = @import("agent_empty_completion.zig");
const goal_state = @import("goal_state.zig");
const peer_channel = @import("peer_channel.zig"); // #469: turn-boundary peer message delivery
const job_notify = @import("job_notify.zig");
const schedule = @import("schedule.zig");
const channel_worker = @import("channel_worker.zig");

pub const TodoItem = struct {
    content: []const u8,
    status: []const u8,
    epoch: u64 = 0, // the goal epoch that authored this item (#318); 0 = no goal
    retired: bool = false, // a LATER user ask retired this finished item (#394): kept as the session's archive, invisible to every epoch-scoped query
};

/// Governed-run status for a standing /goal (#223). Only `.active` steers turns;
/// pause/resume and the /loop continuation gate (#226) key off the others.
pub const GoalStatus = enum { active, paused, blocked, complete };

/// A structured standing objective: the /goal text plus its lifecycle status and
/// created/updated timestamps. Replaces the bare `?[]const u8` so /goal can
/// pause/resume/report and persist a real state machine across resumes. The
/// `objective` string is owned by the session arena (like the old goal string).
pub const Goal = struct {
    objective: []const u8,
    status: GoalStatus = .active,
    epoch: u64 = 0, // monotonic per session; todos are stamped with it so a replaced goal cannot bequeath its checklist (#318)
    standing: bool = false, // seeded by --goal: steering policy for the WHOLE session that the model can never retire; only the user can, with /goal clear|pause|<new> (#318)
    created_ms: i64 = 0,
    updated_ms: i64 = 0,
    // Effort snapshots for task-outcome telemetry (task_outcome.zig): session
    // counters at goal-set time, diffed at completion/abandon.
    turns_at_set: u64 = 0,
    calls_at_set: u64 = 0,
    compacts_at_set: u64 = 0,
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
    /// subagents/one-shots (scratchAlloc() then falls back to arena, unchanged).
    scratch_arena: ?*std.heap.ArenaAllocator = null,
    /// Optional allocator for a temporary request transaction. compact() points
    /// this at its arena so failed summaries do not leak message rewrites or
    /// partial response trees into the long-lived session arena.
    message_mutation_arena: ?Allocator = null,
    io: Io,
    client: *std.http.Client,
    provider: Provider,
    subagent_provider: ?Provider = null, // optional model pin for every direct child/workflow/judge
    subagent_provider_explicit: bool = false, // #371: --subagent-*/GRAFF_SUBAGENT_*/--no-subagent-tier freeze it; a DERIVED default re-follows /model (providers.applyProviderInner)
    subagent_cross_provider: bool = false, // user explicitly allowed the pin to cross a provider/data boundary
    messages: std.json.Array,
    // Codex Responses WS delta transport: one WS held ACROSS user turns (codex_chain.zig), sending previous_response_id + only new items. Reset by closeCodexWs.
    codex_ws: ?*ws.WsClient = null,
    codex_prev_id: ?[]const u8 = null, // last response.id (gpa-owned); null = re-anchor with full input
    codex_sent_upto: usize = 0, // messages the server already holds; delta = messages[codex_sent_upto..]
    codex_chain_rewrites: u32 = 0, // history_rewrites when the chain was anchored; a later compaction/trim invalidates it
    codex_props_fp: u64 = 0, // request properties the server anchored on (model/effort/fast/tools/instructions)
    codex_ws_used_ms: i64 = 0, // .awake-clock ms of the WS's last successful use; gates the idle preemptive re-anchor (#codex-ws)
    codex_ws_opened_ms: i64 = 0, // first connect time; xAI/codex WS hard-cap is 25 minutes
    sub: bool,
    /// This agent is served NO tools at all — the `tools` field is omitted
    /// from the request rather than sent empty, which every provider accepts.
    /// Set for the variant judge: its own design comment says it "only
    /// reads/reasons over text handed to it, never the filesystem", but it was
    /// handed the full subagent catalog anyway and duly spent ~3 calls per
    /// score re-reading files it had already been given. With no tools it must
    /// answer from the excerpt in one call, which is what it was designed for.
    text_only: bool = false,
    label: []const u8,
    out: ?*Io.Writer,
    in: ?*Io.Reader = null, // stdin, root only — backs the ask_user tool
    /// Frontend event sink (#422). Null = resolved per emission from the
    /// process mode (engine_sink.forAgent); set to inject a custom frontend.
    sink: ?@import("engine_sink.zig").EngineSink = null,
    registry: ?*mcp.Registry = null,
    approvals: ?*approvals_mod.Approvals = null, // shared bash-approval state, set by main()
    tracer: ?*trace.Tracer = null, // shared JSONL event trace, set by main()
    run_budget: ?*run_budget_mod.RunBudget = null, // shared invocation-wide call/concurrency ceiling
    depth: u8 = 0, // root/auxiliary = 0; delegated child = 1
    call_kind: run_budget_mod.CallKind = .root,
    last_cache_read: u64 = 0, // KV-cache read tokens from the latest response
    sys_normal: []const u8 = prompts.main_system_prompt, // root system prompt (+ project instructions)
    sys_override: ?[]const u8 = null, // per-child custom prompt or transient isolated-review base
    task_prompt: ?[]const u8 = null, // a subagent's mandate, pinned once before the first history rewrite so compaction can restate it verbatim (recentContextStart can keep no verbatim suffix for a child - its only clean user turn is index 0)
    agent_cwd: ?[]const u8 = null, // subagent-only (#276 P0-1): absolute path of this agent's isolated git worktree, threaded through ToolCtx per tool call instead of a process-wide chdir — parallel siblings each keep their own
    tools_used: trace.ToolSink = .{}, // external tool calls this agent made (per turn for the root)
    tool_calls_this_turn: u64 = 0,
    model_calls_this_turn: u64 = 0,
    handle_note_shown: bool = false, // #541: the handle-protocol lesson rides this agent's FIRST handle, once
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
    pending_image: ?vision.PendingImage = null, // last staged image (history nav)
    pending_images: [16]vision.PendingImage = @splat(.{ .media_type = "", .b64 = "", .label = "" }),
    pending_image_len: u8 = 0, // queued pastes for this turn (#580)
    home: []const u8 = "", // $HOME, for /key persistence (set by main)
    model_catalog: ?models_cache.LazyCodexCatalog = null, // demand-loaded dynamic Codex rows (root only)
    stored_keys_loaded: bool = true, // false after an explicit-provider launch; model surfaces fill the remaining Keychain slots
    keep_context: bool = true, // carry the conversation across wire-format model switches (/keepcontext)
    reasoning: ReasoningEffort = .medium, // reasoning/thinking depth — xai, codex, deepseek, codegraff (/effort, /reasoning)
    fast: bool = false, // codex "fast" mode → priority service_tier (/fast)
    fallback_allow: []const []const u8 = &.{}, // explicit cross-provider allowlist from .harness/settings.json
    fallback_active: bool = false, // current provider/model is a temporary fallback, not the saved preference
    fallback_blocked: bool = false, // startup found a cross-provider fallback that is not allowlisted yet
    ultracode_mode: bool = false,
    review_mode: bool = false,
    show_thinking: bool = true, // stream the model's reasoning live in the TUI (/thinking); off = spinner only
    ai_title: bool = true, // AI-generate the tab/session title from the first prompt (/title)
    ai_recap: bool = true, // AI one-line status recap at turn end (settings: session_recap)
    goal: ?Goal = null, // structured objective + status lifecycle (/goal, #223)
    goal_note_fp: u64 = 0, // last-injected standing-goal note fingerprint (goal_state.steeringGate, #318)
    goal_note_age: u32 = 0, // turns since that note was last injected (refresh interval)
    pending_goal_note: ?[]const u8 = null, // one-shot supersession note for the next turn (/goal replace|clear)
    completion_gate_armed: bool = false, // attempt_completion was refused; the promised second call closes the goal. Persists ACROSS turns (a model emits one per turn) until the checklist or goal changes (#318)
    completion_refused: bool = false, // a refused attempt_completion this turn: work the model must react to, so /loop must not read the turn as zero-tool (#318)
    todos_dirty: bool = false, // todo_write ran in THIS process: a checklist restored from disk is persisted state, never evidence that the current prompt is done (#318)
    goal_flag: ?[]const u8 = null, // --goal objective verbatim: re-applied over EVERY loadSession, including /resume, so the flag's contract survives restores (#318)
    loop_deadline_ms: ?i64 = null, // the running /loop's wall-clock deadline (goal_pacing.LoopClock); read by the subagent spawn path so a child inherits it. Run-local: never saved, cleared on stop/steer
    history_rewrites: u32 = 0, // bumped by compact()/emergencyTrim; state pasted into the dead history (e.g. the /loop checklist copy) must be re-carried (#318)
    session_name: []const u8 = "last", // autosave/resume target (<name>.session.json)
    session_title: ?[]const u8 = null, // human-readable title/rename metadata
    sys_base: []const u8 = "", // #381: the last BASE handed to prompts.setSystemPrompts, WITHOUT the playbook block — what a mid-session constraint re-composes from (playbook_glue.refreshRoot)
    sys_strict: []const u8 = prompts.main_system_prompt_strict,
    sys_ultra: []const u8 = prompts.main_system_prompt ++ prompts.ultracode_system_note, // #326: comptime defaults only — prompts.setSystemPrompts() is the sole production writer
    sys_ultra_strict: []const u8 = prompts.main_system_prompt_strict ++ prompts.ultracode_system_note, // composes onto sys_strict, never replaces it
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
    eval_verified: bool = false, // latest workspace state has a target-meeting verifier result
    eval_repair_pending: bool = false, // a contradiction blocks completion until a fresh green eval
    eval_repair_grants: u8 = 0, // RED continuations consumed (agent_steps.grantRepairTurn); reset by any green eval, capped by eval_control.max_repair_grants
    eval_fp: ?[32]u8 = null, // #412: worktree fingerprint at the last RED eval (verify_fingerprint.Digest); an identical tree skips the re-verify instead of paying for it
    strict: bool = false,
    completed: ?[]const u8 = null,
    last_context_tokens: u64 = 0,
    context_local_tokens: u64 = 0, // local request estimate paired with last_context_tokens
    last_usage_includes_output: bool = false, // fresh usage covers response items step* is about to append
    /// Detail of the most recent API error — carried into the --json `error`
    /// event, which otherwise only knows "api error".
    last_api_error: ?[]const u8 = null,
    /// Text streamed so far in the current request — on Esc-interrupt this is
    /// what survives into history (with an "[interrupted]" marker appended).
    partial_text: std.ArrayList(u8) = .empty,
    stream_quiet: bool = false, // suppress live streaming (one-shot and internal requests)
    compaction_request: bool = false, // the current model call is the synthetic compaction-summary request
    server_compaction_request: bool = false, // force one explicit Codex in-stream compaction pass
    responses_output_limit: ?u32 = null, // auxiliary override (title=64); compaction always uses 4096
    last_request_context_overflow: bool = false, // explicit provider rejection, not an inferred meter threshold
    last_request_write_failed: bool = false, // transport gave up specifically with WriteFailed this request
    compact_transport_failures: u8 = 0, // bounded escape for repeated opaque over-cap WriteFailed/network failures
    compact_summary_failures: u8 = 0, // #379: consecutive complete-but-unusable (empty/truncated) summaries
    compact_pin_degraded: bool = false, // #581: pinned suffix over budget — skip+say once per unresolved turn
    empty_completion_retries: u8 = 0, // degenerate empty completions re-asked this turn (agent_empty_completion.zig)
    precompact_note_gen: ?u32 = null, // #391: history_rewrites at the last pre-compaction note-to-self, so one history generation buys at most one note however often compaction is retried (compact_note.decideCalls)
    ws_off: bool = false, // codex ws transport disabled for this session after a handshake/transport fallback to SSE (#codex-ws)
    ws_transport_failures: u8 = 0, // consecutive WS failures; retry once before latching persistent SSE
    streamed_text: bool = false, // the last request printed its text live
    request_started: ?Io.Timestamp = null, // operational TTFT origin for the active model call (#602)
    first_token_traced: bool = false,
    thinking_open: bool = false, // a live "Thinking" reasoning block is currently streaming (/thinking)
    thinking_rows: usize = 0, // on-screen rows the live Thinking block spans (#75 collapse)
    thinking_col: usize = 0, // running column within the block, for soft-wrap counting
    thinking_overflow: bool = false, // block scrolled past the screen -> don't erase on collapse
    thinking_folded: bool = false, // user folded the live Thinking block (#92)
    thinking_text: std.ArrayList(u8) = .empty, // buffered reasoning, so a fold can unfold (#92)
    ai_title_done: bool = false, // the one-time AI tab-title call has run this session
    title_generation: u64 = 0, // invalidates detached results across /clear, /new, and manual /rename
    session_recap: ?@import("recap.zig").Recap = null, // last turn-end recap (#419): the session_recap wire event, and /status's recap line
    recap_generation: u64 = 0, // bumped at every turn start: supersedes detached recap jobs still in flight (#419)
    arg_live: ArgLive = .{}, // live attempt_completion/ask_user argument text
    streamed_args: ArgTool = .none, // which meta tool's prose streamed live this request
    streamed_args_len: usize = 0, // raw bytes emitted for it (gates re-print suppression)
    cap_new: bool = false, // provider rejected max_tokens → use max_completion_tokens
    sox_json_object: bool = false, // #543: provider rejected response_format json_schema → json_object + schema-in-prompt
    effort_rejected: bool = false, // model rejected reasoning_effort → drop it (e.g. gpt-5.5 on chat/completions wants /v1/responses)
    output_schema: ?[]const u8 = null, // --output-schema: JSON schema the final answer must satisfy (response_format / text.format, #502)
    next_ask_id: u64 = 1,
    tui_header_shown: bool = false,

    // Width-budgeted status-line rendering lives in agent_prompt.zig (#209,
    // 600-line goal); member-aliased so `self.prompt()` still reads as one
    // of Agent's own methods.
    pub const prompt = prompt_ui.prompt;

    // say()/sayApiError() human-facing lines and emit() — the structured
    // --json JSONL writer — live in agent_output.zig (#422, 600-line cap).
    // Member-aliased so `self.say(...)`/`self.emit(...)` resolve unchanged.
    pub const say = @import("agent_output.zig").say;
    pub const sayApiError = @import("agent_output.zig").sayApiError;
    pub const emit = @import("agent_output.zig").emit;

    pub fn systemPrompt(self: *const Agent) []const u8 {
        if (self.review_mode) return self.sys_override orelse self.sys_normal;
        if (self.sub) return self.sys_override orelse prompts.sub_system_prompt;
        // #326: ultra composes onto normal/strict rather than replacing it.
        return if (self.strict) (if (prompts.ultracodeActive(self)) self.sys_ultra_strict else self.sys_strict) else (if (prompts.ultracodeActive(self)) self.sys_ultra else self.sys_normal);
    }

    /// Whether the active provider honors a reasoning-effort hint: the
    /// Responses API (codex, native xAI) via reasoning.effort, and the
    /// OpenAI-compatible providers that normalize reasoning_effort — native
    /// xAI chat, the codegraff gateway, and deepseek. Everything else ignores it.
    pub fn effortApplies(self: *const Agent) bool {
        return schema.providerTakesEffort(self.provider.kind, self.provider.id, self.provider.model);
    }

    /// Whether this turn should put reasoning_effort on the wire. Gemini 3.x
    /// maps that field to thinking_level; the default medium makes every
    /// turn think for seconds (2× wall vs Pi, which omits it). /effort still
    /// applies — we only skip the unset default.
    pub fn sendReasoningEffort(self: *const Agent) bool {
        if (!self.effortApplies() or self.effort_rejected) return false;
        if (std.mem.startsWith(u8, self.provider.model, "gemini") and self.reasoning == .medium) return false;
        return true;
    }

    pub fn toolsJson(self: *const Agent) []const u8 {
        return @import("agent_catalog.zig").toolsJson(self);
    }

    pub fn ensureRootTools(self: *Agent, kind: Provider.Kind) !void {
        return @import("agent_catalog.zig").ensureRootTools(self, kind);
    }

    /// A live MCP registry change invalidates provider-specific catalogs. The
    /// active format is immediately rebuilt; inactive formats remain lazy.
    pub fn invalidateRootTools(self: *Agent) void {
        if (self.sub) return;
        @import("prompt_cache_hud.zig").noteBust(.tools);
        self.tools_anthropic = "";
        self.tools_openai = "";
        self.tools_responses = "";
    }

    pub noinline fn ensureModelCatalog(self: *Agent, keys: provider_mod.Keys) void {
        if (self.model_catalog) |*catalog|
            catalog.ensure(self.io, self.gpa, self.arena, self.home, keys.get("codex") orelse "", keys.codex_account);
    }

    pub fn reloadModelCatalog(self: *Agent, keys: provider_mod.Keys) void {
        if (self.model_catalog) |*catalog| catalog.invalidate();
        self.ensureModelCatalog(keys);
    }

    pub noinline fn ensureStoredKeys(self: *Agent, keys: *provider_mod.Keys) void {
        if (self.stored_keys_loaded) return;
        if (self.home.len != 0) keys_cli.loadMissingStoredKeys(self.io, self.gpa, self.arena, self.home, keys, .all);
        self.stored_keys_loaded = true;
    }

    /// Close the held codex Responses WS session and reset the delta state, so the
    /// next request re-anchors with full input. The chain now spans user turns
    /// (codex_chain.zig guards it), so this is for errors, idle and compaction.
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
        self.codex_ws_opened_ms = 0;
    }

    pub fn runTurn(self: *Agent) anyerror![]const u8 {
        // Defensive for restored/embedded agents whose provider was assigned
        // directly instead of going through providers.applyProvider.
        try self.ensureRootTools(self.provider.kind);
        // No per-turn teardown: the socket and the chain span user turns, guarded by codex_chain.usable instead.
        self.completed = null;
        if (!self.sub and !root_turn_prepared.swap(false, .acq_rel)) esc_cancel.store(false, .release);
        while (true) {
            if (try @import("turn_chrome.zig").beforeRequest(self)) |paused| return paused;
            // Esc during a tool join lands here; root consumes, subagents bail.
            if (esc_cancel.load(.acquire)) {
                if (!self.sub) esc_cancel.store(false, .release);
                return error.Interrupted;
            }
            // #469: co-resident sessions' queued channel messages land at EVERY
            // step boundary, so a working session picks a peer's note up
            // mid-task (between tool batches) and can act on it in the same
            // turn — durable in history, visible as an event. Offset-based:
            // an empty channel costs one small stat per step.
            peer_channel.deliverInbound(self);
            job_notify.deliver(self);
            schedule.deliver(self);
            channel_worker.deliver(self);
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
                // Match the between-turn policy: at the ordinary compactAt
                // threshold, a transient/empty summary must not immediately drop
                // real history. Destructive recovery is reserved for >=95%.
                const recovery_meter = self.effectiveContextTokens();
                self.autocompact(recovery_meter);
                self.closeCodexWs();
            }
            // ADR 0030: showcase rlm once the existing compact meter is
            // actually large. Schema rides the tail; head bytes stay put.
            if (!self.sub) {
                const fold = @import("native_fold.zig");
                if (fold.noticeContext(self.effectiveContextTokens(), self.provider.compactAt())) {
                    self.invalidateRootTools();
                    try self.ensureRootTools(self.provider.kind);
                }
            }
            const hist_len = self.messages.items.len;
            const root = try self.request(if (self.text_only) null else self.toolsJson());
            const done = switch (self.provider.kind) {
                .anthropic => try self.stepAnthropic(root),
                .openai => try self.stepOpenAI(root),
                .responses => try self.stepResponses(root),
            };
            if (done) |final_text| {
                // A completion with no text and no tool calls used to end the turn
                // silently — mid-task that just looks like a dead session.
                if (try empty_completion.handle(self, final_text, hist_len)) continue;
                return final_text;
            }
            self.empty_completion_retries = 0;
        }
    }

    // The provider round trip (request/buildBody + usage/cost recording +
    // Codex/Responses SSE reassembly) lives in agent_request.zig (#123,
    // 600-line goal). Member-aliased so self.request(...)/etc. resolve
    // unchanged.
    pub const request = @import("agent_request.zig").request;
    pub const inputOverCompactThreshold = @import("agent_request.zig").inputOverCompactThreshold;
    pub const fullInputEstimateTokens = @import("agent_request.zig").fullInputEstimateTokens;
    pub const fullRequestEstimateTokens = @import("agent_request.zig").fullRequestEstimateTokens;
    pub const contextEstimate = @import("agent_request.zig").contextEstimate;
    pub const contextEstimateFromInputBytes = @import("agent_request.zig").contextEstimateFromInputBytes;
    pub const effectiveContextTokens = @import("agent_request.zig").effectiveContextTokens;
    pub const pairContextMeterWithCurrentLocal = @import("agent_request.zig").pairContextMeterWithCurrentLocal;
    pub const rebaseContextMeter = @import("agent_request.zig").rebaseContextMeter;
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
    pub const askUser = @import("ask_user.zig").askUser;
    pub const emitAskUser = @import("ask_user.zig").emitAskUser;
    pub const sayToolUse = @import("agent_tools.zig").sayToolUse;
    pub const sayToolResult = @import("agent_tools.zig").sayToolResult;
    pub const renderTodos = goal_state.renderTodos; // body in goal_state.zig (600-line cap)

    // Context management (compaction/emergency-trim) and the --eval/--until
    // eval-driven loop (+ optional LLM-as-judge) live in agent_compact.zig
    // (#123, 600-line goal). Member-aliased so self.compact(...)/etc.
    // resolve unchanged.
    pub const runEval = @import("agent_compact.zig").runEval;
    pub const appendEvalLog = @import("agent_compact.zig").appendEvalLog;
    pub const runJudge = @import("agent_compact.zig").runJudge;
    pub const compact = @import("agent_compact.zig").compact;
    pub const recentContextStart = @import("agent_compact.zig").recentContextStart;
    pub const cleanUserTurn = @import("agent_compact.zig").cleanUserTurn;
    pub const emergencyCutIndex = @import("agent_compact.zig").emergencyCutIndex;
    pub const emergencyTrim = @import("agent_compact.zig").emergencyTrim;
    pub const compactOrRecover = @import("agent_compact.zig").compactOrRecover;
    pub const manualCompact = @import("agent_server_compact.zig").manualCompact;
    pub const autocompact = @import("agent_server_compact.zig").autocompact;
    pub const autocompactResumed = @import("agent_server_compact.zig").autocompactResumed;
    pub const capOversizedToolOutputs = @import("agent_compact.zig").capOversizedToolOutputs;

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
    // single-threaded start/stop, polling the stop flag every 20ms on the
    // pool so stopping is near-instant. Picked via /animation (ported in
    // spirit from arpagon/pi-animations, MIT), persists in settings.json.
    pub var g_spin_stop: std.atomic.Value(bool) = .init(true);
    pub var g_spin_future: ?Io.Future(void) = null;
    pub const spinnerTask = @import("agent_stream_render.zig").spinnerTask;
    pub const spinnerStart = @import("agent_stream_render.zig").spinnerStart;
    pub const spinnerStop = @import("agent_stream_render.zig").spinnerStop;
    pub const streamThinking = @import("agent_stream_render.zig").streamThinking;
    pub const closeThinkingBlock = @import("agent_stream_render.zig").closeThinkingBlock;
    pub const toggleThinkingFold = @import("agent_stream_render.zig").toggleThinkingFold;
    pub const postStream = @import("agent_stream.zig").postStream;
    pub const postStreamWithClient = @import("agent_stream.zig").postStreamWithClient;
    pub const printDelta = @import("agent_stream.zig").printDelta;
    pub const traceFirstToken = @import("agent_observability.zig").firstToken;
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
    var root_turn_prepared: std.atomic.Value(bool) = .init(false);
    pub var esc_watch_done: std.atomic.Value(bool) = .init(true);

    /// Clear stale cancellation before the root becomes externally cancellable;
    /// runTurn consumes the marker without erasing a cancellation arriving later.
    pub fn prepareRootTurn() void {
        esc_cancel.store(false, .release);
        root_turn_prepared.store(true, .release);
    }

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

    pub fn messageMutationAlloc(self: *Agent) Allocator {
        return self.message_mutation_arena orelse self.arena;
    }

    pub const escWatchTask = @import("agent_interrupt.zig").escWatchTask;
    pub const escPressed = @import("agent_interrupt.zig").escPressed;
    pub const drainSteerStdin = @import("agent_interrupt.zig").drainSteerStdin;
    pub const drainStdin = @import("agent_interrupt.zig").drainStdin;
    pub const rawNonblockStdin = @import("agent_interrupt.zig").rawNonblockStdin;
    pub const restoreStdin = @import("agent_interrupt.zig").restoreStdin;
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

test {
    _ = @import("agent_prompt.zig");
    _ = @import("effort_route.zig");
    try agent_tests.lazyRootTools(Agent);
}

test "say: an over-long worker line still ends its row (#tui-tick)" {
    try agent_tests.workerLineAlwaysEndsRow(Agent);
}
