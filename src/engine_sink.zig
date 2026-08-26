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
//!   gated behind a schema_version bump. Not yet the ONLY producer of those
//!   shapes, though: subagent_run.zig's guiEmit writes `tool_call`/
//!   `tool_result` rows with an extra `id` (schema_protocol.zig) straight to
//!   stdout, bypassing this sink. Routing them through it needs an optional
//!   `id` on ToolInvocation/ToolOutcome — decide that when #429 takes the
//!   subagent cluster, while these structs are still cheap to change.
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
const obs = @import("obs.zig");
const protocol_seq = @import("protocol_seq.zig");
const render = @import("agent_stream_render.zig");
const tool_render = @import("agent_tool_render.zig"); // slice 1c: the tool cluster's terminal half
const session_render = @import("session_render.zig"); // slice 2: the lifecycle cluster's terminal half
const prompt_render = @import("agent_prompt_render.zig"); // batch 3: the status line's terminal half
const working = @import("agent_working.zig");
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
    /// known false (TUI dispatch; the tests here pin it). A durable sink must
    /// never be handed an event it will drop: the reserved id would burn with
    /// no wire line, opening a seq gap (#330). jsonSink enforces that at
    /// construction — an agent with no writer gets a non-durable vtable — so
    /// emitters need no `out == null` guard of their own.
    pub fn emit(self: EngineSink, io: Io, ev: EngineEvent) void {
        obs.note(ev);
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

/// The --json wire, for an agent that HAS one. A frontendless agent — a
/// pool-thread subagent (subagent_run.zig builds every child with
/// `.out = null`) or the ACP root between prompts (acp.zig nulls `out`
/// except during session/prompt, when a translating sink is installed) —
/// gets the same emitter but a NON-durable vtable: jsonEmit drops every line
/// for it, and a durable sink would have reserved a sequence id for each of
/// those dropped lines, opening exactly the gap #330 promises cannot exist.
/// Structural, so no emitter has to re-derive the rule per call site.
pub fn jsonSink(a: *Agent) EngineSink {
    return .{ .ctx = a, .vt = if (a.out == null) &json_dropped_vtable else &json_vtable };
}

/// The session lifecycle's terminal sink (slice 2). Its ctx is the WRITER, not
/// an Agent: startup's banner and config reports happen before an Agent exists
/// and shutdown's after it stops mattering, so `forAgent` has nothing to hand
/// them. Nothing this cluster draws needs render state, which is why a plain
/// writer suffices here and does not for the stream.
///
/// A null writer is a run with no frontend (a one-shot, whose stdout carries
/// only the answer; `graff acp`, whose stdout is someone else's protocol) —
/// legitimate, not an error: session_render stays silent for it, except the
/// failover notice, which falls back to stderr as it always did. The sentinel
/// exists only because `ctx` cannot be null.
pub fn writerSink(w: ?*Io.Writer) EngineSink {
    return .{ .ctx = if (w) |x| @ptrCast(x) else @ptrCast(&no_frontend), .vt = &lifecycle_vtable };
}

/// The lifecycle's sink for a moment an Agent DOES own — the mid-turn provider
/// failover, whose --json half is the wire's `model` event but whose terminal
/// half belongs to the caller's writer (mainloop's stdout, the REPL's own
/// sink), not to `a.out`. Same choice as forAgent, different terminal target.
pub fn forSession(a: *Agent, w: ?*Io.Writer) EngineSink {
    if (a.sink) |s| return s;
    return if (main_mod.json_mode) jsonSink(a) else writerSink(w);
}

var no_frontend: u8 align(@alignOf(Io.Writer)) = 0;

/// Startup probed stdout and found a color-capable terminal. A capability, not
/// an event: it settles what the terminal half's palette IS before anything is
/// drawn, so it crosses the boundary as a call rather than an emission.
pub fn enableColor() void {
    session_render.enableColor();
}

/// Set by a fullscreen frontend (TUI/) so TuiSink never draws on stdout —
/// that would fight the alt-screen. Text goes to `a.out` (the pane buffer).
///
/// This only ever gated hostedEmit, which renders the tool cluster back into
/// "⚙ /✓ " TEXT for a frontend to parse out again and silently drops every
/// other event. It survives as the fallback for a hosted agent that has NO
/// sink of its own — a subagent, a one-shot — while a frontend that installs
/// one (see `bindTurnSink`) never goes through it (#551).
pub var hosted_frontend: bool = false;

/// The sink a frontend wants the next Agent built on THIS thread to use.
///
/// The turn constructors (repl_glue.replTurnCb) are shared by every frontend
/// and know nothing about any of them, so the frontend leaves its sink here
/// before handing the turn over and takes it back after. Thread-local because
/// one turn thread runs one turn: a background subagent pool thread building
/// its own Agent finds nothing here and keeps the process-mode default, which
/// is exactly right — a child's output is not the frontend's transcript.
threadlocal var g_turn_sink: ?EngineSink = null;
/// Process-wide copy of the bound frontend sink so a root tool running on the
/// Io pool (every `execTool` is `io.async`) can still emit live progress.
/// Subagent construction still uses the thread-local `turnSink` and sees null.
var g_hosted_sink: ?EngineSink = null;

pub fn bindTurnSink(s: EngineSink) void {
    g_turn_sink = s;
    g_hosted_sink = s;
}

pub fn unbindTurnSink() void {
    g_hosted_sink = null;
    g_turn_sink = null;
}

/// The bound sink, or null when no frontend claimed this turn.
pub fn turnSink() ?EngineSink {
    return g_turn_sink;
}

/// The TUI/hosted sink, visible to pool threads for the duration of the turn.
pub fn hostedSink() ?EngineSink {
    return g_hosted_sink;
}

const tui_vtable: VTable = .{ .emit = tuiEmit, .durable = false };
const json_vtable: VTable = .{ .emit = jsonEmit, .durable = true };
/// Same writer, nothing to write to: see jsonSink.
const json_dropped_vtable: VTable = .{ .emit = jsonEmit, .durable = false };
/// Presentation-only, like the TUI's: the wire lines this cluster owns go out
/// through jsonSink instead, so this one must never reserve a sequence id.
const lifecycle_vtable: VTable = .{ .emit = lifecycleEmit, .durable = false };

fn lifecycleEmit(ctx: *anyopaque, ev: Stamped) void {
    const w: ?*Io.Writer = if (ctx == @as(*anyopaque, @ptrCast(&no_frontend)))
        null
    else
        @ptrCast(@alignCast(ctx));
    session_render.emit(w, ev.event);
}

/// Today's interactive rendering, relocated behind the event contract. Every
/// branch is the old inline agent_stream.zig code path, gate for gate.
fn tuiEmit(ctx: *anyopaque, ev: Stamped) void {
    const a: *Agent = @ptrCast(@alignCast(ctx));
    if (hosted_frontend) return hostedEmit(a, ev.event);
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
        // grok-build RawTerminal/Append: live bash bytes, not markdown.
        // Line REPL keeps them off the transcript unless /debug (ADR 0020).
        .tool_output_delta => |d| tool_render.liveOutput(a, d.text),
        .job_completed => |j| {
            var buf: [80]u8 = undefined;
            const msg = if (j.killed)
                std.fmt.bufPrint(&buf, "\n[job {d} killed]\n", .{j.id})
            else if (j.exit_code) |c|
                std.fmt.bufPrint(&buf, "\n[job {d} exited {d}]\n", .{ j.id, c })
            else
                std.fmt.bufPrint(&buf, "\n[job {d} ended]\n", .{j.id});
            notice(a, msg catch return);
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
        // The tool cluster (slice 1c). Its drawing lives in agent_tool_render,
        // the one file down here that still reaches the palette; the moments
        // the terminal never drew (the dispatch/close brackets, refusals) are
        // silent rather than absent from the vocabulary.
        .tool_call_announced => |t| tool_render.toolUseLine(a, t),
        .tool_result => |r| tool_render.toolResultLine(a, r),
        .tool_call_started, .tool_call_finished, .tool_rejected => {},
        .parallel_batch_started => |b| tool_render.parallelBatchStarted(a, b.count),
        .parallel_batch_finished => |b| tool_render.parallelBatchFinished(a, b),
        .completion_deferred => tool_render.completionDeferred(a),
        .goal_completed => tool_render.goalCompleted(a),
        .completion_text => |t| tool_render.toolTextLine(a, t.text),
        .todo_list_updated => |t| {
            const w = a.out orelse return;
            const title = if (a.goal) |g|
                (if (g.status != .complete and g.objective.len > 0) g.objective else "work")
            else
                "work";
            working.writeFromTodoText(w, title, t.text);
            w.flush() catch {};
        },
        // The lifecycle cluster (slice 2). An Agent-backed TUI sink reaches
        // these only when one is injected (tests, a future frontend): the
        // engine's own lifecycle emitters use writerSink, whose terminal
        // target is the caller's writer rather than a.out.
        .session_notice,
        .session_banner,
        .worktree_entered,
        .shared_worktree_owner,
        .saved_model_unavailable,
        .mcp_consent_prompt,
        .provider_fallback,
        .session_saved,
        .run_finished,
        => session_render.emit(a.out, ev.event),
        // The status line before a human turn (#429). Its drawing — palette,
        // badge frame, and the #209 width budget that decides which segments
        // survive a narrow pane — lives in agent_prompt_render.
        .prompt_ready => |st| {
            tool_render.resetInfra();
            if (a.out) |w| prompt_render.promptLine(w, st);
        },
    }
}

fn notice(a: *Agent, text: []const u8) void {
    const w = a.out orelse return;
    w.writeAll(text) catch return;
    w.flush() catch {};
}

/// The fallback for a HOSTED agent with no sink of its own — a subagent, a
/// one-shot under a fullscreen frontend. It renders the tool cluster back into
/// "⚙ /✓ " text and drops everything else, which is why a real frontend must
/// install a sink instead of reading these bytes back (#551). Nothing new goes
/// in here: a new event gets a surface on a real sink, not a glyph line.
fn hostedEmit(a: *Agent, ev: EngineEvent) void {
    const w = a.out orelse return;
    switch (ev) {
        .text_delta, .tool_arg_delta => |d| {
            w.writeAll(d.text) catch {};
            w.flush() catch {};
        },
        .tool_output_delta => |d| {
            w.writeAll(d.text) catch {};
            w.flush() catch {};
        },
        .job_completed => |j| {
            if (j.killed) w.print("[job {d} killed]\n", .{j.id}) catch {} else if (j.exit_code) |c| w.print("[job {d} exited {d}]\n", .{ j.id, c }) catch {} else w.print("[job {d} ended]\n", .{j.id}) catch {};
            w.flush() catch {};
        },
        .completion_text, .todo_list_updated => |t| {
            w.writeAll(t.text) catch {};
            w.writeAll("\n") catch {};
            w.flush() catch {};
        },
        .tool_call_announced => |t| {
            const arg = compactArg(t.input);
            if (arg.len > 0)
                w.print("⚙ {s} {s}\n", .{ shortTool(t.name), arg }) catch {}
            else
                w.print("⚙ {s}\n", .{shortTool(t.name)}) catch {};
            w.flush() catch {};
        },
        .tool_result => |r| {
            const mark: []const u8 = if (r.is_error) "✗" else "✓";
            const preview = firstLineCap(r.text, 80);
            if (preview.len > 0)
                w.print("{s} {s} | {s}\n", .{ mark, shortTool(r.name), preview }) catch {}
            else
                w.print("{s} {s}\n", .{ mark, shortTool(r.name) }) catch {};
            w.flush() catch {};
        },
        else => {},
    }
}

/// The existing --json wire. Only the durable events have a shape; giving a
/// pulse one is an externally visible change (schema_version gate). Dispatch
/// already holds the stdout lock for these writes in --json mode.
fn jsonEmit(ctx: *anyopaque, ev: Stamped) void {
    const a: *Agent = @ptrCast(@alignCast(ctx));
    const w = a.out orelse return;
    // The invariant that keeps #330's numbering gap-free: this sink writes a
    // line for EXACTLY the events engine_events.durable() claims, so a
    // reserved id can never end up with nothing behind it. Payload-dependent
    // durability (ask_user's bracket, a meta tool's result) is decided there,
    // once, rather than re-derived per branch below.
    //
    // Stream end/abort still flushes the held render tail, as the old inline
    // path did in EVERY mode. (Slice 1b correction to this note: tool-arg
    // prose CANNOT dirty md state here — argLiveDelta has always gated --json
    // off, and this sink drops .tool_arg_delta — so with .text_delta going to
    // the wire the tail is clean and the flush adds no bytes today. It stays
    // because removing a wire-visible behavior, however latent, is a
    // deliberate schema-gated change, not refactor fallout.)
    if (!engine_events.durable(ev.event)) return switch (ev.event) {
        .stream_aborted, .stream_complete => a.flushStreamTail(),
        .tool_output_delta => |d| jsonLine(w, ev.cursor, .{
            .type = "bash_output_chunk",
            .name = d.name,
            .stream = if (d.stderr) "stderr" else "stdout",
            .text = d.text,
        }),
        .job_completed => |j| jsonLine(w, ev.cursor, .{
            .type = "job_completed",
            .id = j.id,
            .exit_code = j.exit_code,
            .killed = j.killed,
        }),
        else => {},
    };
    switch (ev.event) {
        .reasoning_delta => |d| jsonLine(w, ev.cursor, .{ .type = "reasoning", .text = d.text }),
        .text_delta => |d| jsonLine(w, ev.cursor, .{ .type = "text", .text = d.text }),
        .tool_call_announced => |t| jsonLine(w, ev.cursor, .{ .type = "tool_call", .name = t.name, .input = t.input }),
        .tool_call_started => |t| jsonLine(w, ev.cursor, .{ .type = "tool_call_started", .name = t.name, .input = t.input }),
        .tool_result => |r| jsonLine(w, ev.cursor, .{ .type = "tool_result", .name = r.name, .is_error = r.is_error, .text = r.text }),
        .tool_call_finished => |r| jsonLine(w, ev.cursor, .{ .type = "tool_call_finished", .name = r.name, .is_error = r.is_error, .ms = r.ms }),
        .tool_rejected => |r| jsonLine(w, ev.cursor, .{ .type = "tool_rejected", .name = r.name, .reason = r.reason, .input = r.input, .message = r.message }),
        // The failover's wire half (slice 2). Its `note` is a FIXED wire
        // string, not the payload's context_note: a --json client is being
        // told the saved preference survived, while the terminal is told what
        // happened to the conversation. Two audiences, one event, and the
        // difference lives here because this is the one translation point.
        .provider_fallback => |f| jsonLine(w, ev.cursor, .{
            .type = "model",
            .ok = true,
            .provider = f.to_provider,
            .model = f.to_model,
            .context = f.to_context,
            .note = "automatic session fallback; saved model preference kept",
        }),
        // Unreachable: durable() gated every other tag out above. Kept as a
        // hard stop so a NEW durable variant cannot silently reach the wire
        // without a shape — that would burn its id on nothing (#330).
        else => @panic("engine_sink: durable event with no wire shape"),
    }
}

fn jsonLine(w: *Io.Writer, cursor: engine_events.Cursor, payload: anytype) void {
    protocol_seq.writeEventStamped(w, cursor.sequence, payload) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

pub fn shortTool(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read_file")) return "read";
    if (std.mem.eql(u8, name, "write_file")) return "write";
    return name;
}

/// The one argument worth showing beside a tool name — the path it touches,
/// the command it runs, the query it asks. Shared with the TUI's typed sink
/// (tui_sink.zig) so both frontends pick the same field.
pub fn compactArg(input: std.json.Value) []const u8 {
    const obj = switch (input) {
        .object => |o| o,
        else => return "",
    };
    const keys = [_][]const u8{ "path", "target_file", "file", "filename", "command", "cmd", "query", "q", "pattern", "url", "symbol" };
    for (keys) |k| {
        const v = obj.get(k) orelse continue;
        if (v == .string and v.string.len > 0) return v.string;
    }
    return "";
}

pub fn firstLineCap(text: []const u8, cap: usize) []const u8 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| s = std.mem.trim(u8, s[0..i], " \t\r");
    if (s.len > cap) return s[0..cap];
    return s;
}

test {
    _ = @import("engine_sink_tests.zig");
}
