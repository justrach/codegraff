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
};

/// Durable events are the protocol stream: what the --json wire emits today
/// and what a future event log persists. Only they reserve sequence ids —
/// presentation pulses must not open gaps in the wire's numbering.
pub fn durable(ev: EngineEvent) bool {
    return switch (ev) {
        .reasoning_delta, .text_delta => true,
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

test "generation only moves forward, one restart at a time" {
    const before = generation();
    try std.testing.expect(before >= 1);
    try std.testing.expectEqual(before + 1, bumpGeneration());
    try std.testing.expectEqual(before + 1, generation());
}
