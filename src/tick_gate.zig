//! Line-boundary gate for parallel-subagent activity output (#tui-tick).
//!
//! Parallel children run on pool threads with no stdout of their own and log
//! through std.debug.print, which locks stderr — so every worker line is atomic
//! on its own. The ROOT agent streams its answer to stdout a token at a time,
//! and nothing tied the two together: a tick arriving between two deltas landed
//! wherever the cursor happened to be, which in a real fleet run was inside a
//! half-written word —
//!
//!     guard `if (buf.len - [Review Python hot path] ⚙ bash {…} pos < 2…`
//!
//! This module is the missing rendezvous. The foreground stream publishes
//! whether it is mid-line after every flushed delta (setLineStart / hold); a
//! worker line offered while it is mid-line is HELD and printed the moment that
//! line completes. Bounded by construction: `max_pending` slots of `slot_bytes`
//! each, drop-oldest plus a count marker when a flood outruns the stream, and
//! no allocation anywhere on the path.
//!
//! The guarantee, precisely: no worker line is emitted while the foreground's
//! last PUBLISHED position is mid-row, and every held line and every cut line
//! ends in a newline, so released ticks each own whole rows. That is flush
//! granularity, not word granularity — the position is published only after a
//! flush, so a tick offered in the window between the foreground writing bytes
//! and publishing the new position still lands wherever the cursor is. Deltas
//! publish per flushed chunk, so that window is one delta wide; the reported
//! artifact was a tick landing between deltas, and that is what this closes.
//!
//! TUI only. In --json mode stdout is a strict JSONL transport that children
//! never share (they emit structured events), so workerLine keeps the old
//! direct stderr write and the gate stays out of the way.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("main.zig"); // live json_mode toggle

/// #444. A test binary has no terminal for a worker line to reach, and stderr
/// there is not free: zig's build runner routes a Run step through its ERROR
/// printer whenever `result_stderr` is non-empty — even on a green exit 0 — so
/// a passing suite that says anything renders a step-failure tree and a red
/// `failed command: …/test --listen=-`. That output read as a failure for
/// months (the line people latched onto was an unrelated negative control's
/// expected diagnostic, which merely sat in the same stderr buffer).
///
/// So: the gate's accounting still runs under test — offers are held, drops are
/// counted, released lines are still counted — only the physical write is
/// elided, and elided at comptime, so no test build can reach a stderr write
/// through this module.
const emit_to_stderr = !builtin.is_test;

fn writeLine(text: []const u8) void {
    if (!emit_to_stderr) return;
    std.debug.print("{s}", .{text});
}

/// Held lines. Small on purpose: a fleet that outruns the stream should show
/// its newest activity, not replay a backlog once the line finally ends.
pub const max_pending = 6;
/// Per-slot capacity. A launch/done card (box rules + rows + SGR) is the widest
/// realistic tick at well under 1 KiB; longer text is cut, never spilled.
pub const slot_bytes = 2048;

/// The pure line-boundary rule — no I/O, no globals, so the interleave the bug
/// report describes can be unit-tested directly.
pub const Gate = struct {
    /// True when the foreground stream has painted part of a row that has not
    /// ended yet. Nothing may be injected in that state.
    mid_line: bool = false,
    slots: [max_pending][slot_bytes]u8 = undefined,
    lens: [max_pending]u16 = @splat(0),
    head: usize = 0, // oldest held slot
    count: usize = 0,
    dropped: u32 = 0,

    /// The foreground just wrote `bytes` (already flushed): it is mid-line
    /// unless that write ended one. An empty write says nothing.
    pub fn noteForeground(self: *Gate, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.mid_line = bytes[bytes.len - 1] != '\n';
    }

    /// Offer one worker line (newline-terminated). Returns true when the gate
    /// took it — the caller must NOT print. False means the foreground is at a
    /// line boundary and the caller prints immediately, exactly as before.
    pub fn offer(self: *Gate, text: []const u8) bool {
        if (!self.mid_line or text.len == 0) return false;
        if (self.count == max_pending) { // flooded: drop the oldest, count it
            self.head = (self.head + 1) % max_pending;
            self.count -= 1;
            self.dropped +|= 1;
        }
        const i = (self.head + self.count) % max_pending;
        const n = @min(text.len, slot_bytes);
        @memcpy(self.slots[i][0..n], text[0..n]);
        // A cut line still has to end its row, or the release after it starts
        // mid-column and reintroduces the very bug this gate exists to stop.
        if (n < text.len and self.slots[i][n - 1] != '\n') self.slots[i][n - 1] = '\n';
        self.lens[i] = @intCast(n);
        self.count += 1;
        return true;
    }

    /// Copy the oldest held line into `buf` (must be >= slot_bytes) and drop
    /// it, so the caller can print without holding the lock. Null when empty.
    pub fn take(self: *Gate, buf: []u8) ?usize {
        if (self.count == 0) return null;
        const n = self.lens[self.head];
        @memcpy(buf[0..n], self.slots[self.head][0..n]);
        self.head = (self.head + 1) % max_pending;
        self.count -= 1;
        return n;
    }

    /// Lines discarded since the last report; reading clears the counter.
    pub fn takeDropped(self: *Gate) u32 {
        defer self.dropped = 0;
        return self.dropped;
    }
};

/// The process-wide gate. pub only so agent_tests.zig can drive the real
/// workerLine path and inspect what a worker actually handed over.
pub var g_gate: Gate = .{};
var g_lock: std.atomic.Value(bool) = .init(false);

/// Spin-lock, same shape (and reasoning) as repl_glue.steerLock: pool threads
/// offering and the foreground releasing hold it only for a memcpy-sized
/// critical section, never across a print, so it stays uncontended and needs no
/// Io handle — cards.zig and the io-less render path could not reach one.
fn lock() void {
    while (g_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn unlock() void {
    g_lock.store(false, .release);
}

/// A pool-thread worker wants `text` (whole, newline-terminated lines) on the
/// terminal: printed now at a foreground line boundary, held otherwise.
pub fn workerLine(text: []const u8) void {
    if (root.json_mode) return writeLine(text);
    lock();
    const held = g_gate.offer(text);
    unlock();
    if (!held) writeLine(text);
}

/// workerLine for a format string. The activity lines subsystems print
/// directly ("  [workflow] phase 1/2: …", "  [diversity] …") are exactly the
/// class this module exists for — see the module doc — but they reached stderr
/// through a raw std.debug.print, so they neither honoured the line-boundary
/// gate nor could be elided in a test binary (#444). Same fixed slot and same
/// "a cut line still ends its row" repair as agent_output.say.
pub fn workerPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [slot_bytes]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buf);
    const fit = if (sink.print(fmt, args)) |_| true else |_| false;
    var line = sink.buffered();
    if (!fit or line.len == 0 or line[line.len - 1] != '\n') {
        const at: usize = @min(line.len, buf.len - 1);
        buf[at] = '\n';
        line = buf[0 .. at + 1];
    }
    workerLine(line);
}

/// Publish the foreground stream's position and release everything held once it
/// is back at column 0. Returns the number of physical lines released, so a
/// caller doing cursor math over its own rows can account for them.
pub fn setLineStart(at_bol: bool) usize {
    lock();
    g_gate.mid_line = !at_bol;
    unlock();
    return release();
}

/// Hold worker lines until the next setLineStart(true). For foreground output
/// that owns the rows below the cursor — the live "Thinking" block collapses by
/// cursor math, so a tick printed inside it would be erased with the block.
pub fn hold() void {
    lock();
    g_gate.mid_line = true;
    unlock();
}

fn release() usize {
    var lines: usize = 0;
    var buf: [slot_bytes]u8 = undefined;
    while (true) {
        lock();
        if (g_gate.mid_line) {
            unlock();
            return lines;
        }
        const took = g_gate.take(&buf);
        const dropped = if (took == null) g_gate.takeDropped() else 0;
        unlock();
        if (took) |n| {
            writeLine(buf[0..n]);
            for (buf[0..n]) |c| {
                if (c == '\n') lines += 1;
            }
            continue;
        }
        if (dropped > 0) {
            var note: [64]u8 = undefined;
            writeLine(std.fmt.bufPrint(&note, "  [·] {d} subagent line(s) dropped while the answer streamed\n", .{dropped}) catch "  [·] subagent line(s) dropped while the answer streamed\n");
            lines += 1;
        }
        return lines;
    }
}

test "#444: the worker-line write is elided at comptime in a test binary" {
    // The whole point of the gate under test is the accounting, not the write.
    // If this ever flips true, a passing `zig build test` starts printing a
    // step-failure tree and `failed command: …` on a green exit 0 again,
    // because zig's build runner error-prints any Run step with stderr.
    try std.testing.expect(!emit_to_stderr);
    comptime std.debug.assert(!emit_to_stderr);
    // The bookkeeping is untouched: an offer at a line boundary is still
    // refused (the caller "prints"), and a held one is still retrievable.
    hold();
    defer _ = setLineStart(true);
    workerLine("  [w] held under test\n");
    var buf: [slot_bytes]u8 = undefined;
    lock();
    const n = g_gate.take(&buf);
    unlock();
    try std.testing.expect(n != null);
    try std.testing.expectEqualStrings("  [w] held under test\n", buf[0..n.?]);
}

test "tick gate: a tick offered mid-line waits for the newline (#tui-tick)" {
    var gate: Gate = .{};
    var buf: [slot_bytes]u8 = undefined;
    // Foreground painted part of a row.
    gate.noteForeground("guard `if (buf.len - ");
    try std.testing.expect(gate.mid_line);
    // A worker tick arrives right there: held, not printed.
    try std.testing.expect(gate.offer("  [Review Python hot path] ⚙ bash {}\n"));
    try std.testing.expect(gate.mid_line);
    // Still mid-line: the foreground continues its row, the tick keeps waiting.
    gate.noteForeground("pos < 2)`");
    try std.testing.expect(gate.mid_line);
    // The row ends — now it may land.
    gate.noteForeground("\n");
    try std.testing.expect(!gate.mid_line);
    const n = gate.take(&buf).?;
    try std.testing.expectEqualStrings("  [Review Python hot path] ⚙ bash {}\n", buf[0..n]);
    try std.testing.expect(gate.take(&buf) == null);
}

test "tick gate: at a line boundary the worker prints immediately" {
    var gate: Gate = .{};
    try std.testing.expect(!gate.mid_line); // fresh gate starts at column 0
    try std.testing.expect(!gate.offer("  [w] ⚙ read_file {}\n")); // caller prints
    gate.noteForeground("a full line\n");
    try std.testing.expect(!gate.offer("  [w] ⚙ read_file {}\n"));
    var buf: [slot_bytes]u8 = undefined;
    try std.testing.expect(gate.take(&buf) == null); // nothing was buffered
}

test "tick gate: a flood drops the oldest and counts it, order is FIFO" {
    var gate: Gate = .{};
    var buf: [slot_bytes]u8 = undefined;
    gate.noteForeground("mid");
    var i: usize = 0;
    while (i < max_pending + 2) : (i += 1) {
        var line: [16]u8 = undefined;
        try std.testing.expect(gate.offer(std.fmt.bufPrint(&line, "tick {d}\n", .{i}) catch unreachable));
    }
    try std.testing.expectEqual(@as(u32, 2), gate.dropped); // two oldest evicted
    gate.noteForeground("\n");
    // Survivors drain oldest-first, starting after the two that were dropped.
    i = 2;
    while (gate.take(&buf)) |n| : (i += 1) {
        var want: [16]u8 = undefined;
        try std.testing.expectEqualStrings(std.fmt.bufPrint(&want, "tick {d}\n", .{i}) catch unreachable, buf[0..n]);
    }
    try std.testing.expectEqual(@as(usize, max_pending + 2), i);
    try std.testing.expectEqual(@as(u32, 2), gate.takeDropped());
    try std.testing.expectEqual(@as(u32, 0), gate.takeDropped()); // reading clears it
}

test "tick gate: an oversized tick is cut but still ends its row" {
    var gate: Gate = .{};
    var buf: [slot_bytes]u8 = undefined;
    var big: [slot_bytes + 64]u8 = @splat('x');
    big[big.len - 1] = '\n';
    gate.noteForeground("mid");
    try std.testing.expect(gate.offer(&big));
    gate.noteForeground("\n");
    const n = gate.take(&buf).?;
    try std.testing.expectEqual(@as(usize, slot_bytes), n);
    try std.testing.expectEqual(@as(u8, '\n'), buf[n - 1]); // never leaves the cursor mid-row
}

test "tick gate: the reported mid-word injection cannot happen (#tui-tick)" {
    const gpa = std.testing.allocator;
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(gpa);
    var gate: Gate = .{};
    var buf: [slot_bytes]u8 = undefined;
    const tick = "  [Review Python hot path] ⚙ bash {\"cmd\":\"pytest\"}\n";
    // The transcript's own deltas: the tick arrives after the first one, i.e.
    // exactly where the user saw it land inside the word.
    const deltas = [_][]const u8{ "guard `if (buf.len - ", "pos < 2)` fails\n", "next paragraph\n" };
    for (deltas, 0..) |d, i| {
        try screen.appendSlice(gpa, d);
        gate.noteForeground(d);
        if (i == 0 and !gate.offer(tick)) try screen.appendSlice(gpa, tick);
        while (!gate.mid_line) {
            const n = gate.take(&buf) orelse break;
            try screen.appendSlice(gpa, buf[0..n]);
        }
    }
    // The answer text is intact…
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "guard `if (buf.len - pos < 2)` fails") != null);
    // …and the tick starts its own row instead of splitting a word.
    const at = std.mem.indexOf(u8, screen.items, tick).?;
    try std.testing.expect(at > 0 and screen.items[at - 1] == '\n');
}
