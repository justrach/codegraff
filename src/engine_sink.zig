//! The EngineSink boundary (#422 slice 1): engine code emits typed events
//! (engine_events.zig) and a sink turns them into a frontend's output — it
//! receives events, nothing else. Two impls:
//!
//! - TuiSink: today's terminal rendering, verbatim. Its helpers live in
//!   frontend territory (agent_stream_render.zig, agent_render.zig via Agent
//!   aliases); slice 1 keeps the render state (thinking_*/md_* fields) on the
//!   Agent it wraps, so the ctx pointer is that state handle. Known slice-1
//!   debt against the strict-sink rule ("sinks render from events only"):
//!   besides that drawing bookkeeping, the reasoning gate still back-reads
//!   Agent policy (show_thinking/sub/stream_quiet — see tuiEmit). A later
//!   slice moves visibility into the event payload or makes it a sink-owned
//!   preference so a transport-split sink needs no reads into the Agent.
//! - JsonSink: the existing --json wire lines for these events,
//!   byte-identical to the old inline emits. The ONE translation point from
//!   internal type to wire shape: any change here is externally visible and
//!   gated behind a schema_version bump.
//!
//! Events are stamped with a {generation, sequence} Cursor at the dispatch
//! boundary. In --json mode (the only durable sink today), durable events
//! reserve their id INSIDE the same lock that serializes --json stdout,
//! keeping the wire's numbering gap-free and ordered against pool-thread
//! guiEmit writers. NOTE the lock condition is keyed to json_mode, not to
//! vt.durable: an injected durable sink outside --json reserves WITHOUT the
//! lock. When serve/attach (#420) adds one, key the lock to the sink (with a
//! test seam) or it inherits exactly the reorder race this lock prevents.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const engine_events = @import("engine_events.zig");
const EngineEvent = engine_events.EngineEvent;
const protocol_seq = @import("protocol_seq.zig");
const render = @import("agent_stream_render.zig");
const tick_gate = @import("tick_gate.zig"); // #tui-tick: child ticks wait for a foreground line boundary

/// An event plus its position, as delivered to a sink.
pub const Stamped = struct {
    cursor: engine_events.Cursor,
    event: EngineEvent,
};

pub const VTable = struct {
    emit: *const fn (ctx: *anyopaque, ev: Stamped) void,
    /// A durable sink persists/forwards the protocol stream: durable events
    /// reserve a fresh sequence id at dispatch. Presentation-only sinks
    /// observe the current position instead, so an interactive session never
    /// advances the persisted event_seq the --json wire owns.
    durable: bool,
};

pub const EngineSink = struct {
    ctx: *anyopaque,
    vt: *const VTable,

    /// The emission boundary: stamp, then hand off. `io` backs the stdout
    /// lock, taken only when a durable sink reserves AND json_mode is on —
    /// a global, so `io` may be passed undefined only where json_mode is
    /// known false (TUI dispatch; the tests here pin it). Durable emitters
    /// must not emit durable events a sink will drop (jsonEmit returns on
    /// out == null): the reserved id would burn with no wire line, opening
    /// a seq gap (#330). Today printDelta guarantees that by returning
    /// early when out == null, before any durable emission.
    pub fn emit(self: EngineSink, io: Io, ev: EngineEvent) void {
        const reserve = self.vt.durable and engine_events.durable(ev);
        if (reserve and main_mod.json_mode) {
            // Reserving outside the lock could put a smaller seq on the wire
            // AFTER a pool-thread guiEmit line took a larger one.
            main_mod.g_gui_mu.lockUncancelable(io);
            defer main_mod.g_gui_mu.unlock(io);
            self.vt.emit(self.ctx, .{ .cursor = engine_events.stamp(true), .event = ev });
            return;
        }
        self.vt.emit(self.ctx, .{ .cursor = engine_events.stamp(reserve), .event = ev });
    }
};

/// The agent's sink: an injected one (tests, future frontends) or the
/// process-mode default — the wire in --json mode, the terminal otherwise.
pub fn forAgent(a: *Agent) EngineSink {
    if (a.sink) |s| return s;
    return if (main_mod.json_mode) jsonSink(a) else tuiSink(a);
}

pub fn tuiSink(a: *Agent) EngineSink {
    return .{ .ctx = a, .vt = &tui_vtable };
}

pub fn jsonSink(a: *Agent) EngineSink {
    return .{ .ctx = a, .vt = &json_vtable };
}

const tui_vtable: VTable = .{ .emit = tuiEmit, .durable = false };
const json_vtable: VTable = .{ .emit = jsonEmit, .durable = true };

/// Today's interactive rendering, relocated behind the event contract. Every
/// branch is the old inline agent_stream.zig code path, gate for gate.
fn tuiEmit(ctx: *anyopaque, ev: Stamped) void {
    const a: *Agent = @ptrCast(@alignCast(ctx));
    switch (ev.event) {
        .stream_begin => render.spinnerStart(a),
        // Reasoning streams into the live dimmed "Thinking" block when
        // /thinking is on for a live, colored root turn; otherwise the
        // spinner stands in for it. TRANSITIONAL (slice-1 debt, see header):
        // this gate back-reads Agent policy to decide WHAT to render — a
        // wire-split sink cannot, so it must move into the event payload or
        // become a sink-owned preference before Phase 2.
        .reasoning_delta => |d| if (a.show_thinking and !a.sub and !a.stream_quiet and main_mod.use_color)
            render.streamThinking(a, d.text),
        .text_delta => |d| {
            if (a.thinking_open) render.closeThinkingBlock(a); // reasoning -> answer transition
            render.spinnerStop(a); // first visible byte: clear the thinking line
            if (main_mod.use_color) {
                a.streamMarkdown(d.text);
            } else if (a.out) |w| {
                w.writeAll(d.text) catch return;
                w.flush() catch return;
                if (!a.sub) _ = tick_gate.setLineStart(d.text[d.text.len - 1] == '\n'); // #tui-tick
            }
        },
        // Meta-tool argument prose renders like answer text — spinner handoff
        // included — with two deliberate differences from .text_delta, both
        // the old inline emitArgText behavior verbatim: the reasoning block
        // stays as-is (the model is still mid-call), and the no-color branch
        // never marks a tick-gate line start.
        .tool_arg_delta => |d| {
            render.spinnerStop(a); // first visible byte: clear the thinking line
            if (main_mod.use_color) {
                a.streamMarkdown(d.text);
            } else if (a.out) |w| {
                w.writeAll(d.text) catch return;
                w.flush() catch return;
            }
        },
        .thinking_fold_toggle => render.toggleThinkingFold(a),
        // Transport cuts carry no partial answer (nothing streamed on the ws
        // path), so unlike .stream_aborted there is no tail to flush — only
        // the notice, worded exactly as the old inline agent_ws lines were.
        .transport_aborted => |t| notice(a, switch (t.reason) {
            .interrupted => return, // deliberate stop: silent, as ever
            .stalled => if (t.turn_ending)
                "\n⚠ stream stalled — ending turn\n"
            else
                "\n⚠ stream stalled\n",
            .dropped => if (t.turn_ending)
                "\n⚠ connection dropped — response ended early\n"
            else
                "\n⚠ connection dropped\n",
        }),
        .stream_aborted => |reason| {
            a.flushStreamTail(); // render any held partial markdown line
            switch (reason) {
                .interrupted => {}, // a deliberate Esc needs no notice
                .stalled => notice(a, "\n⚠ stream stalled — ending turn\n"),
                .dropped => notice(a, "\n⚠ connection dropped — response ended early\n"),
            }
        },
        .stream_complete => |c| {
            a.flushStreamTail(); // render any held partial markdown line
            if (c.streamed_text) if (a.out) |w| {
                w.writeAll("\n") catch {};
                w.flush() catch {};
                _ = tick_gate.setLineStart(true); // answer is off the wire: release held child ticks (#tui-tick)
            };
        },
        .stream_finished => {
            render.closeThinkingBlock(a); // a reasoning-only turn still closes its block
            render.spinnerStop(a);
        },
    }
}

fn notice(a: *Agent, text: []const u8) void {
    const w = a.out orelse return;
    w.writeAll(text) catch return;
    w.flush() catch {};
}

/// The existing --json wire. Only the durable events have a shape; giving a
/// pulse one is an externally visible change (schema_version gate). Dispatch
/// already holds the stdout lock for these writes in --json mode.
fn jsonEmit(ctx: *anyopaque, ev: Stamped) void {
    const a: *Agent = @ptrCast(@alignCast(ctx));
    const w = a.out orelse return;
    switch (ev.event) {
        .reasoning_delta => |d| jsonLine(w, ev.cursor, .{ .type = "reasoning", .text = d.text }),
        .text_delta => |d| jsonLine(w, ev.cursor, .{ .type = "text", .text = d.text }),
        // Stream end/abort still flushes the held render tail, as the old
        // inline path did in EVERY mode. (Slice 1b correction to this note:
        // tool-arg prose CANNOT dirty md state here — argLiveDelta has always
        // gated --json off, and this sink drops .tool_arg_delta — so with
        // .text_delta going to the wire the tail is clean and the flush adds
        // no bytes today. It stays because removing a wire-visible behavior,
        // however latent, is a deliberate schema-gated change, not refactor
        // fallout.)
        .stream_aborted, .stream_complete => a.flushStreamTail(),
        else => {},
    }
}

fn jsonLine(w: *Io.Writer, cursor: engine_events.Cursor, payload: anytype) void {
    protocol_seq.writeEventStamped(w, cursor.sequence, payload) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

test "dispatch preserves emission order and stamps at the boundary" {
    // emit(undefined, ...) is sound only while json_mode is false (no lock
    // taken): pin it so a leaky earlier test can never turn this into UB.
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var rec: std.ArrayList(Stamped) = .empty;
    defer rec.deinit(std.testing.allocator);
    const vt: VTable = .{ .emit = recordEmit, .durable = true };
    const s: EngineSink = .{ .ctx = &rec, .vt = &vt };
    s.emit(undefined, .stream_begin);
    s.emit(undefined, .{ .reasoning_delta = .{ .text = "think" } });
    s.emit(undefined, .{ .text_delta = .{ .text = "hi" } });
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = true } });
    s.emit(undefined, .stream_finished);
    try std.testing.expectEqual(@as(usize, 5), rec.items.len);
    const want_tags: [5]std.meta.Tag(EngineEvent) = .{
        .stream_begin, .reasoning_delta, .text_delta, .stream_complete, .stream_finished,
    };
    for (want_tags, rec.items) |tag, got| try std.testing.expectEqual(tag, std.meta.activeTag(got.event));
    // Durable deltas reserved fresh ids; pulses ride at the last reserved
    // position — the wire's numbering shows no gap for them.
    const want_seq: [5]u64 = .{ 0, 1, 2, 2, 2 };
    for (want_seq, rec.items) |seq, got| try std.testing.expectEqual(seq, got.cursor.sequence);
    for (rec.items) |got| try std.testing.expectEqual(engine_events.generation(), got.cursor.generation);
}

test "a presentation sink never reserves sequence ids" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var rec: std.ArrayList(Stamped) = .empty;
    defer rec.deinit(std.testing.allocator);
    const vt: VTable = .{ .emit = recordEmit, .durable = false };
    const s: EngineSink = .{ .ctx = &rec, .vt = &vt };
    s.emit(undefined, .{ .text_delta = .{ .text = "hi" } });
    try std.testing.expectEqual(@as(u64, 0), rec.items[0].cursor.sequence);
    try std.testing.expectEqual(@as(u64, 0), protocol_seq.current());
}

fn recordEmit(ctx: *anyopaque, ev: Stamped) void {
    const rec: *std.ArrayList(Stamped) = @ptrCast(@alignCast(ctx));
    rec.append(std.testing.allocator, ev) catch @panic("OOM");
}

test "JsonSink writes today's wire lines byte-for-byte" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
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
    const s = jsonSink(&a);
    s.emit(undefined, .{ .reasoning_delta = .{ .text = "why" } });
    s.emit(undefined, .{ .text_delta = .{ .text = "hi\n" } });
    s.emit(undefined, .stream_begin); // pulses have no wire shape
    // End-of-stream flushes the held render tail (old-path parity); with
    // clean md state that adds no bytes and emits no wire line.
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = true } });
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"type\":\"reasoning\",\"text\":\"why\"}\n{\"seq\":2,\"type\":\"text\",\"text\":\"hi\\n\"}\n",
        aw.writer.buffered(),
    );
}

test "TuiSink streams tool-arg prose raw and never ends the answer line (slice 1b)" {
    const saved_color = main_mod.use_color; // pin the no-color branch
    main_mod.use_color = false;
    defer main_mod.use_color = saved_color;
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
    const s = tuiSink(&a);
    s.emit(undefined, .{ .tool_arg_delta = .{ .text = "answer " } });
    s.emit(undefined, .{ .tool_arg_delta = .{ .text = "prose" } });
    // Exactly the bytes, flushed per delta, no separators added — the old
    // inline emitArgText no-color branch.
    try std.testing.expectEqualStrings("answer prose", aw.writer.buffered());
}

test "TuiSink transport-abort notices reproduce the old inline lines (slice 1b)" {
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
    const s = tuiSink(&a);
    const cases = [_]struct { ev: engine_events.TransportAbort, want: []const u8 }{
        .{ .ev = .{ .reason = .stalled, .turn_ending = false }, .want = "\n⚠ stream stalled\n" },
        .{ .ev = .{ .reason = .stalled, .turn_ending = true }, .want = "\n⚠ stream stalled — ending turn\n" },
        .{ .ev = .{ .reason = .dropped, .turn_ending = false }, .want = "\n⚠ connection dropped\n" },
        .{ .ev = .{ .reason = .dropped, .turn_ending = true }, .want = "\n⚠ connection dropped — response ended early\n" },
        // A deliberate interrupt was never announced at the transport layer.
        .{ .ev = .{ .reason = .interrupted, .turn_ending = true }, .want = "" },
    };
    for (cases) |c| {
        aw.clearRetainingCapacity();
        s.emit(undefined, .{ .transport_aborted = c.ev });
        try std.testing.expectEqualStrings(c.want, aw.writer.buffered());
    }
}

test "JsonSink stays silent for moments the wire never carried (slice 1b)" {
    const saved_json = main_mod.json_mode; // pin: see the dispatch-order test
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
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
    const s = jsonSink(&a);
    s.emit(undefined, .{ .tool_arg_delta = .{ .text = "prose" } });
    s.emit(undefined, .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = true } });
    s.emit(undefined, .{ .transport_aborted = .{ .reason = .dropped, .turn_ending = false } });
    // No wire line AND no sequence id burned: both stay pulses, so the
    // wire's gap-free numbering is untouched by them (#330).
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    try std.testing.expectEqual(@as(u64, 0), protocol_seq.current());
}

test "TuiSink renders a plain text delta exactly as the no-color TTY did" {
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
    const s = tuiSink(&a);
    s.emit(undefined, .{ .text_delta = .{ .text = "plain\n" } });
    try std.testing.expectEqualStrings("plain\n", aw.writer.buffered());
    // Normal end after streamed text: the separating newline, as before.
    s.emit(undefined, .{ .stream_complete = .{ .streamed_text = true } });
    try std.testing.expectEqualStrings("plain\n\n", aw.writer.buffered());
}
