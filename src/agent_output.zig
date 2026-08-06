//! Root-agent output plumbing, split off agent.zig (600-line cap, #422):
//! say() — human-facing lines routed by mode/thread, sayApiError() — the
//! remembered API-error notice, and emit() — the single structured JSONL
//! writer for --json mode. Member-aliased back onto Agent so call sites
//! (`self.say(...)`, `self.emit(...)`) resolve unchanged.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const protocol_seq = @import("protocol_seq.zig"); // #330: monotonic `seq` on every --json event
const tick_gate = @import("tick_gate.zig"); // #tui-tick: child ticks wait for a foreground line boundary

pub fn say(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
    // stdout is a strict JSONL transport in --json mode. Human-facing
    // notices are represented by their structured terminal/error events;
    // never leak an unframed line that breaks SDK parsers.
    if (main_mod.json_mode and !self.sub) return;
    if (self.out) |w| {
        try w.print(fmt, args);
        try w.flush();
        // The root just ended a row: anything a child offered mid-stream
        // may land now (#tui-tick).
        if (!self.sub and !main_mod.json_mode and comptime endsLine(fmt)) _ = tick_gate.setLineStart(true);
    } else {
        // A pool-thread child has no writer: its activity line goes to
        // stderr THROUGH the gate, so it lands at a line boundary the root
        // has published rather than mid-row (#tui-tick).
        var buf: [tick_gate.slot_bytes]u8 = undefined;
        var sink = Io.Writer.fixed(&buf);
        const fit = if (sink.print("  [{s}] " ++ fmt, .{self.label} ++ args)) |_| true else |_| false;
        var line = sink.buffered();
        // Over-long (an uncapped provider error) means the fixed sink cut
        // the text and ate the trailing newline. The gate cannot repair
        // that — the cut exactly fills a slot, so its own guard never fires
        // — and a line that does not end its row splices the next worker
        // line onto it mid-column, which is the reported artifact. End it.
        if (!fit or line.len == 0 or line[line.len - 1] != '\n') {
            // usize, not @min's narrowed comptime-derived type: at + 1 == buf.len.
            const at: usize = @min(line.len, buf.len - 1); // append, or overwrite the last byte
            buf[at] = '\n';
            line = buf[0 .. at + 1];
        }
        tick_gate.workerLine(line);
    }
}

/// Comptime: does this say() format end a terminal row?
fn endsLine(comptime fmt: []const u8) bool {
    return fmt.len > 0 and fmt[fmt.len - 1] == '\n';
}

/// say() for text that is already rendered (#422: a sink holds the bytes, not
/// a comptime format). Same routing, same worker-line framing, same tick-gate
/// rule — only the line-ending test moves from the format to the last byte.
/// Errors are swallowed: an event sink's emit path has nowhere to return them.
pub fn sayText(self: *Agent, text: []const u8) void {
    if (main_mod.json_mode and !self.sub) return;
    if (self.out) |w| {
        w.print("{s}", .{text}) catch return;
        w.flush() catch return;
        if (!self.sub and !main_mod.json_mode and text.len > 0 and text[text.len - 1] == '\n') _ = tick_gate.setLineStart(true);
        return;
    }
    // A pool-thread child has no writer: same fixed slot, same label prefix,
    // and the same repair when an over-long line lost its newline to the cut.
    var buf: [tick_gate.slot_bytes]u8 = undefined;
    var sink = Io.Writer.fixed(&buf);
    const fit = if (sink.print("  [{s}] {s}", .{ self.label, text })) |_| true else |_| false;
    var line = sink.buffered();
    if (!fit or line.len == 0 or line[line.len - 1] != '\n') {
        const at: usize = @min(line.len, buf.len - 1);
        buf[at] = '\n';
        line = buf[0 .. at + 1];
    }
    tick_gate.workerLine(line);
}

/// Remember the formatted message for the --json `error` event, then print
/// like say() + a #398 duration hint; last_api_error keeps provider words.
pub fn sayApiError(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
    self.last_api_error = std.fmt.allocPrint(self.arena, fmt, args) catch null;
    if (self.last_api_error) |m| if (@import("retry_hint.zig").humanizeRetrySeconds(m)) |h| return self.say("{s} (~{s})\n", .{ m, h.buf[0..h.len] });
    try self.say(fmt ++ "\n", args);
}

/// Emit one structured JSONL event to stdout (--json mode). `ev` is any
/// struct/anonymous struct; field names become JSON keys (a std.json.Value
/// field, e.g. tool input, serializes correctly). Best-effort.
///
/// #330: in --json mode the event is stamped with a monotonic `seq` so a
/// supervisor that loses the stream can say exactly where it stopped. The
/// counter is bumped inside the same lock that serializes stdout, which is
/// what makes the sequence gap-free rather than merely increasing.
pub fn emit(self: *Agent, ev: anytype) void {
    const w = self.out orelse return;
    // --json: the GUI stream is shared with pool-thread subagent emits
    // (guiEmit), so serialize + flush under the lock — a raw line must never
    // land mid-buffer and two writers must never interleave on stdout.
    if (main_mod.json_mode) main_mod.g_gui_mu.lockUncancelable(self.io);
    defer if (main_mod.json_mode) main_mod.g_gui_mu.unlock(self.io);
    if (main_mod.json_mode) {
        protocol_seq.writeEvent(w, ev) catch return;
    } else {
        var s: std.json.Stringify = .{ .writer = w };
        s.write(ev) catch return;
    }
    w.writeByte('\n') catch return;
    w.flush() catch return;
}
