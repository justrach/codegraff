//! Session tracing + DGM trajectory archive: the per-line JSON writer, the
//! harness.trace.jsonl event Tracer (which also feeds the telemetry counters),
//! the append-only harness.trajectory.jsonl Trajectory (the MAP-Elites fitness
//! ledger), and the per-agent ToolSink tool-call log. Split out of main.zig
//! (600-line goal). Imports telemetry.zig for the counter sink. main aliases
//! Tracer/Trajectory/ToolSink/trace_path back, re-exports trajectory_path
//! (fleet.zig back-imports it), and mod-qualifies g_traj.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const telemetry = @import("telemetry.zig");

pub const trace_path = "harness.trace.jsonl";

/// Serialize one record as a single JSON line into an in-memory buffer, then
/// write the whole line to `w` in one shot. Building the line in memory first
/// means a partial serialization failure writes *nothing* — the shared buffered
/// file writer never sees a half-record, and the trailing newline is always
/// attached to its record. Without this, a write that errored mid-record left a
/// truncated line plus leftover buffer bytes that the next record concatenated
/// onto, corrupting the JSONL (issue #86: lines like `{"text":"You ar{"kind":…`).
/// Flushing per line keeps the buffer empty between records. Best-effort.
fn writeJsonLine(gpa: Allocator, w: *Io.Writer, rec: anytype) void {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(rec) catch return;
    aw.writer.writeByte('\n') catch return;
    w.writeAll(aw.writer.buffered()) catch return;
    w.flush() catch return;
}

/// Session event trace: one JSON object per line, written to trace_path in
/// the cwd (truncated at startup, so it always covers the current session).
/// Thread-safe — agents on pool threads share it through the mutex. The
/// system prompt tells the agent the file exists, so it can read its own
/// trace to debug or profile the harness ("t" is ms since session start).
pub const Tracer = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    out: ?*Io.Writer,
    start: Io.Timestamp,
    enabled: bool = true,

    pub fn api(self: *Tracer, label: []const u8, model: []const u8, ms: i64, req_bytes: usize, resp_bytes: usize, context_tokens: u64, cache_read: u64, is_error: bool) void {
        if (telemetry.g_telem) |t| t.countApi(model, is_error);
        self.write(.{
            .t = self.elapsedMs(),
            .ev = "api",
            .agent = label,
            .model = model,
            .ms = ms,
            .req_bytes = req_bytes,
            .resp_bytes = resp_bytes,
            .context_tokens = context_tokens,
            .cache_read_tokens = cache_read,
            .is_error = is_error,
        });
    }

    pub fn tool(self: *Tracer, name: []const u8, ms: i64, is_error: bool, result_bytes: usize, from_sub: bool) void {
        if (telemetry.g_telem) |t| t.countTool(is_error);
        self.write(.{
            .t = self.elapsedMs(),
            .ev = "tool",
            .name = name,
            .ms = ms,
            .result_bytes = result_bytes,
            .is_error = is_error,
            .from_sub = from_sub,
        });
    }

    pub fn note(self: *Tracer, kind: []const u8, detail: []const u8) void {
        self.write(.{ .t = self.elapsedMs(), .ev = kind, .detail = detail });
    }

    pub fn elapsedMs(self: *Tracer) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    /// Serialize any struct as one JSON line. Best-effort: trace failures
    /// never disturb the session.
    pub fn write(self: *Tracer, event: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const w = self.out orelse return;
        if (!self.enabled) return;
        writeJsonLine(self.gpa, w, event);
    }

    pub fn toggle(self: *Tracer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.enabled = !self.enabled;
        return self.enabled;
    }
};

// ── Trajectory (DGM-style archive tree) ────────────────────────────────────

pub const trajectory_path = "harness.trajectory.jsonl";

/// Session trajectory in the shape of the Darwin Gödel Machine's archive
/// tree (arXiv:2505.22954): one JSON node per agent run. Root turns form
/// the spine (each turn's parent is the previous turn); every subagent or
/// workflow task hangs off the turn that spawned it. Each node carries a
/// fingerprint of the system prompt it ran with, so prompt mutations —
/// set_system_prompt on the spine, per-child system_prompt overrides on the
/// fan-out — are visible as hash changes along edges, and a lineage can be
/// replayed or scored offline (see docs/hyperagents.md, arXiv:2603.19461).
/// Written to harness.trajectory.jsonl, truncated at startup like the trace.
pub const Trajectory = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    out: ?*Io.Writer,
    start: Io.Timestamp,
    next_id: u64 = 1, // node 0 is the session itself
    turn_node: u64 = 0, // current root-turn node: parent for spawned agents
    seen_shas: std.ArrayList([16]u8) = .empty, // prompts captured this session

    /// Reserve a node id (turns claim theirs before running so children can
    /// point at them).
    pub fn nextId(self: *Trajectory) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn setTurn(self: *Trajectory, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.turn_node = id;
    }

    pub fn currentTurn(self: *Trajectory) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.turn_node;
    }

    pub fn elapsedMs(self: *Trajectory) i64 {
        return @intCast(@max(0, self.start.untilNow(self.io, .awake).toMilliseconds()));
    }

    /// Serialize one node as a JSON line. Best-effort, like the Tracer.
    pub fn node(self: *Trajectory, rec: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writeLocked(rec);
    }

    /// Capture the full prompt text behind a fingerprint, once per session
    /// (a `kind:"prompt"` record): the archive then maps sha → text so any
    /// lineage can be replayed or re-mutated offline. Dedup is per session;
    /// across sessions a sha repeats at most once per session — readers
    /// treat the records as an idempotent map.
    pub fn capturePrompt(self: *Trajectory, sha: [16]u8, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.out == null) return;
        for (self.seen_shas.items) |s| if (std.mem.eql(u8, &s, &sha)) return;
        self.seen_shas.append(self.gpa, sha) catch return;
        self.writeLocked(.{ .kind = "prompt", .prompt_sha = &sha, .text = text });
    }

    pub fn writeLocked(self: *Trajectory, rec: anytype) void {
        const w = self.out orelse return;
        writeJsonLine(self.gpa, w, rec);
    }

    pub fn deinit(self: *Trajectory) void {
        self.seen_shas.deinit(self.gpa);
    }
};

/// Set by main(); runSub and the REPL loop record nodes through this.
pub var g_traj: ?*Trajectory = null;

/// Per-agent record of external tool calls (name + error flag, in call
/// order): the process signal behind "which tool combinations work" —
/// rendered into trajectory nodes and OTLP run events, joinable to scores
/// via prompt_sha. Tool fan-out is concurrent, so appends lock. Capped:
/// the first 64 calls are plenty for pattern mining.
pub const ToolSink = struct {
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { name: []const u8, err: bool };
    const cap = 64;

    pub fn add(self: *ToolSink, io: Io, gpa: Allocator, name: []const u8, err: bool) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.items.len >= cap) return;
        self.entries.append(gpa, .{ .name = name, .err = err }) catch {};
    }

    /// "read_file,edit_file!,bash" — `!` marks a failed call. Allocated from
    /// `alloc`; "" when no tools ran. Call after the agent's tool futures
    /// are joined (no lock taken).
    pub fn render(self: *const ToolSink, alloc: Allocator) []const u8 {
        if (self.entries.items.len == 0) return "";
        var aw: Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) aw.writer.writeByte(',') catch return "";
            aw.writer.writeAll(e.name) catch return "";
            if (e.err) aw.writer.writeByte('!') catch return "";
        }
        return alloc.dupe(u8, aw.writer.buffered()) catch "";
    }

    pub fn clear(self: *ToolSink, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *ToolSink, gpa: Allocator) void {
        self.entries.deinit(gpa);
    }
};
test "writeJsonLine: one complete newline-terminated JSON record per call" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    writeJsonLine(std.testing.allocator, &aw.writer, .{ .kind = "turn", .id = @as(u64, 7), .ok = true });
    writeJsonLine(std.testing.allocator, &aw.writer, .{ .kind = "prompt", .text = "hi" });
    const out = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    while (it.next()) |line| {
        var p = try std.json.parseFromSlice(Value, std.testing.allocator, line, .{});
        defer p.deinit();
        try std.testing.expect(p.value == .object); // each line parses as valid JSON
    }
}
