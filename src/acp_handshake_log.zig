//! #1837: name the slow step of an ACP handshake on stderr, timings only.
//!
//! A client sees one pause before its first `session/prompt` and cannot tell
//! process startup from `session/load` from the config round trips. Each
//! handshake phase is timed; one over `phase_budget_ms` gets a line, and the
//! first `session/prompt` gets a summary when the whole handshake was slow.
//! Phase names and milliseconds only: no prompt text, paths, or ids.

const std = @import("std");
const Io = std.Io;

/// A phase this slow is worth naming.
pub const phase_budget_ms: i64 = 200;
/// A whole handshake this slow is "the pause" and gets a summary.
pub const total_budget_ms: i64 = 500;

/// Requests that run before the first prompt. Anything else is not timed.
const phases = [_][]const u8{
    "initialize",
    "session/new",
    "session/load",
    "session/resume",
    "session/set_config_option",
    "session/set_model",
    "session/set_mode",
};

pub const Sink = *const fn (line: []const u8) void;

fn stderrSink(line: []const u8) void {
    std.debug.print("{s}\n", .{line});
}

/// One handshake phase in flight.
pub const Pending = struct { phase: []const u8, started: Io.Timestamp };

pub const Log = struct {
    /// When the process started (`startup_timing.g_started`); null in tests
    /// that do not care about startup.
    process_started: ?Io.Timestamp = null,
    sink: Sink = stderrSink,
    phases: u32 = 0,
    slow: u32 = 0,
    sum_ms: i64 = 0,
    /// The first prompt has been seen; nothing more is timed.
    done: bool = false,

    /// Call before dispatching `line`. Returns the phase to hand to `after`.
    pub fn before(self: *Log, io: Io, line: []const u8) ?Pending {
        if (self.done) return null;
        const method = methodOf(line) orelse return null;
        const now = Io.Timestamp.now(io, .awake);
        if (std.mem.eql(u8, method, "initialize") and self.phases == 0) {
            if (self.process_started) |s| self.record("startup", msBetween(s, now));
        }
        if (std.mem.eql(u8, method, "session/prompt")) {
            self.done = true;
            const total = if (self.process_started) |s| msBetween(s, now) else self.sum_ms;
            if (self.slow > 0 or total >= total_budget_ms) {
                var buf: [96]u8 = undefined;
                self.sink(std.fmt.bufPrint(&buf, "acp handshake slow total_ms={d} phases={d}", .{ total, self.phases }) catch return null);
            }
            return null;
        }
        for (phases) |p| if (std.mem.eql(u8, p, method)) return .{ .phase = p, .started = now };
        return null;
    }

    pub fn after(self: *Log, io: Io, pending: ?Pending) void {
        const p = pending orelse return;
        self.record(p.phase, msBetween(p.started, Io.Timestamp.now(io, .awake)));
    }

    fn record(self: *Log, phase: []const u8, ms: i64) void {
        self.phases += 1;
        self.sum_ms += ms;
        if (ms < phase_budget_ms) return;
        self.slow += 1;
        var buf: [96]u8 = undefined;
        self.sink(std.fmt.bufPrint(&buf, "acp handshake slow phase={s} ms={d}", .{ phase, ms }) catch return);
    }
};

fn msBetween(a: Io.Timestamp, b: Io.Timestamp) i64 {
    return @max(0, a.durationTo(b).toMilliseconds());
}

/// The JSON-RPC method of `line` without parsing the whole request: a prompt
/// can carry megabytes of images. Inside a JSON string a quote is escaped, so
/// an unescaped `"method"` can only be a key.
pub fn methodOf(line: []const u8) ?[]const u8 {
    const key = "\"method\"";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var i = at + key.len;
    while (i < line.len and (line[i] == ' ' or line[i] == ':' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse return null;
    return line[i + 1 .. end];
}

// ── tests ─────────────────────────────────────────────────────────────────

const Captured = struct {
    var lines: [8][96]u8 = undefined;
    var lens: [8]usize = undefined;
    var n: usize = 0;
    fn sink(line: []const u8) void {
        if (n == lines.len) return;
        @memcpy(lines[n][0..line.len], line);
        lens[n] = line.len;
        n += 1;
    }
    fn get(i: usize) []const u8 {
        return lines[i][0..lens[i]];
    }
};

test "acp handshake log: methodOf reads the method key, not text that mentions it" {
    try std.testing.expectEqualStrings("session/load", methodOf("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/load\",\"params\":{}}").?);
    try std.testing.expectEqualStrings("initialize", methodOf("{\"id\":1, \"method\" : \"initialize\"}").?);
    try std.testing.expect(methodOf("{\"id\":1,\"result\":{}}") == null);
    // A prompt whose text says "method" has it escaped, so the key still wins.
    try std.testing.expectEqualStrings("session/prompt", methodOf("{\"method\":\"session/prompt\",\"params\":{\"text\":\"\\\"method\\\":\\\"x\\\"\"}}").?);
}

test "acp handshake log: a slow phase gets one line, fast ones none, and the prompt a summary" {
    Captured.n = 0;
    const io = std.testing.io;
    var log: Log = .{ .sink = Captured.sink };
    // Fast phase: no line.
    log.after(io, log.before(io, "{\"method\":\"initialize\"}"));
    try std.testing.expectEqual(@as(usize, 0), Captured.n);
    // A slow phase, faked by backdating its start.
    var p = log.before(io, "{\"method\":\"session/load\"}").?;
    p.started = p.started.subDuration(.fromMilliseconds(640));
    log.after(io, p);
    try std.testing.expectEqual(@as(usize, 1), Captured.n);
    try std.testing.expect(std.mem.startsWith(u8, Captured.get(0), "acp handshake slow phase=session/load ms=6"));
    // Not a handshake phase: untimed.
    try std.testing.expect(log.before(io, "{\"method\":\"session/cancel\"}") == null);
    // First prompt: the summary, then nothing more is timed.
    try std.testing.expect(log.before(io, "{\"method\":\"session/prompt\"}") == null);
    try std.testing.expectEqual(@as(usize, 2), Captured.n);
    try std.testing.expect(std.mem.startsWith(u8, Captured.get(1), "acp handshake slow total_ms=6"));
    try std.testing.expect(std.mem.endsWith(u8, Captured.get(1), " phases=2"));
    try std.testing.expect(log.before(io, "{\"method\":\"session/load\"}") == null);
}

test "acp handshake log: slow startup is named; a fast handshake logs nothing at all" {
    Captured.n = 0;
    const io = std.testing.io;
    const now = Io.Timestamp.now(io, .awake);
    var slow: Log = .{ .sink = Captured.sink, .process_started = now.subDuration(.fromMilliseconds(450)) };
    slow.after(io, slow.before(io, "{\"method\":\"initialize\"}"));
    try std.testing.expect(std.mem.startsWith(u8, Captured.get(0), "acp handshake slow phase=startup ms=4"));

    Captured.n = 0;
    var fast: Log = .{ .sink = Captured.sink, .process_started = Io.Timestamp.now(io, .awake) };
    fast.after(io, fast.before(io, "{\"method\":\"initialize\"}"));
    fast.after(io, fast.before(io, "{\"method\":\"session/new\"}"));
    _ = fast.before(io, "{\"method\":\"session/prompt\"}");
    try std.testing.expectEqual(@as(usize, 0), Captured.n);
}
