//! Identical tool-batch loop guard (#1706).
//!
//! A model can repeat one call with the same input, get the same result, and
//! keep going until a wall clock kills the run. Nothing else ends that turn:
//! `tool_call_repair.brokenCallLoop` only covers unusable arguments, and the
//! dedupe gate in `agent_tools.rejectToolCall` is opt-in. Each executed batch
//! folds into two runs:
//!
//! - the call run: the same normalized calls with the same results. The
//!   `nudge_at`-th in a row tells the model so, the `stop_at`-th ends the turn.
//! - the result run: the same tools with the same results, whatever the input.
//!   A model that rewords the call (`cat ./x`, `cat 'x'`, `cat -- x`) to get
//!   the same answer again is still not making progress, so the
//!   `reworded_nudge_at`-th tells it and the `reworded_stop_at`-th ends the
//!   turn. A batch whose results carry no content (`(no output)`, a bare exit
//!   code) breaks this run: quiet commands in a row are ordinary work.
//!
//! A batch still waiting on work breaks both runs: a pending or cancelled
//! result, a shell job poll that reports the job is still running
//! (`[job N: running…]`), which is how a model waits on CI or a build, or an
//! `agent_output` snapshot of a subagent still running (`[agent N: running]`).
//! `clock_sleep` is not waiting by itself: it keeps no rail bypass (#225), and
//! a sleep between re-checks puts a different batch between them anyway. Reset
//! at `runTurn`, except when a worker's transient-failure re-ask resumes the
//! same history (`carryOver`): a fresh count there would let a looping worker
//! repeat up to `stop_at - 1` more batches per ask.

const std = @import("std");
const tools = @import("tools.zig");

pub const nudge_at: u8 = 4;
pub const stop_at: u8 = 8;
pub const reworded_nudge_at: u8 = 6;
pub const reworded_stop_at: u8 = 12;

pub const nudge_text = std.fmt.comptimePrint("[graff] This call ran with this input and returned this result {d} times in a row. Repeating it will not make progress: take a different step, or finish with what you have.", .{nudge_at});

pub const stop_text = std.fmt.comptimePrint("Stopped: the model repeated the same tool call with the same result {d} times in a row, so the turn ended instead of running it again. Send a new message to continue, or switch models.", .{stop_at});

pub const reworded_nudge_text = std.fmt.comptimePrint("[graff] This tool returned this same result {d} times in a row; only the wording of the call changed. Rewording it will not make progress: take a different step, or finish with what you have.", .{reworded_nudge_at});

pub const reworded_stop_text = std.fmt.comptimePrint("Stopped: the model got the same tool result {d} times in a row while rewording the call, so the turn ended instead of running it again. Send a new message to continue, or switch models.", .{reworded_stop_at});

/// One run of equal fingerprints; null (no countable batch) breaks it.
const Run = struct {
    last: u64 = 0,
    len: u8 = 0,

    fn note(self: *Run, fp: ?u64) u8 {
        const f = fp orelse {
            self.* = .{};
            return 0;
        };
        if (self.len > 0 and f == self.last) {
            self.len +|= 1;
        } else {
            self.* = .{ .last = f, .len = 1 };
        }
        return self.len;
    }
};

pub const Notice = enum { none, repeated, reworded };

/// Turn-scoped runs of repeating batches. No heap.
pub const Tracker = struct {
    calls: Run = .{},
    results: Run = .{},
    carry: bool = false,

    pub fn reset(self: *Tracker) void {
        if (self.carry) {
            self.carry = false;
            return;
        }
        self.* = .{};
    }

    /// The next `reset` keeps the runs: the coming `runTurn` resumes this
    /// turn's history rather than starting a new one.
    pub fn carryOver(self: *Tracker) void {
        self.carry = true;
    }

    /// Folds one batch into both runs; says which notice, if any, it earned.
    pub fn note(self: *Tracker, calls_fp: ?u64, results_fp: ?u64) Notice {
        const same_call = self.calls.note(calls_fp);
        const same_result = self.results.note(results_fp);
        if (same_call == nudge_at) return .repeated;
        if (same_result == reworded_nudge_at and same_call < nudge_at) return .reworded;
        return .none;
    }

    /// The text that ends the turn, once a run reached its stop.
    pub fn stopText(self: *const Tracker) ?[]const u8 {
        if (self.calls.len >= stop_at) return stop_text;
        if (self.results.len >= reworded_stop_at) return reworded_stop_text;
        return null;
    }
};

/// A shell job poll whose job has not exited yet (jobs.zig/job_notify.zig).
fn jobRunning(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "[job ")) return false;
    const head = text[0 .. std.mem.indexOfScalar(u8, text, ']') orelse text.len];
    return std.mem.indexOf(u8, head, ": running") != null;
}

/// An `agent_output` snapshot of a subagent that has not finished
/// (`subagent.agentStatusText`). With `ids`, one report per agent is joined
/// by blank lines, so any line of that exact shape means one is still out.
fn agentRunning(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[agent ") or !std.mem.endsWith(u8, line, ": running]")) continue;
        const id = line["[agent ".len .. line.len - ": running]".len];
        if (id.len > 0 and std.mem.indexOfNone(u8, id, "0123456789") == null) return true;
    }
    return false;
}

/// The result says the work it reports on is still going: polling it again
/// and reading the same line is waiting, not repeating.
fn stillRunning(text: []const u8) bool {
    return jobRunning(text) or agentRunning(text);
}

/// Inputs that only bound or label a call. A model that varies them, or the
/// spacing inside a command, to dodge the guard is still repeating itself:
/// one live run polled `cat status.txt` as `cat  status.txt`, then with
/// `timeout` 1000, 1001, 1002...
const knobs = [_][]const u8{ "timeout", "timeout_ms", "wait_ms", "description" };

/// The call's identity for the fingerprint: its name and input, minus the
/// top-level knobs, with whitespace runs in strings collapsed.
pub fn callKey(arena: std.mem.Allocator, call: tools.ToolCall) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll(call.name);
    try aw.writer.writeByte('\n');
    try writeInput(&aw.writer, call.input, true);
    return aw.writer.buffered();
}

fn writeInput(w: *std.Io.Writer, v: std.json.Value, top: bool) !void {
    switch (v) {
        .string => |text| {
            try w.writeByte('"');
            var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
            var first = true;
            while (it.next()) |word| : (first = false) {
                if (!first) try w.writeByte(' ');
                try w.writeAll(word);
            }
            try w.writeByte(0);
        },
        .object => |o| {
            try w.writeByte('{');
            var it = o.iterator();
            entries: while (it.next()) |kv| {
                if (top) for (knobs) |k| if (std.mem.eql(u8, kv.key_ptr.*, k)) continue :entries;
                try w.print("{s}:", .{kv.key_ptr.*});
                try writeInput(w, kv.value_ptr.*, false);
                try w.writeByte(',');
            }
            try w.writeByte('}');
        },
        .array => |a| {
            try w.writeByte('[');
            for (a.items) |item| {
                try writeInput(w, item, false);
                try w.writeByte(',');
            }
            try w.writeByte(']');
        },
        else => {
            var j: std.json.Stringify = .{ .writer = w };
            try j.write(v);
        },
    }
}

/// Null when any result is still waiting: waiting is not repeating.
pub fn fingerprint(keys: []const []const u8, results: []const tools.ExecResult) ?u64 {
    var h = std.hash.Wyhash.init(0x1706);
    for (keys, results) |key, r| {
        if (r.pending or r.cancelled or stillRunning(r.text)) return null;
        h.update(key);
        h.update(&.{ 0, @intFromBool(r.is_error) });
        h.update(r.text);
        h.update(&.{0});
    }
    return h.final();
}

/// No output and no error text: `(no output)`, or nothing but `[exit code N]`.
fn contentFree(text: []const u8) bool {
    var rest = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.endsWith(u8, rest, "]")) {
        if (std.mem.lastIndexOf(u8, rest, "[exit code ")) |i| rest = std.mem.trim(u8, rest[0..i], " \t\r\n");
    }
    return rest.len == 0 or std.mem.eql(u8, rest, "(no output)");
}

/// The batch's tools and results, input ignored. Null when every result is
/// content-free, or when any is still waiting.
pub fn resultFingerprint(names: []const []const u8, results: []const tools.ExecResult) ?u64 {
    for (results) |r| {
        if (!contentFree(r.text)) break;
    } else return null;
    return fingerprint(names, results);
}

/// After a batch ran: count it, and on the nudge append the notice to the
/// last result so the model reads it with what it just got back.
pub fn observe(self: anytype, calls: []const tools.ToolCall, results: []tools.ExecResult) !void {
    if (calls.len == 0) return;
    const keys = try self.arena.alloc([]const u8, calls.len);
    const names = try self.arena.alloc([]const u8, calls.len);
    for (calls, keys, names) |call, *key, *name| {
        key.* = try callKey(self.arena, call);
        name.* = call.name;
    }
    const notice = switch (self.tool_repeat.note(fingerprint(keys, results), resultFingerprint(names, results))) {
        .none => return,
        .repeated => nudge_text,
        .reworded => reworded_nudge_text,
    };
    const last = &results[results.len - 1];
    last.text = try std.fmt.allocPrint(self.arena, "{s}\n\n{s}", .{ last.text, notice });
}

test "identical batches build a run that stops at stop_at" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"shell\n{\"command\":\"echo ok\"}"};
    const ok = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
    var i: u8 = 1;
    while (i < stop_at) : (i += 1) {
        try std.testing.expectEqual(i, t.calls.note(fingerprint(&keys, &ok)));
        try std.testing.expect(t.stopText() == null);
    }
    try std.testing.expectEqual(stop_at, t.calls.note(fingerprint(&keys, &ok)));
    try std.testing.expectEqual(@as(?[]const u8, stop_text), t.stopText());
    t.reset();
    try std.testing.expect(t.stopText() == null);
}

test "a carried run survives one reset, then resets clear it again" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"shell\n{\"command\":\"echo ok\"}"};
    const ok = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
    var i: u8 = 1;
    while (i < stop_at) : (i += 1) _ = t.calls.note(fingerprint(&keys, &ok));
    t.carryOver();
    t.reset();
    try std.testing.expectEqual(stop_at, t.calls.note(fingerprint(&keys, &ok)));
    try std.testing.expect(t.stopText() != null);
    t.reset();
    try std.testing.expect(t.stopText() == null);
    try std.testing.expectEqual(@as(u8, 1), t.calls.note(fingerprint(&keys, &ok)));
}

test "a different input, result, or error flag starts a new run" {
    var t: Tracker = .{};
    const a = [_][]const u8{"shell\n{\"command\":\"echo ok\"}"};
    const b = [_][]const u8{"shell\n{\"command\":\"echo ko\"}"};
    const ok = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
    const ok_err = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = true }};
    const other = [_]tools.ExecResult{.{ .text = "ok 2\n", .is_error = false }};
    _ = t.calls.note(fingerprint(&a, &ok));
    try std.testing.expectEqual(@as(u8, 2), t.calls.note(fingerprint(&a, &ok)));
    try std.testing.expectEqual(@as(u8, 1), t.calls.note(fingerprint(&b, &ok)));
    try std.testing.expectEqual(@as(u8, 1), t.calls.note(fingerprint(&b, &other)));
    try std.testing.expectEqual(@as(u8, 1), t.calls.note(fingerprint(&b, &ok_err)));
}

test "a pending or cancelled result never counts and breaks the run" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"agent_output\n{\"id\":\"a1\"}"};
    const done = [_]tools.ExecResult{.{ .text = "still running", .is_error = false }};
    const waiting = [_]tools.ExecResult{.{ .text = "still running", .is_error = false, .pending = true }};
    const cancelled = [_]tools.ExecResult{.{ .text = "still running", .is_error = false, .cancelled = true }};
    _ = t.calls.note(fingerprint(&keys, &done));
    _ = t.calls.note(fingerprint(&keys, &done));
    try std.testing.expectEqual(@as(u8, 0), t.calls.note(fingerprint(&keys, &waiting)));
    try std.testing.expectEqual(@as(u8, 1), t.calls.note(fingerprint(&keys, &done)));
    try std.testing.expectEqual(@as(u8, 0), t.calls.note(fingerprint(&keys, &cancelled)));
}

test "polling a job that is still running never counts, a finished job's output does" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"bash_output\n{\"id\":34,\"wait_ms\":30000}"};
    const running = [_]tools.ExecResult{.{ .text = "[job 34: running] Refreshing run status", .is_error = false }};
    const parked = [_]tools.ExecResult{.{ .text = "[job 9: running — persistent server; parked in the background. You are notified on exit; do not poll]", .is_error = false }};
    const exited = [_]tools.ExecResult{.{ .text = "[job 34: exited with code 0]\nok", .is_error = false }};
    var i: u8 = 0;
    while (i < 12) : (i += 1) try std.testing.expectEqual(@as(u8, 0), t.calls.note(fingerprint(&keys, &running)));
    while (i < 24) : (i += 1) try std.testing.expectEqual(@as(u8, 0), t.calls.note(fingerprint(&keys, &parked)));
    try std.testing.expect(t.stopText() == null);
    i = 1;
    while (i <= stop_at) : (i += 1) _ = t.calls.note(fingerprint(&keys, &exited));
    try std.testing.expect(t.stopText() != null);
}

test "polling a subagent that is still running never counts, its finished report does" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"agent_output\n{\"id\":7}"};
    const running = [_]tools.ExecResult{.{ .text = "[agent 7: running]", .is_error = false }};
    const many = [_]tools.ExecResult{.{ .text = "[agent 6: completed in 900ms · 2 tool call(s) · ~10 context token(s) · 0 cache-read token(s)]\n\nreport\n\n[agent 7: running]", .is_error = false }};
    const done = [_]tools.ExecResult{.{ .text = "[agent 7: completed in 1200ms · 3 tool call(s) · ~4500 context token(s) · 100 cache-read token(s)]\n\nreport", .is_error = false }};
    const lookalike = [_]tools.ExecResult{.{ .text = "[agent x: running]", .is_error = false }};
    var i: u8 = 0;
    while (i < 2 * stop_at) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 0), t.calls.note(fingerprint(&keys, &running)));
        try std.testing.expectEqual(@as(u8, 0), t.calls.note(fingerprint(&keys, &many)));
    }
    try std.testing.expect(t.stopText() == null);
    try std.testing.expect(fingerprint(&keys, &lookalike) != null);
    i = 1;
    while (i <= stop_at) : (i += 1) _ = t.calls.note(fingerprint(&keys, &done));
    try std.testing.expectEqual(@as(?[]const u8, stop_text), t.stopText());
}

test "an empty-argument error loop still stops" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"read_file\n{}"};
    const err = [_]tools.ExecResult{.{ .text = "[error] tool call arguments were truncated", .is_error = true }};
    var i: u8 = 0;
    while (i < stop_at) : (i += 1) _ = t.calls.note(fingerprint(&keys, &err));
    try std.testing.expect(t.stopText() != null);
}

test "observe appends the notice on the nudge batch only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const Fake = struct {
        arena: std.mem.Allocator,
        tool_repeat: Tracker = .{},
    };
    var fake: Fake = .{ .arena = arena_state.allocator() };
    const calls = [_]tools.ToolCall{.{ .id = "c", .name = "shell", .input = .null }};
    var i: u8 = 1;
    while (i <= nudge_at + 1) : (i += 1) {
        var results = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
        try observe(&fake, &calls, &results);
        const noticed = std.mem.indexOf(u8, results[0].text, nudge_text) != null;
        try std.testing.expectEqual(i == nudge_at, noticed);
    }
}

test "the same result under reworded calls nudges at 6 and stops at 12" {
    var t: Tracker = .{};
    const names = [_][]const u8{"shell"};
    const pending = [_]tools.ExecResult{.{ .text = "PENDING\n", .is_error = false }};
    const spellings = [_][]const u8{ "cat status.txt", "cat ./status.txt", "cat 'status.txt'", "cat -- status.txt", "cat \"status.txt\"", "cat ././status.txt" };
    var i: u8 = 1;
    while (i <= reworded_stop_at) : (i += 1) {
        const keys = [_][]const u8{spellings[(i - 1) % spellings.len]};
        const notice = t.note(fingerprint(&keys, &pending), resultFingerprint(&names, &pending));
        try std.testing.expectEqual(if (i == reworded_nudge_at) Notice.reworded else Notice.none, notice);
        try std.testing.expectEqual(i == reworded_stop_at, t.stopText() != null);
    }
    try std.testing.expectEqual(@as(?[]const u8, reworded_stop_text), t.stopText());
}

test "identical calls take the call notice and stop, never the reworded one" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"shell\n{\"command\":\"echo ok\"}"};
    const names = [_][]const u8{"shell"};
    const ok = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
    var i: u8 = 1;
    while (i <= stop_at) : (i += 1) {
        const notice = t.note(fingerprint(&keys, &ok), resultFingerprint(&names, &ok));
        try std.testing.expectEqual(if (i == nudge_at) Notice.repeated else Notice.none, notice);
    }
    try std.testing.expectEqual(@as(?[]const u8, stop_text), t.stopText());
}

test "content-free results under different calls are ordinary work" {
    var t: Tracker = .{};
    const names = [_][]const u8{"shell"};
    const quiet = [_][]const tools.ExecResult{
        &.{.{ .text = "(no output)", .is_error = false }},
        &.{.{ .text = "\n[exit code 1]", .is_error = true }},
        &.{.{ .text = "", .is_error = false }},
    };
    var i: u8 = 0;
    while (i < 3 * reworded_stop_at) : (i += 1) {
        const r = quiet[i % quiet.len];
        try std.testing.expectEqual(@as(?u64, null), resultFingerprint(&names, r));
        const keys = [_][]const u8{if (i % 2 == 0) "grep a" else "grep b"};
        try std.testing.expectEqual(Notice.none, t.note(fingerprint(&keys, r), resultFingerprint(&names, r)));
    }
    try std.testing.expect(t.stopText() == null);
    const noisy = [_]tools.ExecResult{.{ .text = "boom\n[exit code 1]", .is_error = true }};
    try std.testing.expect(resultFingerprint(&names, &noisy) != null);
}

test "observe appends the reworded notice when only the wording changes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Fake = struct {
        arena: std.mem.Allocator,
        tool_repeat: Tracker = .{},
    };
    var fake: Fake = .{ .arena = arena };
    const dots = "./././././././.";
    var i: u8 = 1;
    while (i <= reworded_nudge_at + 1) : (i += 1) {
        const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, try std.fmt.allocPrint(arena, "{{\"command\":\"cat {s}status.txt\"}}", .{dots[0 .. 2 * @as(usize, i)]}), .{});
        const calls = [_]tools.ToolCall{.{ .id = "c", .name = "shell", .input = input }};
        var results = [_]tools.ExecResult{.{ .text = "PENDING\n", .is_error = false }};
        try observe(&fake, &calls, &results);
        try std.testing.expectEqual(i == reworded_nudge_at, std.mem.indexOf(u8, results[0].text, reworded_nudge_text) != null);
        try std.testing.expect(std.mem.indexOf(u8, results[0].text, nudge_text) == null);
    }
}

test "the key ignores knobs and spacing, not what the call does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inputs = [_][]const u8{
        "{\"command\":\"cat status.txt\"}",
        "{\"command\":\"cat  status.txt\"}",
        "{\"command\":\"cat status.txt\",\"timeout\":1000}",
        "{\"command\":\" cat status.txt\\n\",\"timeout\":1001,\"description\":\"poll\"}",
    };
    var keys: [inputs.len][]const u8 = undefined;
    for (inputs, &keys) |text, *key| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        key.* = try callKey(arena, .{ .id = "c", .name = "shell", .input = v });
    }
    for (keys[1..]) |key| try std.testing.expectEqualStrings(keys[0], key);
    const differ = [_][]const u8{
        "{\"command\":\"cat other.txt\"}",
        "{\"command\":\"cat status.txt\",\"run_in_background\":true}",
        "{\"command\":\"cat status.txt\",\"opts\":{\"timeout\":1}}",
    };
    for (differ) |text| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        try std.testing.expect(!std.mem.eql(u8, keys[0], try callKey(arena, .{ .id = "c", .name = "shell", .input = v })));
    }
    const read = try std.json.parseFromSliceLeaky(std.json.Value, arena, inputs[0], .{});
    try std.testing.expect(!std.mem.eql(u8, keys[0], try callKey(arena, .{ .id = "c", .name = "read_file", .input = read })));
}
