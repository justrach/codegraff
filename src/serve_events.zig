//! The durable side of `graff serve` (#330 part 2): a per-session append-only
//! log of the exact protocol event lines the bridge forwarded, plus the replay
//! filter and the line helpers serve.zig reads events with.
//!
//! Why a second file rather than the existing `.graff/traces/<run>.jsonl`: the
//! trace stream is per-PROCESS performance telemetry keyed by run id, and it
//! does not contain protocol events at all — nothing in it can reconstruct the
//! `--json` stream a supervisor lost. The conversation itself is NOT duplicated
//! here; that stays in `.graff/sessions/<name>.session.json`, which the child
//! already autosaves after every turn and `--resume <name>` already restores.
//! This log is only the event tape, keyed by the same session name, so a
//! REPLACEMENT serve process appends to the very file the dead one was writing
//! and `?from=N` keeps meaning the same thing across the process boundary.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol_seq = @import("protocol_seq.zig");

pub const serve_dir = ".graff/serve";
/// The producer stamps `seq`; the bridge only reads it back off the line.
pub const seqOf = protocol_seq.seqOf;
/// Cap on a whole event log we are willing to slurp for a cold replay. Well
/// past a realistic session; a bigger file replays nothing rather than trying
/// to buy the memory.
pub const max_log_bytes = 64 * 1024 * 1024;

pub fn logPath(allocator: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.events.jsonl", .{ serve_dir, name });
}

/// A session name is both a URL path segment and a file name, so it is
/// restricted to characters that are unambiguous in both and can never walk
/// out of `.graff/`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Append-only writer for one live session. Best-effort throughout: losing the
/// log degrades resumability, it must never fail a turn. On any write error the
/// file is dropped rather than kept at a drifted offset (#242's lesson: a
/// swallowed short write silently corrupts every later record).
pub const EventLog = struct {
    io: Io,
    file: ?Io.File = null,
    offset: u64 = 0,

    pub fn open(io: Io, dir: Io.Dir, path: []const u8) EventLog {
        if (std.fs.path.dirname(path)) |parent| dir.createDirPath(io, parent) catch {};
        const file = dir.createFile(io, path, .{ .truncate = false }) catch return .{ .io = io };
        const size: u64 = if (file.stat(io)) |st| st.size else |_| 0;
        return .{ .io = io, .file = file, .offset = size };
    }

    pub fn close(self: *EventLog) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    /// Persist one event line (without its newline; this adds it).
    pub fn append(self: *EventLog, line: []const u8) void {
        const file = self.file orelse return;
        file.writePositionalAll(self.io, line, self.offset) catch return self.close();
        self.offset += line.len;
        file.writePositionalAll(self.io, "\n", self.offset) catch return self.close();
        self.offset += 1;
    }
};

/// Highest `seq` persisted in `data`. 0 when the log is empty or unstamped.
/// Only COMPLETE (newline-terminated) lines count: a half-written tail is a
/// mid-append artifact, and reporting its id as the end of the tape would tell
/// a reconnecting client to skip past an event it never received.
pub fn lastSeqOf(data: []const u8) u64 {
    var high: u64 = 0;
    var rest = data;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = std.mem.trim(u8, rest[0..nl], " \t\r");
        rest = rest[nl + 1 ..];
        if (line.len == 0) continue;
        if (protocol_seq.seqOf(line)) |s| high = @max(high, s);
    }
    return high;
}

/// Highest `seq` already on disk for `name`, so a fresh bridge can tell a
/// client where the tape ends before it reconnects.
pub fn lastSeqOnDisk(io: Io, dir: Io.Dir, gpa: Allocator, path: []const u8) u64 {
    const data = dir.readFileAlloc(io, path, gpa, .limited(max_log_bytes)) catch return 0;
    defer gpa.free(data);
    return lastSeqOf(data);
}

pub const Replayed = struct {
    /// Lines written to the sink.
    emitted: usize = 0,
    /// Highest seq written; 0 when nothing matched.
    last_seq: u64 = 0,
    /// The last line written terminates a protocol request.
    terminal: bool = false,
};

/// Write every COMPLETE line of `data` whose stamped seq is >= `from`.
///
/// A trailing partial line (the producer is mid-append) is deliberately not
/// written — the caller polls again once its newline lands, which is what makes
/// duplicate-free tailing possible. Unstamped lines are skipped rather than
/// guessed at, so replay can never invent a position. CRLF tolerant.
pub fn replay(w: *Io.Writer, data: []const u8, from: u64) !Replayed {
    var out: Replayed = .{};
    var rest = data;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const raw = rest[0..nl];
        rest = rest[nl + 1 ..];
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const seq = protocol_seq.seqOf(line) orelse continue;
        if (seq < from) continue;
        try w.writeAll(line);
        try w.writeByte('\n');
        out.emitted += 1;
        out.last_seq = seq;
        out.terminal = terminalEvent(line);
    }
    return out;
}

/// Streams complete lines appended to a log by ANOTHER writer (the in-flight
/// request, possibly in this process, possibly not). Stateless about partial
/// lines: the file offset only ever advances past a newline, so a line that is
/// still being written is simply re-read on the next poll.
pub const Follower = struct {
    io: Io,
    file: ?Io.File = null,
    offset: u64 = 0,
    buf: []u8,

    pub fn open(io: Io, dir: Io.Dir, path: []const u8, buf: []u8, from_offset: u64) Follower {
        const file = dir.openFile(io, path, .{}) catch return .{ .io = io, .buf = buf };
        return .{ .io = io, .file = file, .buf = buf, .offset = from_offset };
    }

    pub fn close(self: *Follower) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    /// Bytes ending at the last complete line, or "" when nothing new landed.
    pub fn poll(self: *Follower) []const u8 {
        const file = self.file orelse return "";
        const size = (file.stat(self.io) catch return "").size;
        if (size <= self.offset) return "";
        const want: usize = @intCast(@min(@as(u64, self.buf.len), size - self.offset));
        const got = file.readPositionalAll(self.io, self.buf[0..want], self.offset) catch return "";
        const chunk = self.buf[0..got];
        const last_nl = std.mem.lastIndexOfScalar(u8, chunk, '\n') orelse return "";
        self.offset += last_nl + 1;
        return chunk[0 .. last_nl + 1];
    }
};

/// Is this child event line the terminal event of a protocol request?
/// turn/error end user turns; the rest are between-turn acks. Unknown event
/// types stream through (edge-version durability) — a newer child must still
/// terminate every request with one of these.
pub fn terminalEvent(line: []const u8) bool {
    const t = stringField(line, "type") orelse "";
    return std.mem.eql(u8, t, "turn") or std.mem.eql(u8, t, "error") or
        std.mem.eql(u8, t, "system_prompt") or std.mem.eql(u8, t, "score") or
        std.mem.eql(u8, t, "model") or std.mem.eql(u8, t, "compact") or
        std.mem.eql(u8, t, "mode") or std.mem.eql(u8, t, "agent") or
        std.mem.eql(u8, t, "effort") or std.mem.eql(u8, t, "fast");
}

/// Pull a JSON string field out of an event line by scanning, not parsing:
/// `type` sits in the envelope, so this stays O(1) on a MiB-sized tool_result.
pub fn stringField(line: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (field.len + 4 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = start + needle.len;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '"') return line[start + needle.len .. i];
    }
    return null;
}

/// `from` out of a request target's query string (`/v1/…?from=12&x=y`).
pub fn queryU64(query: []const u8, key: []const u8) ?u64 {
    var it = std.mem.splitAny(u8, query, "&;");
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return std.fmt.parseInt(u64, pair[eq + 1 ..], 10) catch null;
    }
    return null;
}

/// Split a request target into path and query. No query -> "".
pub fn splitTarget(target: []const u8) struct { path: []const u8, query: []const u8 } {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return .{ .path = target, .query = "" };
    return .{ .path = target[0..q], .query = target[q + 1 ..] };
}

const testing = std.testing;

test "replay: from=N is inclusive, gap-free, and never duplicates" {
    const log =
        "{\"seq\":1,\"type\":\"started\"}\n" ++
        "{\"seq\":2,\"type\":\"text\",\"text\":\"a\"}\n" ++
        "{\"seq\":3,\"type\":\"text\",\"text\":\"b\"}\n" ++
        "{\"seq\":4,\"type\":\"turn\",\"text\":\"done\"}\n";
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const all = try replay(&w, log, 1);
    try testing.expectEqual(@as(usize, 4), all.emitted);
    try testing.expectEqual(@as(u64, 4), all.last_seq);
    try testing.expect(all.terminal); // the turn event closes the request
    try testing.expectEqualStrings(log, w.buffered());

    var buf2: [1024]u8 = undefined;
    var w2: Io.Writer = .fixed(&buf2);
    const tail = try replay(&w2, log, 3);
    try testing.expectEqual(@as(usize, 2), tail.emitted);
    try testing.expect(std.mem.startsWith(u8, w2.buffered(), "{\"seq\":3,"));
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"seq\":2") == null);

    // Past the end: nothing replayed, and nothing invented.
    var buf3: [64]u8 = undefined;
    var w3: Io.Writer = .fixed(&buf3);
    const none = try replay(&w3, log, 99);
    try testing.expectEqual(@as(usize, 0), none.emitted);
    try testing.expectEqual(@as(u64, 0), none.last_seq);
    try testing.expect(!none.terminal);
    try testing.expectEqual(@as(usize, 0), w3.buffered().len);
}

test "replay: holds back a partial line, tolerates CRLF and unstamped noise" {
    // The producer is mid-append: the last line has no newline yet.
    const log = "{\"seq\":1,\"type\":\"text\"}\r\n\r\n{\"type\":\"error\"}\n{\"seq\":2,\"type\":\"tur";
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const got = try replay(&w, log, 1);
    try testing.expectEqual(@as(usize, 1), got.emitted); // seq 2 is still partial
    try testing.expectEqual(@as(u64, 1), got.last_seq);
    // CR stripped, blank line skipped, unstamped line skipped rather than guessed.
    try testing.expectEqualStrings("{\"seq\":1,\"type\":\"text\"}\n", w.buffered());
    try testing.expectEqual(@as(u64, 1), lastSeqOf(log));
}

test "lastSeqOf reads the high-water mark of a log" {
    try testing.expectEqual(@as(u64, 0), lastSeqOf(""));
    try testing.expectEqual(@as(u64, 0), lastSeqOf("{\"type\":\"text\"}\n"));
    try testing.expectEqual(@as(u64, 7), lastSeqOf("{\"seq\":5,\"type\":\"a\"}\n{\"seq\":7,\"type\":\"b\"}\n"));
}

test "validName keeps a session name inside .graff and inside one URL segment" {
    try testing.expect(validName("a1b2c3d4e5f60718"));
    try testing.expect(validName("nightly_run-2"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("../../etc/passwd"));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("has space"));
    try testing.expect(!validName("slash/inside"));
    var long: [65]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(!validName(&long));
}

test "queryU64 + splitTarget: ?from=N off a request target" {
    const split = splitTarget("/v1/sessions/abc/events?from=12&x=y");
    try testing.expectEqualStrings("/v1/sessions/abc/events", split.path);
    try testing.expectEqual(@as(u64, 12), queryU64(split.query, "from").?);
    try testing.expect(queryU64(split.query, "missing") == null);
    const bare = splitTarget("/healthz");
    try testing.expectEqualStrings("/healthz", bare.path);
    try testing.expectEqualStrings("", bare.query);
    try testing.expect(queryU64(bare.query, "from") == null);
    try testing.expect(queryU64("from=notanumber", "from") == null);
}

test "terminalEvent + stringField: envelope reads survive a seq prefix" {
    try testing.expect(terminalEvent("{\"seq\":9,\"type\":\"turn\",\"text\":\"x\"}"));
    try testing.expect(terminalEvent("{\"seq\":9,\"type\":\"error\",\"message\":\"x\"}"));
    try testing.expect(!terminalEvent("{\"seq\":9,\"type\":\"text\",\"text\":\"x\"}"));
    try testing.expect(!terminalEvent("{\"seq\":9,\"type\":\"tool_call\",\"name\":\"bash\"}"));
    try testing.expectEqualStrings("turn", stringField("{\"seq\":1,\"type\":\"turn\"}", "type").?);
    try testing.expect(stringField("{\"seq\":1,\"type\":\"turn\"}", "missing") == null);
    // escaped quote inside the value is skipped, not treated as the terminator
    try testing.expectEqualStrings("a\\\"b", stringField("{\"text\":\"a\\\"b\"}", "text").?);
}

test "EventLog + Follower: appended lines tail without gaps or duplicates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Exactly the path serve builds, including the .graff/serve/ chain the
    // writer has to create for itself on a cold workspace.
    const path = try logPath(testing.allocator, "run-1");
    defer testing.allocator.free(path);

    var log = EventLog.open(io, tmp.dir, path);
    defer log.close();
    log.append("{\"seq\":1,\"type\":\"started\"}");
    log.append("{\"seq\":2,\"type\":\"text\",\"text\":\"a\"}");

    var buf: [4096]u8 = undefined;
    var follower = Follower.open(io, tmp.dir, path, &buf, 0);
    defer follower.close();
    var out: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    const first = try replay(&w, follower.poll(), 1);
    try testing.expectEqual(@as(usize, 2), first.emitted);
    try testing.expect(!first.terminal);

    // Nothing new: the follower yields nothing rather than replaying itself.
    try testing.expectEqualStrings("", follower.poll());

    log.append("{\"seq\":3,\"type\":\"turn\",\"text\":\"done\"}");
    var out2: [4096]u8 = undefined;
    var w2: Io.Writer = .fixed(&out2);
    const second = try replay(&w2, follower.poll(), 1);
    try testing.expectEqual(@as(usize, 1), second.emitted);
    try testing.expectEqual(@as(u64, 3), second.last_seq);
    try testing.expect(second.terminal);

    // A second process re-opening the same log appends past the tape, and the
    // on-disk high-water mark is what a fresh bridge reports to its client.
    var reopened = EventLog.open(io, tmp.dir, path);
    defer reopened.close();
    try testing.expectEqual(@as(u64, 3), lastSeqOnDisk(io, tmp.dir, testing.allocator, path));
    reopened.append("{\"seq\":4,\"type\":\"started\"}");
    try testing.expectEqual(@as(u64, 4), lastSeqOnDisk(io, tmp.dir, testing.allocator, path));
}
