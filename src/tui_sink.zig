//! The fullscreen TUI's EngineSink (#551, the #422 epic).
//!
//! This is the one place that speaks both vocabularies: the engine's
//! `engine_events.EngineEvent` on one side, the frontend-agnostic
//! `tui.Event` on the other. Before it existed the TUI had no sink at all —
//! `engine_sink.hostedEmit` rendered the tool cluster into "⚙ /✓ /✗ " lines,
//! dropped every other event through an `else => {}`, and the TUI recovered
//! what it could by scanning those lines back out of the stream.
//!
//! The split here is deliberate and is the contract the TUI renders from:
//!
//!   - PROSE (answer text, meta-tool argument prose, and — with /thinking on —
//!     reasoning) streams into the live text buffer the pending row tails.
//!   - STRUCTURE (tool calls, outcomes, refusals, notices, failover) is pushed
//!     as a typed event with fields. Nothing is rendered here for a frontend
//!     to parse again.
//!
//! Every EngineEvent variant is handled explicitly. The ones with no TUI
//! surface today are grouped and say WHY they are ignored — a bare `else` is
//! how the reasoning stream went missing for as long as it did.

const std = @import("std");

const engine_events = @import("engine_events.zig");
const EngineEvent = engine_events.EngineEvent;
const engine_sink = @import("engine_sink.zig");
const repl = @import("repl.zig");
const tui = @import("tui");

/// Result previews are one line, capped — the same budget hostedEmit used, so
/// a row's body stays a body and a 20 KB tool result never reaches the queue.
const preview_cap: usize = 80;
/// Arguments get more room: a path or a command IS the row's identity, and
/// truncating one at 80 columns is how a reader loses which file was touched.
const arg_cap: usize = 160;

/// One line of `text`, at most `cap` bytes, ending on a UTF-8 boundary. A byte
/// cap alone can split a multi-byte codepoint, and half a glyph in the
/// transcript is a rendering bug the reader gets to see.
fn capLine(text: []const u8, cap: usize) []const u8 {
    return dropPartialTail(engine_sink.firstLineCap(text, cap));
}

/// Drop a trailing INCOMPLETE UTF-8 sequence, and nothing else — a whole
/// multi-byte character at the end must survive.
fn dropPartialTail(s: []const u8) []const u8 {
    var i = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        const b = s[i];
        if (b & 0x80 == 0) return s; // ASCII tail: nothing is half-written
        if (b & 0xC0 != 0x80) {
            // A lead byte: keep the character only if all of it is here.
            const need = std.unicode.utf8ByteSequenceLength(b) catch return s[0..i];
            return if (i + need <= s.len) s else s[0..i];
        }
    }
    return s;
}

/// The per-turn wiring a TUI turn hands the engine. Lives on the turn caller's
/// frame (tui_launch.turnCb) for exactly as long as the turn runs.
pub const Bridge = struct {
    /// Typed events for the transcript. Lock-guarded, so the parallel tool
    /// pool may push from its own threads.
    queue: *tui.EventQueue,
    /// The live prose buffer the pending row tails. Single-writer by contract:
    /// only the streaming reader (the turn thread) writes deltas.
    stream: *repl.StreamBuf,
    /// /thinking — whether reasoning belongs in the live tail at all.
    show_thinking: bool = false,
    /// Reasoning has been written and no answer text has followed it yet, so
    /// the first visible byte should break the line first.
    reasoning_open: bool = false,
};

const vtable: engine_sink.VTable = .{ .emit = emit, .durable = false };

pub fn forBridge(b: *Bridge) engine_sink.EngineSink {
    return .{ .ctx = @ptrCast(b), .vt = &vtable };
}

fn emit(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const b: *Bridge = @ptrCast(@alignCast(ctx));
    switch (ev.event) {
        // ── prose: into the live tail ────────────────────────────────────
        .reasoning_delta => |d| if (b.show_thinking) {
            b.reasoning_open = true;
            b.stream.appendBytes(d.text);
        },
        .text_delta, .tool_arg_delta => |d| {
            if (b.reasoning_open) {
                b.reasoning_open = false;
                b.stream.appendBytes("\n");
            }
            b.stream.appendBytes(d.text);
        },
        // A meta tool owns this text's layout, so it arrives whole.
        .completion_text, .todo_list_updated => |t| {
            b.stream.appendBytes(t.text);
            b.stream.appendBytes("\n");
        },

        // ── structure: typed rows ────────────────────────────────────────
        .tool_call_announced => |t| b.queue.push(.{ .tool_started = .{
            .name = t.name,
            .detail = capLine(engine_sink.compactArg(t.input), arg_cap),
        } }),
        .tool_result => |r| b.queue.push(.{ .tool_finished = .{
            .name = r.name,
            .detail = capLine(r.text, preview_cap),
            .is_error = r.is_error,
        } }),
        // The harness refused the call before it ran. hostedEmit dropped this
        // outright, so the row simply never closed and the user watched a tool
        // that looked stuck.
        .tool_rejected => |r| b.queue.push(.{ .tool_rejected = .{
            .name = r.name,
            .detail = capLine(r.message, preview_cap),
            .is_error = true,
            .denied = true,
        } }),

        // ── notices: system rows ─────────────────────────────────────────
        .session_notice => |n| {
            // A notice may open with an emphasized badge ("⚠ YOLO"); the TUI's
            // system row has one style, so the two halves are joined here
            // rather than half of it being dropped. The queue copies, so a
            // stack buffer is enough and nothing is allocated on this path.
            var buf: [512]u8 = undefined;
            const line = if (n.lead.len == 0)
                n.text
            else
                std.fmt.bufPrint(&buf, "{s}{s}", .{ n.lead, n.text }) catch n.lead;
            b.queue.push(.{ .notice = line });
        },
        .transport_aborted => |t| switch (t.reason) {
            // A deliberate Esc is silent here as everywhere: finishJob already
            // writes the one "■ interrupted" row.
            .interrupted => {},
            .stalled => b.queue.push(.{ .notice = "⚠ stream stalled" }),
            .dropped => b.queue.push(.{ .notice = "⚠ connection dropped" }),
        },
        .stream_aborted => |reason| switch (reason) {
            .interrupted => {},
            .stalled => b.queue.push(.{ .notice = "⚠ stream stalled — ending turn" }),
            .dropped => b.queue.push(.{ .notice = "⚠ connection dropped — response ended early" }),
        },
        // The status bar's model name is a TUI-owned global; a mid-turn
        // failover is the one thing that can change it behind the frontend's
        // back, so the event carries the substitute and the TUI adopts it.
        .provider_fallback => |f| b.queue.push(.{ .model_changed = f.to_model }),

        // ── consciously ignored, with the reason ─────────────────────────
        // Live-stream bookkeeping: the TUI's pending row IS the spinner, and
        // its fold state is frontend-owned, so none of these need a surface.
        .stream_begin, .stream_complete, .stream_finished, .thinking_fold_toggle => {},
        // The engine's own call brackets. tool_call_announced/tool_result are
        // the pair a transcript row is built from; these two are the timing
        // brackets a supervisor uses and would double every row here.
        .tool_call_started, .tool_call_finished => {},
        // Tool-run colour the compact transcript deliberately does not draw:
        // batch fan-out/join tallies, the completion-gate refusal, and a
        // retired standing goal. Each is a candidate for its own row later;
        // none has one today.
        .parallel_batch_started, .parallel_batch_finished, .completion_deferred, .goal_completed => {},
        // Session lifecycle that happens OUTSIDE a turn: by the time a turn's
        // sink exists the banner, worktree entry, checkout-owner warning and
        // saved-model substitution have all already been decided, and the MCP
        // consent prompt still reads stdin at its emit site (#422 phase 1b).
        .session_banner,
        .worktree_entered,
        .shared_worktree_owner,
        .saved_model_unavailable,
        .mcp_consent_prompt,
        .session_saved,
        .run_finished,
        => {},
        // The pre-turn status line. The TUI draws its own chrome from its own
        // Model, so adopting this needs the context/cost meters to move into
        // that Model first — a later slice of #551, not a silent drop here.
        .prompt_ready => {},
    }
}

test "prose streams into the live tail; structure never does" {
    var qbuf: tui.EventQueue = .{};
    qbuf.attach(std.testing.allocator);
    defer qbuf.deinit();
    var sbuf: [256]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &sbuf };
    var bridge: Bridge = .{ .queue = &qbuf, .stream = &stream };
    const sink = forBridge(&bridge);

    sink.emit(undefined, .{ .text_delta = .{ .text = "hello" } });
    sink.emit(undefined, .{ .tool_call_announced = .{ .name = "bash", .input = .null } });
    sink.emit(undefined, .{ .tool_result = .{ .name = "bash", .text = "ok\nmore", .is_error = false } });
    sink.emit(undefined, .{ .text_delta = .{ .text = " world" } });

    const snap = stream.snapshot(std.testing.allocator) orelse return error.NoStream;
    defer std.testing.allocator.free(snap);
    // The tool cluster left no bytes in the prose buffer — that mixing is what
    // the TUI used to have to un-mix by scanning for glyphs.
    try std.testing.expectEqualStrings("hello world", snap);

    const evs = qbuf.drain();
    defer qbuf.free(evs);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqualStrings("bash", evs[0].tool_started.name);
    try std.testing.expectEqualStrings("ok", evs[1].tool_finished.detail);
    try std.testing.expect(!evs[1].tool_finished.is_error);
}

test "reasoning reaches the tail only with /thinking on" {
    var qbuf: tui.EventQueue = .{};
    qbuf.attach(std.testing.allocator);
    defer qbuf.deinit();
    var off_buf: [64]u8 = undefined;
    var off_stream: repl.StreamBuf = .{ .buf = &off_buf };
    var off: Bridge = .{ .queue = &qbuf, .stream = &off_stream, .show_thinking = false };
    forBridge(&off).emit(undefined, .{ .reasoning_delta = .{ .text = "why" } });
    try std.testing.expect(off_stream.snapshot(std.testing.allocator) == null);

    var on_buf: [64]u8 = undefined;
    var on_stream: repl.StreamBuf = .{ .buf = &on_buf };
    var on: Bridge = .{ .queue = &qbuf, .stream = &on_stream, .show_thinking = true };
    const sink = forBridge(&on);
    sink.emit(undefined, .{ .reasoning_delta = .{ .text = "because" } });
    sink.emit(undefined, .{ .text_delta = .{ .text = "answer" } });
    const snap = on_stream.snapshot(std.testing.allocator) orelse return error.NoStream;
    defer std.testing.allocator.free(snap);
    // The answer breaks the line the reasoning was on rather than running into it.
    try std.testing.expectEqualStrings("because\nanswer", snap);
}

test "a refusal and a failover reach the frontend instead of being dropped" {
    var qbuf: tui.EventQueue = .{};
    qbuf.attach(std.testing.allocator);
    defer qbuf.deinit();
    var sbuf: [64]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &sbuf };
    var bridge: Bridge = .{ .queue = &qbuf, .stream = &stream };
    const sink = forBridge(&bridge);
    sink.emit(undefined, .{ .tool_rejected = .{
        .name = "bash",
        .input = .null,
        .reason = "budget",
        .message = "tool-call budget spent",
    } });
    sink.emit(undefined, .{ .session_notice = .{ .text = "loaded 2 saved approval(s)", .tone = .dim } });
    sink.emit(undefined, .{ .provider_fallback = .{
        .from_provider = "codex",
        .from_model = "gpt-5.5",
        .to_provider = "anthropic",
        .to_model = "sonnet",
        .to_context = 200_000,
        .context_note = "context kept",
    } });
    const evs = qbuf.drain();
    defer qbuf.free(evs);
    try std.testing.expectEqual(@as(usize, 3), evs.len);
    try std.testing.expect(evs[0].tool_rejected.denied);
    try std.testing.expectEqualStrings("tool-call budget spent", evs[0].tool_rejected.detail);
    try std.testing.expectEqualStrings("loaded 2 saved approval(s)", evs[1].notice);
    try std.testing.expectEqualStrings("sonnet", evs[2].model_changed);
}

test "a capped preview never ends mid-character" {
    // 80 bytes of ASCII then a 3-byte glyph straddling the cap.
    var buf: [128]u8 = undefined;
    @memset(buf[0..79], 'x');
    @memcpy(buf[79..86], "…tail");
    const long = buf[0..86];
    const cut = capLine(long, preview_cap);
    try std.testing.expectEqual(@as(usize, 79), cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    // A whole multi-byte character that FITS is kept, not shaved off.
    try std.testing.expectEqualStrings("a…", capLine("a…\nrest", preview_cap));
    try std.testing.expectEqualStrings("plain", capLine("  plain  \nmore", preview_cap));
}

test "the turn-sink binding is thread-local and released after the turn" {
    var qbuf: tui.EventQueue = .{};
    var sbuf: [8]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &sbuf };
    var bridge: Bridge = .{ .queue = &qbuf, .stream = &stream };
    try std.testing.expect(engine_sink.turnSink() == null);
    engine_sink.bindTurnSink(forBridge(&bridge));
    try std.testing.expect(engine_sink.turnSink() != null);

    // A pool thread building its own Agent must NOT inherit the frontend's
    // sink: a subagent's output is not the transcript.
    const Probe = struct {
        fn f(seen: *bool) void {
            seen.* = engine_sink.turnSink() != null;
        }
    };
    var seen = true;
    const th = try std.Thread.spawn(.{}, Probe.f, .{&seen});
    th.join();
    try std.testing.expect(!seen);

    engine_sink.unbindTurnSink();
    try std.testing.expect(engine_sink.turnSink() == null);
}
