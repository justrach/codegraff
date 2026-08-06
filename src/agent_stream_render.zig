//! TUI-side live-stream rendering (#422): the thinking spinner
//! (spinnerTask/Start/Stop, an animated indicator while the model is silent)
//! and the live dimmed "Thinking" reasoning block (streamThinking/
//! closeThinkingBlock/toggleThinkingFold), moved verbatim out of
//! agent_stream.zig so the transport loop owns no terminal drawing. Driven by
//! TuiSink (engine_sink.zig) only, as of slice 1b — agent_ws.zig emits events
//! now instead of reaching the spinner aliases. Frontend territory:
//! term.zig/ansi.zig/anim.zig imports live here, never in engine files.
//!
//! Agent.g_spin_stop/Agent.g_spin_future are struct-level `pub var`s that stay
//! declared directly inside the Agent struct (never alias a `var`) — reached
//! here as `Agent.g_spin_stop`/`Agent.g_spin_future`.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const style = &@import("ansi.zig").style;

const anim = @import("anim.zig");
const tick_gate = @import("tick_gate.zig"); // #tui-tick: child ticks wait for a foreground line boundary

const terminal = @import("term.zig");
const termCols = terminal.termCols;
const termRows = terminal.termRows;
const advanceThinkingRows = terminal.advanceThinkingRows;

pub fn spinnerTask(io: Io) void {
    var i: usize = 0;
    var buf: [512]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    while (!Agent.g_spin_stop.load(.acquire)) {
        if (main_mod.g_steer_visible.load(.acquire)) {
            io.sleep(.fromMilliseconds(20), .awake) catch break;
            continue;
        }
        // Clear-then-draw each frame: animations may vary in width.
        w.interface.writeAll("\r\x1b[2K\x1b[?7l") catch return; // ?7l: autowrap off so a wide spinner truncates instead of wrapping in a narrow window (the "goes on and on" bug)
        anim.anims[anim.g_anim_current].frame(&w.interface, i) catch return;
        w.interface.writeAll("\x1b[?7h") catch return; // restore autowrap
        w.interface.flush() catch return;
        i += 1;
        const frame_ticks = @max(@as(usize, 1), @as(usize, anim.anims[anim.g_anim_current].frame_ms) / 20);
        var t: usize = 0;
        while (t < frame_ticks and !Agent.g_spin_stop.load(.acquire)) : (t += 1) {
            if (main_mod.g_steer_visible.load(.acquire)) break;
            io.sleep(.fromMilliseconds(20), .awake) catch break;
        }
    }
    if (!main_mod.g_steer_visible.load(.acquire)) {
        w.interface.writeAll("\x1b[?7h\r\x1b[2K") catch return; // restore autowrap + clear
        w.interface.flush() catch {};
    }
}

pub fn spinnerStart(self: *Agent) void {
    if (self.sub or main_mod.json_mode or !main_mod.use_color or self.out == null) return;
    if (anim.g_anim_off) return;
    if (Agent.g_spin_future != null) return;
    anim.selectSpinner(self.io);
    Agent.g_spin_stop.store(false, .release);
    Agent.g_spin_future = self.io.concurrent(spinnerTask, .{self.io}) catch blk: {
        Agent.g_spin_stop.store(true, .release); // no spare concurrency: skip quietly
        break :blk null;
    };
}

pub fn spinnerStop(self: *Agent) void {
    if (self.sub) return; // root-only state — subs run on pool threads
    if (Agent.g_spin_future) |*f| {
        Agent.g_spin_stop.store(true, .release);
        f.await(self.io);
        Agent.g_spin_future = null;
    }
}

/// Stream a chunk of the model's reasoning into a live, dimmed "Thinking"
/// block in the terminal, opening the block (and handing the line off from
/// the spinner) on the first chunk. Gated by /thinking; when off the block is
/// never opened and the spinner stands in for it. We track the block's
/// on-screen height as it streams so closeThinkingBlock can collapse it to a
/// one-line summary when the answer starts (#75).
pub fn streamThinking(self: *Agent, chunk: []const u8) void {
    const w = self.out orelse return;
    if (!self.thinking_open) {
        self.spinnerStop();
        w.print("{s}▼ Thinking{s}\n{s}", .{ style.dim, style.reset, style.dim }) catch return;
        self.thinking_open = true;
        main_mod.g_thinking_open = true;
        self.thinking_rows = 1; // the header newline already moved us down one line
        self.thinking_col = 0;
        self.thinking_overflow = false;
        // The block owns every row below this one and collapses them by cursor
        // math — a child's tick printed inside it would be erased with the
        // block (or shift the erase onto real output). Hold until it closes.
        tick_gate.hold();
    }
    self.thinking_text.appendSlice(self.gpa, chunk) catch {};
    if (self.thinking_folded) return; // folded: buffer only, don't draw the live block
    w.writeAll(chunk) catch return;
    w.flush() catch return;
    advanceThinkingRows(&self.thinking_rows, &self.thinking_col, termCols(), chunk);
    if (self.thinking_rows + 1 >= termRows()) self.thinking_overflow = true;
}

/// Close an open "Thinking" block. If it still fits on screen, collapse it in
/// place to a one-line "Thought" summary (#75); if it has scrolled off
/// (overflow) leave the reasoning and just append the summary, so we never
/// erase the user's earlier output. Runs on the reasoning->answer transition
/// and at stream end.
pub fn closeThinkingBlock(self: *Agent) void {
    if (!self.thinking_open) return;
    self.thinking_open = false;
    main_mod.g_thinking_open = false;
    self.thinking_folded = false;
    const w = self.out orelse return;
    if (!self.thinking_overflow and self.thinking_rows >= 1 and main_mod.use_color) {
        w.print("\x1b[{d}F\x1b[0J{s}✓ Thought{s}\n\n", .{ self.thinking_rows, style.dim, style.reset }) catch return;
    } else {
        w.print("{s}\n{s}✓ Thought{s}\n\n", .{ style.reset, style.dim, style.reset }) catch return;
    }
    w.flush() catch return;
    _ = tick_gate.setLineStart(true); // both branches end at column 0 — held ticks land here (#tui-tick)
}

/// Ctrl-T: fold/unfold the live "Thinking" block in place (#92/#85). Only
/// acts on an open, on-screen block; folding erases it to a one-line marker,
/// unfolding re-streams the buffered reasoning. Cursor math mirrors
/// closeThinkingBlock (erase `thinking_rows` lines up, clear to end).
pub fn toggleThinkingFold(self: *Agent) void {
    if (!self.thinking_open or self.thinking_overflow or !main_mod.use_color) return;
    const w = self.out orelse return;
    if (!self.thinking_folded) {
        w.print("\x1b[{d}F\x1b[0J{s}▶ Thinking (folded · ^T){s}\n", .{ self.thinking_rows, style.dim, style.reset }) catch return;
        self.thinking_folded = true;
        self.thinking_rows = 1;
        self.thinking_col = 0;
    } else {
        w.print("\x1b[1F\x1b[0J{s}▼ Thinking{s}\n{s}", .{ style.dim, style.reset, style.dim }) catch return;
        self.thinking_folded = false;
        self.thinking_rows = 1;
        self.thinking_col = 0;
        w.writeAll(self.thinking_text.items) catch return;
        advanceThinkingRows(&self.thinking_rows, &self.thinking_col, termCols(), self.thinking_text.items);
    }
    w.flush() catch return;
}
