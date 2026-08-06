//! The engine's internal event vocabulary (#422 slice 1): one tagged union of
//! every distinct output emission the live streaming path (agent_stream.zig)
//! produces, expressed as semantic content — no ANSI, no pre-rendered text.
//! Frontends never see engine internals: a sink (engine_sink.zig) receives
//! these events and renders them (TUI) or serializes them (--json wire).
//!
//! Growth rules for the vocabulary:
//! - New engine output = a new variant (or a new field on a payload struct),
//!   never a pre-rendered string where structure exists. Rendering choices
//!   (color, spinners, wording of notices) belong to sinks.
//! - `durable` classifies each variant: durable events are the protocol
//!   stream a wire/log sink persists and are what reserve sequence ids;
//!   everything else is a presentation pulse that rides at the current
//!   position. Promoting a pulse to the wire is an externally visible shape
//!   change and is gated behind a schema_version bump (epic #422 rule 1).
//! - Payloads are structs so fields can grow without call-site churn.

const std = @import("std");
const protocol_seq = @import("protocol_seq.zig");

/// Position of an event in a session's event log. `sequence` alone is
/// meaningless across restarts: `generation` increments whenever the log
/// restarts (process restart, resume — wired in a later #422 slice), and
/// `sequence` is monotonic within a generation (protocol_seq.zig, the one
/// counter the --json wire already stamps).
pub const Cursor = struct {
    generation: u64,
    sequence: u64,
};

/// Why a delta stream stopped before the provider's terminal event.
pub const StreamAbort = enum {
    /// The user cancelled (Esc) — a deliberate stop, rendered silently.
    interrupted,
    /// The stream went silent past its watchdog budget, or the read path lost
    /// its watchdog (pool exhaustion) — the harness is ending the turn.
    stalled,
    /// The provider closed/reset the socket before its terminal event (#133).
    dropped,
};

/// A streamed content chunk. `text` is never empty — emitters drop empty
/// deltas before dispatch.
pub const Delta = struct {
    text: []const u8,
};

/// A live transport attempt was cut before the provider's terminal event —
/// the transport-layer counterpart of StreamAbort, born in the connection/
/// read guards (agent_ws.zig slice 1b) where nothing of the answer has
/// rendered yet: sinks may surface a notice but have no held output to
/// flush. `reason == .interrupted` is never emitted today (a deliberate Esc
/// propagates as an error, silently); a sink renders nothing for it.
pub const TransportAbort = struct {
    reason: StreamAbort,
    /// The guard is giving the turn up (its notice says so); false = an
    /// attempt-level cut the reconnect ladder may still retry, surfaced
    /// more tersely.
    turn_ending: bool,
};

/// One tool call as the engine hands it to a frontend (#422 slice 1c).
/// `ask_user` is called out on its own because a --json client learns of
/// that moment through its own `ask_user` event, never as a tool-call pair.
/// `arg_streamed` says the call's prose already streamed out of its
/// still-in-flight arguments (agent_argstream.zig), so an announcement line
/// would repeat what the reader just watched arrive.
pub const ToolInvocation = struct {
    name: []const u8,
    input: std.json.Value,
    ask_user: bool = false,
    arg_streamed: bool = false,
};

/// One finished tool call. `text` is the model-facing result the engine
/// already capped and previewed; `ms` is its measured wall clock. `meta`
/// marks a meta tool (schema.isMetaName) — those own their UX and, except
/// for ask_user, never carried a result on the wire.
pub const ToolOutcome = struct {
    name: []const u8,
    text: []const u8,
    is_error: bool,
    cancelled: bool = false,
    ms: i64 = 0,
    meta: bool = false,
    ask_user: bool = false,
};

/// A tool call the harness refused before it ran: the verifier boundary, a
/// stale eval, the --max-tool-calls budget, the dedupe rule, or review mode.
pub const ToolRejection = struct {
    name: []const u8,
    input: std.json.Value,
    reason: []const u8,
    message: []const u8,
};

/// How a parallel tool batch ended (#266): the tallies, not a rendered line.
pub const BatchOutcome = struct { done: usize, failed: usize, cancelled: usize };

/// Text whose layout belongs to the meta tool that produced it (a completion
/// answer, a rendered todo list) — carried whole because the structure lives
/// in that tool's own module, not in this vocabulary.
pub const ToolText = struct { text: []const u8 };

/// One operational line about the session itself (slice 2): a config file that
/// did not parse, an MCP server that would not connect, what startup loaded.
/// The engine owns the wording — the shared shape is what keeps the lifecycle
/// cluster from needing a variant per call site — and a sink owns how loud it
/// looks. Anything with real structure a frontend would want to read gets its
/// own variant instead (see session_banner and its neighbours below).
pub const Notice = struct {
    /// An emphasized opening fragment (a badge like "⚠ YOLO") a sink may draw
    /// apart from the rest of the line; empty for an ordinary notice.
    lead: []const u8 = "",
    text: []const u8,
    tone: Tone = .plain,

    /// How much attention the line is asking for — the only rendering decision
    /// the engine delegates, since it is about meaning, not palette.
    pub const Tone = enum { plain, dim, warn, alert };
};

/// The interactive startup line. Only the two facts vary per run; what else
/// goes on it (the key hints) is frontend knowledge and lives in the sink.
pub const SessionBanner = struct { cwd: []const u8, trace_path: []const u8 };

/// `-w/--worktree` entered its scratch checkout. `autocommit` says the run
/// will checkpoint each turn onto that branch (main.g_worktree_autocommit).
pub const WorktreeEntry = struct { path: []const u8, branch: []const u8, autocommit: bool };

/// Startup could not honor the saved model preference and picked another.
/// `blocked` means the substitute is cross-provider and not on the fallback
/// allow-list, so it stays a one-session choice until the user widens it.
pub const SavedModelNotice = struct {
    saved: []const u8,
    model: []const u8,
    provider: []const u8,
    blocked: bool,
};

/// A mid-turn provider failover (providers.runTurnWithFallback). Wire: the
/// existing `model` event, which carries the SUBSTITUTE only — `context_note`
/// (what happened to the conversation across the switch) is the terminal's
/// half, and the wire's own fixed note lives in the sink that writes it.
pub const ProviderFallback = struct {
    from_provider: []const u8,
    from_model: []const u8,
    to_provider: []const u8,
    to_model: []const u8,
    to_context: u64,
    context_note: []const u8,
};

/// The durable session file was written. `ext` is session.session_ext, kept in
/// the payload rather than the sink because the extension belongs to the
/// session format, not to any frontend.
pub const SessionSaved = struct { name: []const u8, ext: []const u8 };

// ── The interactive status line (#429 batch 3) ───────────────────────────────
// Its own value types rather than main.zig's/learning_privacy's: this file is
// the vocabulary, and a transport-split sink must be able to read an event
// without importing the engine. The emit site maps with an exhaustive switch,
// so adding a tier upstream is a compile error here rather than a silent
// mistranslation.

/// Reasoning depth, when the provider takes one at all (main.ReasoningEffort).
pub const ReasoningEffort = enum { low, medium, high, xhigh, max, ultra };

/// The federated-learning privacy ceiling (learning_privacy.Mode).
pub const PrivacyTier = enum { local, aggregate, templates, examples };

/// What the cost meter can say. Deliberately not a pre-formatted string: only
/// `.usd` has a figure, and the other three are states, not numbers.
pub const CostMeter = union(enum) {
    /// The meter is off (--no-cost): the segment does not exist.
    hidden,
    /// A flat-rate provider (codex): spend is not per-turn, so there is no
    /// figure to show.
    subscription,
    /// No price-table entry for this model — a real figure cannot be derived.
    unpriced,
    /// Session spend so far, in US dollars.
    usd: f64,
};

/// The live context meter. Present only once a response has reported usage;
/// `tokens` is the effective count, which is not always what the last response
/// said (local estimates carry it between turns).
pub const ContextMeter = struct {
    tokens: u64,
    window: u64,
    /// The count at which this provider compacts.
    compact_at: u64,
};

/// Everything the status line printed before a human turn actually says.
/// Deliberately semantic: no widths, no colors, no assembled segments. Which
/// badges survive a narrow pane is a rendering decision (#209) and belongs to
/// the sink, which is the only thing that knows the terminal.
pub const PromptStatus = struct {
    model: []const u8,
    provider_id: []const u8,
    cwd: []const u8,
    /// The privacy mode's own badge wording, owned by learning_privacy.zig —
    /// carried whole for the same reason ToolText is, while the tier beside it
    /// is what a sink picks a tone from.
    privacy_label: []const u8,
    privacy: PrivacyTier,
    /// null when this provider takes no reasoning effort, so no badge exists.
    effort: ?ReasoningEffort = null,
    /// null until a response has reported usage.
    context: ?ContextMeter = null,
    /// Prompt-cache hit on the last response; 0 = nothing cached.
    cache_read: u64 = 0,
    cost: CostMeter = .hidden,
    /// The Fast badge APPLIES — the flag is on and the provider honors it.
    fast: bool = false,
    fallback: bool = false,
    plan: bool = false,
    strict: bool = false,
    ultracode: bool = false,
};

/// Everything the streaming path tells a frontend. Each doc comment states
/// the emission site's contract, not how any one sink draws it.
pub const EngineEvent = union(enum) {
    /// A streaming model request is in flight; nothing has arrived yet. The
    /// TUI answers with the thinking spinner and a fresh per-stream render
    /// state; the wire has no shape for it.
    stream_begin,
    /// A chunk of the model's reasoning ("thinking") text. Wire: the
    /// existing `reasoning` event. TUI: the live dimmed Thinking block,
    /// gated by /thinking.
    reasoning_delta: Delta,
    /// A chunk of visible answer text. Wire: the existing `text` event.
    /// TUI: streamed markdown (or raw bytes off-color). The first one also
    /// ends the reasoning presentation (block close, spinner stop).
    text_delta: Delta,
    /// A chunk of user-facing prose streamed out of a whitelisted meta tool
    /// call's still-in-flight arguments (attempt_completion's result,
    /// ask_user's question — agent_argstream.zig, slice 1b). Never on the
    /// wire: --json clients get the assembled tool_call instead, so a wire
    /// sink stays silent. TUI: renders like answer text (spinner handoff
    /// included) but does NOT end the reasoning presentation — argument
    /// prose can stream while the model is still mid-call.
    tool_arg_delta: Delta,
    /// A live transport attempt was cut; the payload says how and whether
    /// the turn ends with it (slice 1b). Distinct from stream_aborted: no
    /// partial answer is in flight, so sinks notice without flushing.
    transport_aborted: TransportAbort,
    /// The user asked to fold/unfold the live reasoning view (Ctrl-T, #92).
    /// Presentation-only; a headless frontend ignores it. TRANSITIONAL
    /// (Phase 1b): this is frontend INPUT round-tripping engine-ward through
    /// a global (g_thinking_fold_request) and coming back out — when input
    /// inversion lands it leaves this union (a frontend-owned command, not an
    /// engine event), so plan for removal, not extension.
    thinking_fold_toggle,
    /// The delta stream was cut before its terminal event; the payload says
    /// how. Sinks flush any held partial output and may surface a notice for
    /// the non-deliberate reasons.
    stream_aborted: StreamAbort,
    /// The delta stream ended normally (terminal event seen). streamed_text:
    /// at least one text_delta was emitted live, so the TUI ends the answer
    /// line.
    stream_complete: struct { streamed_text: bool },
    /// The streaming transport call is fully over — emitted on EVERY exit
    /// path, after stream_complete/stream_aborted when those fired. Sinks
    /// tear down live-stream presentation (spinner, an open reasoning-only
    /// Thinking block).
    stream_finished,

    // ── The tool-execution cluster (slice 1c) ────────────────────────────
    /// A tool call cleared the gates and is about to run. Wire: the existing
    /// `tool_call` event. TUI: the ⚙ announcement line.
    tool_call_announced: ToolInvocation,
    /// The same call, now dispatched — the bracket a supervisor times against.
    /// Wire: the existing `tool_call_started` event. TUI: nothing (the ⚙ line
    /// already said it).
    tool_call_started: ToolInvocation,
    /// A tool call returned. Wire: the existing `tool_result` event. TUI: the
    /// compact ✓/✗/⊘ line with a one-line preview.
    tool_result: ToolOutcome,
    /// The same call's closing bracket, carrying the outcome and duration
    /// rather than the text. Wire: `tool_call_finished`. TUI: nothing.
    tool_call_finished: ToolOutcome,
    /// A tool call the harness refused before running it. Wire: the existing
    /// `tool_rejected` event; the TUI has never drawn one (the refusal reaches
    /// the user as the model's next answer).
    tool_rejected: ToolRejection,
    /// A batch of external tool calls is fanning out across the pool.
    /// Presentation-only: the wire brackets each call individually.
    parallel_batch_started: struct { count: usize },
    /// That batch is joined; the payload is the tally (#266 — a cancelled
    /// batch used to just look "running" and then fail).
    parallel_batch_finished: BatchOutcome,
    /// attempt_completion was refused because the standing goal's checklist
    /// is not settled (#318). Presentation-only; the model gets the refusal
    /// as its tool result.
    completion_deferred,
    /// A standing --goal was retired by an accepted attempt_completion.
    goal_completed,
    /// The answer attempt_completion carried, surfaced because it did NOT
    /// stream live out of the call's arguments.
    completion_text: ToolText,
    /// todo_write applied; the payload is the list as goal_todo rendered it.
    todo_list_updated: ToolText,

    // ── The session-lifecycle cluster (slice 2) ──────────────────────────
    // These fire around the turn loop rather than inside it: startup, config
    // loading, provider failover, shutdown. Most of them happen before an
    // Agent exists or after it stops mattering, which is why they reach a
    // sink through engine_sink.writerSink rather than forAgent.
    //
    // The `!json_mode` / `oneshot_prompt == null` gates stay at the EMIT
    // sites, as slice 1c's review put the `!sub` gates back: who may write to
    // the terminal at all is engine policy about who owns it, not a drawing
    // decision, and a sink has no way to know a run is a one-shot.
    /// An operational line about the session. Presentation-only: none of these
    /// ever appeared on the --json wire.
    session_notice: Notice,
    /// The interactive startup banner.
    session_banner: SessionBanner,
    /// `-w/--worktree` entered its scratch checkout.
    worktree_entered: WorktreeEntry,
    /// The saved model preference could not be honored this session. The
    /// startup twin of provider_fallback, and deliberately not a Notice: a
    /// frontend that wants to offer "use it anyway" needs the fields.
    saved_model_unavailable: SavedModelNotice,
    /// Untrusted MCP servers are configured and the session wants a decision
    /// before connecting them. TRANSITIONAL (Phase 1b): only the QUESTION is
    /// inverted here — the stdin read still happens at the emit site. When
    /// input inversion lands (#430) this becomes a request answered by a
    /// `respond` command, so plan for replacement, not extension.
    mcp_consent_prompt: struct { count: usize },
    /// The active provider failed over mid-turn. Wire: the existing `model`
    /// event; the terminal draws a notice instead.
    provider_fallback: ProviderFallback,
    /// The durable session file was written.
    session_saved: SessionSaved,
    /// The run is over and the engine is done with the frontend: a terminal
    /// frontend hands raw mode back here (#396). Emitted on the one-shot's
    /// completion path in EVERY mode, so a sink must not gate it on json_mode.
    run_finished,

    /// A human turn is about to be read: this is what the session looks like
    /// right now (#429). Presentation-only and always will be — the --json
    /// wire has no prompt because an SDK client drives turns itself, which is
    /// why the emit site skips json_mode entirely rather than relying on a
    /// silent sink.
    prompt_ready: PromptStatus,
};

/// Durable events are the protocol stream: what the --json wire emits today
/// and what a future event log persists. Only they reserve sequence ids —
/// presentation pulses must not open gaps in the wire's numbering.
///
/// This reads the PAYLOAD, not just the tag, and it has to: whether a tool
/// moment reaches the wire depends on which tool it is. A durable sink writes
/// exactly the events this returns true for (engine_sink.jsonEmit asserts it),
/// so a reserved id can never burn with no line behind it (#330).
pub fn durable(ev: EngineEvent) bool {
    return switch (ev) {
        .reasoning_delta, .text_delta => true,
        // Every tool's call bracket is on the wire except ask_user's: a
        // --json client is handed that moment as its own `ask_user` event,
        // and answers it on stdin.
        .tool_call_announced, .tool_call_started => |t| !t.ask_user,
        // Meta tools render their own UX and never carried a wire result —
        // except ask_user, whose typed reply IS the result.
        .tool_result, .tool_call_finished => |r| !r.meta or r.ask_user,
        .tool_rejected => true,
        // The lifecycle cluster is presentation-only except the failover,
        // which has always been the wire's `model` event.
        .provider_fallback => true,
        else => false,
    };
}

// Generation 1 is the first life of this process's event log; restart/resume
// wiring bumps it in a later #422 slice (serve attach, #420).
var g_generation: std.atomic.Value(u64) = .init(1);

pub fn generation() u64 {
    return g_generation.load(.monotonic);
}

/// The session's event log restarted: later sequences are a fresh line of
/// history, not a continuation the old cursor can index into.
pub fn bumpGeneration() u64 {
    return g_generation.fetchAdd(1, .monotonic) + 1;
}

/// Stamp a Cursor at the emission boundary. `reserve` draws a fresh id from
/// protocol_seq (durable events on a durable sink; in --json mode the caller
/// holds the stdout lock so reservation and wire order can never diverge —
/// an injected durable sink outside --json currently reserves unlocked, see
/// the engine_sink.zig header note); otherwise the event observes the last
/// reserved position without advancing it.
pub fn stamp(reserve: bool) Cursor {
    return .{
        .generation = generation(),
        .sequence = if (reserve) protocol_seq.next() else protocol_seq.current(),
    };
}

test "every variant constructs; only the wire deltas are durable" {
    const wire: [2]EngineEvent = .{
        .{ .reasoning_delta = .{ .text = "why" } },
        .{ .text_delta = .{ .text = "hi" } },
    };
    for (wire) |ev| try std.testing.expect(durable(ev));
    const pulses: [5]EngineEvent = .{
        .stream_begin,
        .thinking_fold_toggle,
        .{ .stream_aborted = .stalled },
        .{ .stream_complete = .{ .streamed_text = true } },
        .stream_finished,
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
}

test "stamp: reserving draws fresh monotonic ids; observing never advances" {
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    const a = stamp(true);
    const b = stamp(true);
    try std.testing.expectEqual(@as(u64, 1), a.sequence);
    try std.testing.expectEqual(a.sequence + 1, b.sequence);
    // A pulse rides at the last reserved position and reserves nothing.
    const o = stamp(false);
    try std.testing.expectEqual(b.sequence, o.sequence);
    try std.testing.expectEqual(b.sequence, protocol_seq.current());
    try std.testing.expectEqual(generation(), o.generation);
}

test "slice 1b: tool-arg prose and transport aborts are presentation pulses" {
    // Neither ever appeared on the --json wire (argLiveDelta gates --json
    // off; the transport notices were TTY-only), so neither may reserve a
    // sequence id — promoting one is a schema_version event, not a default.
    const pulses: [3]EngineEvent = .{
        .{ .tool_arg_delta = .{ .text = "prose" } },
        .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = true } },
        .{ .transport_aborted = .{ .reason = .dropped, .turn_ending = false } },
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
}

test "slice 1c: the tool bracket is durable per TOOL, not per tag" {
    const call: ToolInvocation = .{ .name = "bash", .input = .null };
    const ask: ToolInvocation = .{ .name = "ask_user", .input = .null, .ask_user = true };
    // An ordinary tool's bracket is the wire's tool_call/tool_call_started…
    try std.testing.expect(durable(.{ .tool_call_announced = call }));
    try std.testing.expect(durable(.{ .tool_call_started = call }));
    // …while ask_user's reaches a --json client as the `ask_user` event, so
    // neither half may reserve an id the wire will not spend (#330).
    try std.testing.expect(!durable(.{ .tool_call_announced = ask }));
    try std.testing.expect(!durable(.{ .tool_call_started = ask }));
    // arg_streamed is a TUI-only suppression: the wire still carries the call.
    const streamed: ToolInvocation = .{ .name = "bash", .input = .null, .arg_streamed = true };
    try std.testing.expect(durable(.{ .tool_call_announced = streamed }));

    const ext: ToolOutcome = .{ .name = "bash", .text = "ok", .is_error = false };
    const meta: ToolOutcome = .{ .name = "todo_write", .text = "ok", .is_error = false, .meta = true };
    const answer: ToolOutcome = .{ .name = "ask_user", .text = "yes", .is_error = false, .meta = true, .ask_user = true };
    try std.testing.expect(durable(.{ .tool_result = ext }));
    try std.testing.expect(durable(.{ .tool_call_finished = ext }));
    try std.testing.expect(!durable(.{ .tool_result = meta }));
    try std.testing.expect(!durable(.{ .tool_call_finished = meta }));
    try std.testing.expect(durable(.{ .tool_result = answer }));
    try std.testing.expect(durable(.{ .tool_call_finished = answer }));

    // A refusal has always been a wire-only moment.
    try std.testing.expect(durable(.{ .tool_rejected = .{ .name = "bash", .input = .null, .reason = "budget", .message = "no" } }));
}

test "slice 1c: the tool-cluster notices are presentation pulses" {
    // None of these ever appeared on the --json wire, so promoting one is a
    // schema_version event rather than refactor fallout.
    const pulses: [6]EngineEvent = .{
        .{ .parallel_batch_started = .{ .count = 3 } },
        .{ .parallel_batch_finished = .{ .done = 2, .failed = 1, .cancelled = 0 } },
        .completion_deferred,
        .goal_completed,
        .{ .completion_text = .{ .text = "done" } },
        .{ .todo_list_updated = .{ .text = "todos" } },
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
}

test "slice 2: the lifecycle cluster is pulses, except the failover the wire carries" {
    const pulses: [8]EngineEvent = .{
        .{ .session_notice = .{ .text = "loaded 2 saved approval(s)", .tone = .dim } },
        .{ .session_banner = .{ .cwd = "/repo", .trace_path = ".graff/traces/a.jsonl" } },
        .{ .worktree_entered = .{ .path = ".graff/worktrees/w", .branch = "worktree-w", .autocommit = true } },
        .{ .saved_model_unavailable = .{ .saved = "old", .model = "new", .provider = "codex", .blocked = false } },
        .{ .mcp_consent_prompt = .{ .count = 3 } },
        .{ .session_saved = .{ .name = "session-1", .ext = ".session.json" } },
        .run_finished,
        // A notice with a badge is still a notice, not a second variant.
        .{ .session_notice = .{ .lead = "⚠ YOLO", .text = " mode", .tone = .alert } },
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
    // The failover has always reached a --json client as the `model` event, so
    // it reserves an id like any other wire line.
    try std.testing.expect(durable(.{ .provider_fallback = .{
        .from_provider = "codex",
        .from_model = "gpt-5.5",
        .to_provider = "anthropic",
        .to_model = "sonnet",
        .to_context = 200_000,
        .context_note = "context kept",
    } }));
}

test "batch 3: the status line is a presentation pulse, never a wire line" {
    // The --json wire has never had a prompt event and must not grow one by
    // accident: a client that drives its own turns would read a burned
    // sequence id as lost data (#330).
    const status: PromptStatus = .{
        .model = "gpt-5.6",
        .provider_id = "codex",
        .cwd = "~/src/graff",
        .privacy_label = "Privacy:Aggregate",
        .privacy = .aggregate,
        .effort = .high,
        .context = .{ .tokens = 12_345, .window = 200_000, .compact_at = 160_000 },
        .cache_read = 2048,
        .cost = .subscription,
    };
    try std.testing.expect(!durable(.{ .prompt_ready = status }));
}

test "generation only moves forward, one restart at a time" {
    const before = generation();
    try std.testing.expect(before >= 1);
    try std.testing.expectEqual(before + 1, bumpGeneration());
    try std.testing.expectEqual(before + 1, generation());
}
