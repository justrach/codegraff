//! #409: spill, don't truncate. The per-output cap (#193/#196) bounds any single
//! tool output before send; this is where the ORIGINAL bytes go first, so the
//! elision is addressable instead of destructive. The marker that replaces them
//! carries the ABSOLUTE path and the full byte count, so the next turn can read
//! or grep exactly the slice it needs instead of re-running the tool.
//!
//! Layout: `.graff/sessions/<session>/artifacts/tool-<n>.txt`, a sibling of that
//! session's `<session>.session.json`. Two bounds keep it from growing without
//! limit: `session_cap_bytes` per session, and reclamation of the artifact dirs
//! whose session file is gone (`sweepOnce`) — the session FILE is the ground
//! truth for "this session was deleted", so an `rm`, the AI-title rename, or a
//! `/new` all reclaim what they left behind.
//!
//! Spilling is off until `enable` wires a target, and never happens for a
//! subagent: its history is not persisted, so there is no durable session to
//! attach an artifact to and the cap stays a plain truncation.
//!
//! Also the home of the cap's truncation primitives (moved here from
//! agent_compact.zig, which sits at the 600-line cap): the spill has to happen
//! inside `truncateStrField`, the one place that still holds the pre-truncation
//! string.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const utf8Prefix = util.utf8Prefix;
const session_index = @import("session_index.zig");

/// Ceiling on what one session may leave on disk. Every artifact is a tool
/// output that ALREADY exceeded the per-output cap, so a runaway tool loop is
/// exactly the case that would otherwise fill a disk one oversized result at a
/// time. `pub var` so a test can shrink it without writing 64 MiB.
pub var session_cap_bytes: usize = 64 * 1024 * 1024;

/// How stale an orphaned artifact dir must be before it is reclaimed. A second
/// graff can spill during its first turn, before its own session file has been
/// autosaved; the grace window means that window never costs it its artifacts.
pub var orphan_grace_ms: i64 = std.time.ms_per_hour;

/// Where the artifacts go. Null until `enable` wires it, so unit tests and any
/// run without a workspace get the pre-#409 plain truncation.
pub const Sink = struct {
    io: Io,
    /// The directory `.graff` lives under: the cwd in production, a tmp dir in tests.
    dir: Io.Dir,
    /// Absolute path of `dir`. The marker names an absolute path so the model can
    /// open it from anywhere (a subagent may be running inside a worktree).
    base_abs: []const u8,
};

var g_sink: ?Sink = null;
var g_used: std.atomic.Value(usize) = .init(0);
var g_seq: std.atomic.Value(u64) = .init(0);
var g_spills: std.atomic.Value(u64) = .init(0);
var g_swept: std.atomic.Value(bool) = .init(false);

/// Artifacts written this process. The caller's user-facing note reads it so a
/// cap that PRESERVED the bytes cannot read like one that destroyed them (#202).
pub fn spillCount() u64 {
    return g_spills.load(.monotonic);
}

pub fn enable(sink: Sink) void {
    g_sink = sink;
}

pub fn resetForTest() void {
    g_sink = null;
    g_used.store(0, .monotonic);
    g_seq.store(0, .monotonic);
    g_spills.store(0, .monotonic);
    g_swept.store(false, .monotonic);
}

/// The session an agent's spills belong to, or "" for plain truncation. Only a
/// root agent has one: a subagent's history is never written to disk, which is
/// the issue's "only spill when a durable session exists".
pub fn sessionFor(sub: bool, session_name: []const u8) []const u8 {
    return if (sub) "" else session_name;
}

/// The byte-budget half of the spill decision, pure. An artifact is written
/// whole or not at all — a partial one would make the marker lie about its byte
/// count — so an output that would overrun the remaining budget is truncated the
/// old way instead.
pub fn withinBudget(used: usize, len: usize, cap: usize) bool {
    return len > 0 and used +| len <= cap;
}

/// An artifact dir is reclaimable once its session file is gone AND it is older
/// than the grace window. An unreadable mtime is never "age 0" (worktree_prune's
/// rule): it keeps the directory.
pub fn reclaimable(session_file_exists: bool, age_ms: i64, grace_ms: i64) bool {
    if (session_file_exists or age_ms < 0) return false;
    return age_ms >= grace_ms;
}

/// A session name that can only ever name a directory INSIDE `.graff/sessions`.
/// Session names reach us from /save and from AI titles; a '/' or a ".." in one
/// must never become a write outside the sessions dir.
pub fn safeName(session: []const u8) bool {
    if (session.len == 0 or session.len > 128) return false;
    if (std.mem.indexOfAny(u8, session, "/\\") != null) return false;
    return !std.mem.eql(u8, session, ".") and !std.mem.eql(u8, session, "..");
}

/// What replaces the elided bytes. `session` empty (a subagent, an unwired
/// process) means plain truncation with `fallback`.
pub const Note = struct {
    fallback: []const u8,
    session: []const u8 = "",

    /// The marker for an output of `full`, bounded by the same `cap` as the stub
    /// it goes into: a marker that cannot fit falls back to the short one rather
    /// than growing an output the cap just shrank.
    pub fn text(self: Note, arena: Allocator, full: []const u8, cap: usize) []const u8 {
        const path = spill(arena, self.session, full) orelse return self.fallback;
        const marker = std.fmt.allocPrint(arena, "[tool output truncated at this model's per-result cap — the FULL {d} bytes are at {s}; read or grep that file for the slice you need instead of re-running the tool (#409)]", .{ full.len, path }) catch return self.fallback;
        return if (marker.len + 1 > cap) self.fallback else marker;
    }
};

/// Write `full` to this session's artifact dir; the ABSOLUTE path on success.
/// Null — i.e. plain truncation — when no durable session is wired, when the
/// per-session budget is spent, or when any part of the write fails.
fn spill(arena: Allocator, session: []const u8, full: []const u8) ?[]const u8 {
    const sink = g_sink orelse return null;
    if (!safeName(session)) return null;
    if (!reserve(full.len)) return null;
    const dir = std.fmt.allocPrint(arena, "{s}/{s}/artifacts", .{ session_index.sessions_dir, session }) catch return refund(full.len);
    sweepOnce(sink, arena, session);
    sink.dir.createDirPath(sink.io, dir) catch return refund(full.len);
    const seq = g_seq.fetchAdd(1, .monotonic);
    const rel = std.fmt.allocPrint(arena, "{s}/tool-{d}.txt", .{ dir, seq }) catch return refund(full.len);
    sink.dir.writeFile(sink.io, .{ .sub_path = rel, .data = full, .flags = .{ .exclusive = true } }) catch return refund(full.len);
    _ = g_spills.fetchAdd(1, .monotonic);
    return absolute(sink, arena, rel);
}

/// The path the marker hands the model. Resolved through the same dir handle the
/// artifact was written with, so it names the file that actually exists — the
/// declared `base_abs` is only a fallback, and it is derived from $PWD when the
/// cwd cannot be resolved, which a caller that inherited a stale PWD gets wrong.
fn absolute(sink: Sink, arena: Allocator, rel: []const u8) []const u8 {
    var buf: [4096]u8 = undefined;
    if (sink.dir.realPathFile(sink.io, rel, &buf)) |n| {
        return arena.dupe(u8, buf[0..n]) catch rel;
    } else |_| {}
    if (sink.base_abs.len == 0) return rel;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ sink.base_abs, rel }) catch rel;
}

fn reserve(len: usize) bool {
    const prev = g_used.fetchAdd(len, .monotonic);
    if (withinBudget(prev, len, session_cap_bytes)) return true;
    _ = g_used.fetchSub(len, .monotonic);
    return false;
}

fn refund(len: usize) ?[]const u8 {
    _ = g_used.fetchSub(len, .monotonic);
    return null;
}

/// Reclaim the artifact dirs of sessions that no longer exist. Once per process,
/// at the FIRST spill: a run that never spills does no extra I/O at all, and by
/// then this session's own dir is either current (skipped by name) or still
/// young enough for the grace window.
fn sweepOnce(sink: Sink, arena: Allocator, current: []const u8) void {
    if (g_swept.swap(true, .monotonic)) return;
    var names: std.ArrayList([]const u8) = .empty; // collect first: deleting mid-iteration is not portable
    {
        var dir = sink.dir.openDir(sink.io, session_index.sessions_dir, .{ .iterate = true }) catch return;
        defer dir.close(sink.io);
        var it = dir.iterate();
        while (it.next(sink.io) catch null) |entry| {
            if (entry.kind != .directory or std.mem.eql(u8, entry.name, current)) continue;
            names.append(arena, arena.dupe(u8, entry.name) catch continue) catch continue;
        }
    }
    const now = util.unixMs(sink.io);
    for (names.items) |name| {
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ session_index.sessions_dir, name }) catch continue;
        const file = std.fmt.allocPrint(arena, "{s}{s}", .{ path, session_index.session_ext }) catch continue;
        const live = if (sink.dir.statFile(sink.io, file, .{})) |_| true else |_| false;
        if (!reclaimable(live, ageMs(sink, path, now), orphan_grace_ms)) continue;
        sink.dir.deleteTree(sink.io, path) catch {};
    }
}

fn ageMs(sink: Sink, path: []const u8, now_ms: i64) i64 {
    const st = sink.dir.statFile(sink.io, path, .{}) catch return -1;
    const mtime_ms: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
    const age = now_ms - mtime_ms;
    return if (age < 0) 0 else age; // clock skew, not a stale artifact dir
}

/// True if `m` is a tool-output message whose payload can be truncated to
/// reclaim context: responses `function_call_output`, openai `role:"tool"`, or an
/// anthropic user message carrying `tool_result` blocks (#163).
pub fn isToolOutputMsg(m: Value) bool {
    if (m != .object) return false;
    if (m.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "function_call_output")) return true;
    if (m.object.get("role")) |r| if (r == .string) {
        if (std.mem.eql(u8, r.string, "tool")) return true;
        if (std.mem.eql(u8, r.string, "user")) if (m.object.get("content")) |c| if (c == .array)
            for (c.array.items) |blk| {
                if (blk == .object) if (blk.object.get("type")) |bt|
                    if (bt == .string and std.mem.eql(u8, bt.string, "tool_result")) return true;
            };
    };
    return false;
}

fn truncateStrField(arena: Allocator, o: *std.json.ObjectMap, key: []const u8, cap: usize, note: Note) usize {
    const v = o.get(key) orelse return 0;
    if (v != .string or v.string.len <= cap) return 0;
    const orig = v.string.len;
    // The full bytes go to an artifact first (when the session is durable), so
    // the marker below can point at them instead of only announcing the loss.
    const marker = note.text(arena, v.string, cap);
    // Keep the prefix short enough that prefix + '\n' + marker <= cap, so the
    // marker never grows an output that was only barely over the cap.
    const stub = std.fmt.allocPrint(arena, "{s}\n{s}", .{ utf8Prefix(v.string, cap -| (marker.len + 1)), marker }) catch return 0;
    o.put(arena, key, .{ .string = stub }) catch return 0;
    return orig -| stub.len;
}

/// Truncate an over-large tool-output payload in `m` in place to ~`cap` bytes,
/// preserving the message and its call/output pairing. Returns bytes reclaimed.
pub fn truncateToolOutput(arena: Allocator, m: *Value, cap: usize, note: Note) usize {
    if (m.* != .object) return 0;
    if (m.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "function_call_output"))
        return truncateStrField(arena, &m.object, "output", cap, note);
    if (m.object.get("role")) |r| if (r == .string) {
        if (std.mem.eql(u8, r.string, "tool")) return truncateStrField(arena, &m.object, "content", cap, note);
        if (std.mem.eql(u8, r.string, "user")) if (m.object.get("content")) |c| if (c == .array) {
            var saved: usize = 0;
            for (m.object.get("content").?.array.items) |*blk| {
                if (blk.* != .object) continue;
                const bt = blk.object.get("type") orelse continue;
                if (bt == .string and std.mem.eql(u8, bt.string, "tool_result"))
                    saved += truncateStrField(arena, &blk.object, "content", cap, note);
            }
            return saved;
        };
    };
    return 0;
}

test "spill decision (#409): durable session, non-empty payload, room in the budget" {
    // A subagent has no persisted history, so it has no artifact to attach to.
    try std.testing.expectEqualStrings("", sessionFor(true, "session-17"));
    try std.testing.expectEqualStrings("session-17", sessionFor(false, "session-17"));
    // All-or-nothing at the budget edge.
    try std.testing.expect(withinBudget(0, 100, 100));
    try std.testing.expect(withinBudget(90, 10, 100));
    try std.testing.expect(!withinBudget(91, 10, 100));
    try std.testing.expect(!withinBudget(0, 0, 100)); // nothing to spill
    try std.testing.expect(!withinBudget(std.math.maxInt(usize), 8, 100)); // no wraparound
    // A name that could escape .graff/sessions never becomes a directory.
    try std.testing.expect(safeName("session-1770000000000"));
    try std.testing.expect(!safeName(""));
    try std.testing.expect(!safeName("../../etc"));
    try std.testing.expect(!safeName(".."));
    try std.testing.expect(!safeName("a/b"));
}

test "reclaimable (#409): the session file is the ground truth, and an unknown age keeps" {
    try std.testing.expect(!reclaimable(true, 999_999, 0)); // session still exists
    try std.testing.expect(reclaimable(false, 3_600_000, 3_600_000)); // gone and past the grace
    try std.testing.expect(!reclaimable(false, 60_000, 3_600_000)); // gone but still young
    try std.testing.expect(!reclaimable(false, -1, 0)); // unreadable mtime keeps
}

test "no durable session (#409): the cap stays a plain truncation" {
    resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const note: Note = .{ .fallback = "[truncated]", .session = "" };
    // Unwired process AND empty session: both fall back, and neither writes.
    try std.testing.expectEqualStrings("[truncated]", note.text(a, &util.repeatBytes("x", 4096), 1024));
}

test "spill writes the full output and the marker points at it (#409)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    defer resetForTest();
    enable(.{ .io = io, .dir = tmp.dir, .base_abs = "/work" });

    const cap: usize = 1024;
    const big = try a.alloc(u8, 8192);
    @memset(big, 'x');
    big[8000] = 'N'; // a needle past the cap: only the artifact can still hold it

    var fco: std.json.ObjectMap = .empty;
    try fco.put(a, "type", .{ .string = "function_call_output" });
    try fco.put(a, "output", .{ .string = big });
    var m: Value = .{ .object = fco };
    const reclaimed = truncateToolOutput(a, &m, cap, .{ .fallback = "[truncated]", .session = "s1" });
    try std.testing.expect(reclaimed > 0);

    // (a) the artifact holds the FULL original bytes
    const rel = ".graff/sessions/s1/artifacts/tool-0.txt";
    const spilled = try tmp.dir.readFileAlloc(io, rel, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(spilled);
    try std.testing.expectEqualStrings(big, spilled);
    // (b) the capped message stays within the cap and cites path + byte count
    const stub = m.object.get("output").?.string;
    try std.testing.expect(stub.len <= cap);
    try std.testing.expect(std.mem.indexOf(u8, stub, "are at /") != null); // absolute, resolved through the dir handle
    try std.testing.expect(std.mem.indexOf(u8, stub, rel) != null);
    try std.testing.expect(std.mem.indexOf(u8, stub, "8192 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub, "truncated") != null);
    // the needle is gone from the transcript and recoverable only from the file
    try std.testing.expect(std.mem.indexOf(u8, stub, "N") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, spilled, 'N') != null);
}

test "the per-session byte cap bounds the spill, and over it the cap truncates as before (#409)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    const saved_cap = session_cap_bytes;
    defer {
        session_cap_bytes = saved_cap;
        resetForTest();
    }
    session_cap_bytes = 9000;
    enable(.{ .io = io, .dir = tmp.dir, .base_abs = "" });

    const note: Note = .{ .fallback = "[truncated]", .session = "s2" };
    const big = try a.alloc(u8, 8192);
    @memset(big, 'x');
    // First spill fits the budget; the second would overrun it whole, so it is
    // truncated the pre-#409 way rather than half-written.
    try std.testing.expect(std.mem.indexOf(u8, note.text(a, big, 1024), "tool-0.txt") != null);
    try std.testing.expectEqualStrings("[truncated]", note.text(a, big, 1024));
    try std.testing.expect(tmp.dir.statFile(io, ".graff/sessions/s2/artifacts/tool-1.txt", .{}) == error.FileNotFound);
}

test "artifacts are reclaimed with their session, and a live session keeps its own (#409)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    const saved_grace = orphan_grace_ms;
    defer {
        orphan_grace_ms = saved_grace;
        resetForTest();
    }
    orphan_grace_ms = 0; // every orphan is old enough
    enable(.{ .io = io, .dir = tmp.dir, .base_abs = "" });

    // A session that was deleted (no .session.json), one that is still saved,
    // and the one doing the spilling.
    try tmp.dir.createDirPath(io, ".graff/sessions/dead/artifacts");
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/sessions/dead/artifacts/tool-9.txt", .data = "stale" });
    try tmp.dir.createDirPath(io, ".graff/sessions/alive/artifacts");
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/sessions/alive/artifacts/tool-9.txt", .data = "keep" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/sessions/alive.session.json", .data = "{}" });

    const note: Note = .{ .fallback = "[truncated]", .session = "current" };
    try std.testing.expect(std.mem.indexOf(u8, note.text(a, &util.repeatBytes("y", 4096), 1024), "tool-0.txt") != null);

    try std.testing.expect(tmp.dir.statFile(io, ".graff/sessions/dead", .{}) == error.FileNotFound);
    _ = try tmp.dir.statFile(io, ".graff/sessions/alive/artifacts/tool-9.txt", .{});
    _ = try tmp.dir.statFile(io, ".graff/sessions/current/artifacts/tool-0.txt", .{});
}
