//! #441: the append-only per-session transcript — the history compaction
//! discards, kept and kept greppable.
//!
//! THE FALSE PREMISE THIS CORRECTS. #438 (issue #410) added a prompt line
//! telling the model that the session file preserves what compaction throws
//! away. It does not. `.graff/sessions/<name>.session.json` is a SINGLE JSON
//! object whose `messages` array is rewritten in place: when compact() replaces
//! a hundred turns with one summary, the very next autosave overwrites the file
//! and the pre-compaction history is gone for good. Prime-agent's "grep your
//! own conversation log" property — recovering the exact wording of an error a
//! summary paraphrased — therefore had no graff equivalent. The trace and
//! trajectory JSONLs do not provide it either: they record events for
//! telemetry, not the conversation for recall.
//!
//! WHAT THIS IS. `.graff/sessions/<name>.transcript.jsonl`, one line per
//! message as it FIRST enters history, appended and never rewritten. A line is
//! that message's provider-native JSON verbatim — JSON escapes every control
//! character, so a message is always exactly one line — which makes the file
//! greppable with no tooling and re-readable with no parser state. Compaction
//! cannot touch it: it rewrites `root.messages` in memory, while every line
//! already on disk stays exactly where it was.
//!
//! WHERE IT HOOKS. session.queueSave, the point at which the autosave already
//! observes a new message. The history has ~25 mutation sites (session_writer's
//! own comment counts them); hooking each one is the hand-maintained dirty flag
//! that file rejects for the same reason. Observing the array instead costs one
//! serialization per turn — see `collect`'s fast path.
//!
//! IDENTITY. A message is already transcribed when its serialized bytes digest
//! to a line already written — counted, not positioned. `counts` is a MULTISET
//! of the digests on disk, because a rewrite reorders as well as removes:
//! compact() builds `[handoff summary] ++ recent_messages` with the tail
//! verbatim, so the summary sits at the FRONT of the history while it is the
//! LAST line in the file, and any position-based match re-appends the tail
//! behind it. Counting instead: the tail's digests are already accounted for,
//! only the summary is new. emergencyTrim drops a prefix and the survivors are
//! likewise accounted for; capOversizedToolOutputs edits a message in place,
//! and the transcript simply keeps the PRE-truncation bytes, which is the whole
//! point of it. A genuine repeat is still recorded twice: the second identical
//! "ok" is the history's SECOND, and the file holds only one.
//!
//! The one thing counting gives up, deliberately: a message identical to one
//! whose every copy compaction has already discarded is not written again. Its
//! bytes are in the file verbatim either way, so recall — what this exists for
//! — is unaffected; only exact multiplicity is, and only after a compaction.
//!
//! BOUNDS. Subagents are excluded — their history is never persisted, so there
//! is no durable session to attach a transcript to (#409's rule, unchanged).
//! The size cap ROTATES rather than head-truncates; `rotate` says why. The
//! lifecycle is #409's rather than a second one: `tool_spill.sweepSessionsOnce`
//! now reclaims transcripts and artifact dirs together, by the same rule (the
//! session file is the ground truth for "this session is gone") and the same
//! grace window.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const session_index = @import("session_index.zig");
const tool_spill = @import("tool_spill.zig"); // #409: safeName + the shared session sweep

pub const transcript_ext = session_index.transcript_ext;
pub const transcript_rotated_ext = session_index.transcript_rotated_ext;

/// Ceiling on ONE generation, so a session keeps at most twice this on disk
/// (the live file plus the one rotated generation). `pub var` so a test can
/// shrink it without writing 16 MiB.
pub var cap_bytes: usize = 16 * 1024 * 1024;

/// `.graff/sessions/<name>.transcript.jsonl`. Pure; #411's post-compaction note
/// and anything else that needs the path calls this instead of re-deriving the
/// filename.
pub fn transcriptPath(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ session_index.sessions_dir, name, transcript_ext });
}

/// The previous generation (see `rotate`), which is just as greppable.
pub fn rotatedPath(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ session_index.sessions_dir, name, transcript_rotated_ext });
}

/// The transcript path for THIS agent, or null when it has none: a subagent, a
/// name that cannot be a file, or a session no save has reached yet. #411's
/// note calls this rather than building the path itself, so it can never cite a
/// file that does not exist.
pub fn activePath(root: *Agent, arena: Allocator) ?[]const u8 {
    if (root.sub or g.total == 0) return null;
    if (g.name.len == 0 or !std.mem.eql(u8, g.name, root.session_name)) return null;
    return transcriptPath(arena, g.name) catch null;
}

/// How many messages this session's transcript is known to hold — the "N
/// messages" half of a note that cites the path. Known: a resume re-reads the
/// live generation, not the rotated one behind it.
pub fn lineCount() usize {
    return g.total;
}

/// The session currently attached and what is already on disk for it. One root
/// agent owns the durable session, so this is process state rather than agent
/// state; `attach` re-seeds it whenever the name changes (startup, /resume,
/// /new, /save <other>, the AI-title rename).
const State = struct {
    name: []const u8 = "", // a slice of name_buf; "" = nothing attached
    /// How many lines carry each digest — see IDENTITY above.
    counts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    total: usize = 0, // lines accounted for
    /// The cursor the fast path rides: this many messages of the CURRENT
    /// history are accounted for, and `anchor` is the digest the last of them
    /// had when that became true. If it still does, nothing before it moved.
    seen_len: usize = 0,
    anchor: u64 = 0,
    bytes: usize = 0, // size of the live generation on disk
};

var g: State = .{};
// Owns `g.name`'s bytes, and `g.counts` is allocated with the page allocator
// rather than the session's `gpa`, for session_writer.zig's #365 reason: this
// is PROCESS state that outlives every session in it, so charging it to the
// conversation's allocator makes the last session's state a leak at exit —
// and, in the test suite, a free across a test boundary that has already
// reclaimed the arena underneath it.
var name_buf: [256]u8 = undefined;
const state_gpa = std.heap.page_allocator;
// std.Io owns the synchronization primitives (session_writer.zig's note): the
// save path is the caller's thread, and `serve` can hold more than one session
// in a process.
var mutex: Io.Mutex = .init;

fn digest(line: []const u8) u64 {
    return std.hash.Wyhash.hash(0x441, line);
}

/// One message as it goes to disk. Serializing to the arena is the same walk
/// std.json.Stringify performs for the save itself.
fn serialize(arena: Allocator, m: Value) ?[]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(m) catch return null;
    return aw.toOwnedSlice() catch null;
}

const Line = struct { text: []const u8, hash: u64 };

fn push(arena: Allocator, out: *std.ArrayList(Line), m: Value) void {
    const text = serialize(arena, m) orelse return;
    out.append(arena, .{ .text = text, .hash = digest(text) }) catch {};
}

/// The messages in `items` that are not yet in the transcript, in order.
///
/// The fast path is the one every ordinary turn takes: the accounted-for prefix
/// is still in place — proven by re-digesting its LAST message — so everything
/// after it is new by construction. Two serializations plus one per new
/// message, instead of one per message in the whole history, every save.
///
/// The slow path runs on the first append of a session, and after a rewrite:
/// tally the history's digests in order and write a message only once its
/// running tally passes the number of lines the file already has for it.
fn collect(arena: Allocator, items: []const Value, out: *std.ArrayList(Line)) void {
    if (g.seen_len > 0 and g.seen_len <= items.len and lastMatches(arena, items[g.seen_len - 1], g.anchor)) {
        for (items[g.seen_len..]) |m| push(arena, out, m);
        return;
    }
    var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty; // arena-owned, dies with the save
    for (items) |m| {
        const text = serialize(arena, m) orelse continue;
        const h = digest(text);
        const e = seen.getOrPut(arena, h) catch return;
        e.value_ptr.* = (if (e.found_existing) e.value_ptr.* else 0) + 1;
        if (e.value_ptr.* <= (g.counts.get(h) orelse 0)) continue; // this copy is already a line
        out.append(arena, .{ .text = text, .hash = h }) catch return;
    }
}

fn lastMatches(arena: Allocator, last: Value, anchor: u64) bool {
    const text = serialize(arena, last) orelse return false;
    return digest(text) == anchor;
}

/// Append every message that is not already in this session's transcript.
/// Called from session.queueSave, after the blank-draft and unchanged-session
/// gates, so a transcript exists exactly when a durable session does.
///
/// Never fails a save: every error path is a skip. A skipped append costs a
/// duplicate line on the next one, never a lost message.
///
/// Serializes into a scratch arena of its own rather than the caller's: the
/// turn path's arena lives as long as the process (mainloop.Ctx.arena), and a
/// copy of every new message per turn parked there for the whole session would
/// double what the conversation already costs.
pub fn record(root: *Agent, dir: Io.Dir, name: []const u8) void {
    if (root.sub) return; // a subagent's history is never persisted
    if (!tool_spill.safeName(name)) return; // never write outside .graff/sessions
    if (root.messages.items.len == 0) return;
    const io = root.io;
    var scratch = std.heap.ArenaAllocator.init(root.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    attach(io, dir, arena, name);
    if (!std.mem.eql(u8, g.name, name)) return; // attach failed; try again next save
    const items = root.messages.items;
    var pending: std.ArrayList(Line) = .empty;
    collect(arena, items, &pending);
    // A batch that never reached the disk leaves the cursor alone, so the next
    // save writes it instead of stepping over it.
    if (pending.items.len > 0 and !flush(io, dir, arena, name, pending.items)) return;
    g.seen_len = items.len;
    g.anchor = if (serialize(arena, items[items.len - 1])) |text| digest(text) else 0;
}

/// Point the state at `name`, rebuilding it from disk when the session changed.
/// A resumed conversation is the case that matters: its history is restored
/// whole, and every message in it is already a line in its transcript.
fn attach(io: Io, dir: Io.Dir, arena: Allocator, name: []const u8) void {
    if (g.name.len > 0 and std.mem.eql(u8, g.name, name)) return;
    detach();
    if (name.len > name_buf.len) return; // safeName caps well below this
    @memcpy(name_buf[0..name.len], name);
    g.name = name_buf[0..name.len];
    // #409's sweep, now shared: at the first append as well as the first spill,
    // so a run that never spills still reclaims what deleted sessions left.
    tool_spill.sweepSessionsOnce(io, dir, arena, name);
    seed(io, dir, arena, name);
}

fn detach() void {
    g.counts.deinit(state_gpa);
    g = .{};
}

/// Read back the digests of the lines already in the live generation. Exact,
/// because a line IS the serialized message: hashing the line bytes reproduces
/// the digest the writer recorded. An unreadable file seeds nothing, which
/// costs duplicated lines and never a lost one.
fn seed(io: Io, dir: Io.Dir, arena: Allocator, name: []const u8) void {
    const path = transcriptPath(arena, name) catch return;
    const data = dir.readFileAlloc(io, path, arena, .limited(cap_bytes)) catch return;
    g.bytes = data.len;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue; // the trailing newline, or a torn write
        bump(digest(line));
    }
}

fn bump(h: u64) void {
    const e = g.counts.getOrPut(state_gpa, h) catch return;
    e.value_ptr.* = (if (e.found_existing) e.value_ptr.* else 0) + 1;
    g.total += 1;
}

fn flush(io: Io, dir: Io.Dir, arena: Allocator, name: []const u8, pending: []const Line) bool {
    var buf: std.ArrayList(u8) = .empty;
    for (pending) |line| {
        buf.appendSlice(arena, line.text) catch return false;
        buf.append(arena, '\n') catch return false;
    }
    if (g.bytes +| buf.items.len > cap_bytes) rotate(io, dir, arena, name);
    const path = transcriptPath(arena, name) catch return false;
    const size = appendWhole(io, dir, path, buf.items) orelse return false;
    g.bytes = size;
    for (pending) |line| bump(line.hash); // only now: these bytes are on disk
    return true;
}

/// ONE positional write at the current end of file (playbook.appendLine's and
/// serve_events.EventLog's shape). Nothing already in the file is read, moved
/// or rewritten — that is the whole append-only guarantee, and it is why a
/// compaction running against the same session cannot cost the transcript a
/// byte. Returns the new size.
fn appendWhole(io: Io, dir: Io.Dir, path: []const u8, data: []const u8) ?usize {
    dir.createDirPath(io, session_index.sessions_dir) catch {};
    const f = dir.createFile(io, path, .{ .truncate = false }) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    f.writePositionalAll(io, data, st.size) catch return null;
    return @as(usize, @intCast(st.size)) + data.len;
}

/// At the cap the live generation is RENAMED aside, never trimmed in place.
///
/// Head-truncation would mean reading the file, dropping a prefix and writing
/// what is left back over it — an in-place rewrite of the history, which is
/// precisely the failure mode this file exists to fix, and one a crash halfway
/// through turns into total loss. A rename is a single atomic syscall: the old
/// bytes survive intact under a sibling name the model greps exactly like the
/// live one, every line ever written stays a line somewhere, and the bound is
/// simply two generations. The previous generation is what the next rotation
/// replaces, so disk use is capped rather than merely slowed.
fn rotate(io: Io, dir: Io.Dir, arena: Allocator, name: []const u8) void {
    const live = transcriptPath(arena, name) catch return;
    const prev = rotatedPath(arena, name) catch return;
    dir.rename(live, dir, prev, io) catch return;
    g.bytes = 0;
    // The digests stay: they identify messages, not file offsets, so a message
    // already in the rotated generation is still not re-appended to the live one.
}

pub fn resetForTest() void {
    detach();
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn msg(arena: Allocator, role: []const u8, text: []const u8) !Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "role", .{ .string = role });
    try o.put(arena, "content", .{ .string = text });
    return .{ .object = o };
}

/// The fields `record` reads, and nothing else.
fn agentFor(gpa: Allocator, arena: Allocator, io: Io, name: []const u8) Agent {
    var root: Agent = undefined;
    root.gpa = gpa;
    root.io = io;
    root.sub = false;
    root.session_name = name;
    root.messages = std.json.Array.init(arena);
    return root;
}

fn readTranscript(dir: Io.Dir, gpa: Allocator, rel: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, rel, gpa, .limited(1 << 20));
}

fn countLines(data: []const u8) usize {
    return std.mem.count(u8, data, "\n");
}

test "one line per message, however many times the autosave runs (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "s");
    try root.messages.append(try msg(a, "user", "why did the build fail?"));
    record(&root, tmp.dir, "s");
    // The autosave runs again over an unchanged history: no second line.
    record(&root, tmp.dir, "s");
    record(&root, tmp.dir, "s");
    const one = try readTranscript(tmp.dir, gpa, ".graff/sessions/s.transcript.jsonl");
    defer gpa.free(one);
    try testing.expectEqual(@as(usize, 1), countLines(one));
    try testing.expect(std.mem.indexOf(u8, one, "why did the build fail?") != null);

    // A new turn adds exactly its own lines.
    try root.messages.append(try msg(a, "assistant", "error: undefined symbol GRAFF_441"));
    record(&root, tmp.dir, "s");
    record(&root, tmp.dir, "s");
    const two = try readTranscript(tmp.dir, gpa, ".graff/sessions/s.transcript.jsonl");
    defer gpa.free(two);
    try testing.expectEqual(@as(usize, 2), countLines(two));
    // Append-only at the byte level: the first line is untouched where it was.
    try testing.expect(std.mem.startsWith(u8, two, one));

    // A genuine repeat is a real message, not a duplicate: forward-only
    // matching must not swallow it.
    try root.messages.append(try msg(a, "user", "why did the build fail?"));
    record(&root, tmp.dir, "s");
    const three = try readTranscript(tmp.dir, gpa, ".graff/sessions/s.transcript.jsonl");
    defer gpa.free(three);
    try testing.expectEqual(@as(usize, 3), countLines(three));
}

test "compaction discards the history; the transcript still has it (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "c");
    // The exact wording that a summary would paraphrase away.
    const detail = "ld: symbol(s) not found for architecture arm64: _graff_441_probe";
    try root.messages.append(try msg(a, "user", "build it"));
    try root.messages.append(try msg(a, "tool", detail));
    try root.messages.append(try msg(a, "assistant", "fixing the link order"));
    try root.messages.append(try msg(a, "user", "and now?"));
    record(&root, tmp.dir, "c");
    const before = try readTranscript(tmp.dir, gpa, ".graff/sessions/c.transcript.jsonl");
    defer gpa.free(before);
    try testing.expectEqual(@as(usize, 4), countLines(before));

    // compact()'s shape: a fresh array of [handoff summary] ++ the recent
    // suffix verbatim. The detail is now unreachable from `messages` — the very
    // next autosave rewrites the session file without it.
    const tail = root.messages.items[3];
    var fresh = std.json.Array.init(a);
    try fresh.append(try msg(a, "user", "[summary] we were fixing a link error"));
    try fresh.append(tail);
    root.messages = fresh;
    record(&root, tmp.dir, "c");

    const after = try readTranscript(tmp.dir, gpa, ".graff/sessions/c.transcript.jsonl");
    defer gpa.free(after);
    // (a) every earlier line survived, byte for byte, in place
    try testing.expect(std.mem.startsWith(u8, after, before));
    // (b) the discarded detail is still greppable
    try testing.expect(std.mem.indexOf(u8, after, detail) != null);
    // (c) only the summary was added — the verbatim tail is not duplicated
    try testing.expectEqual(@as(usize, 5), countLines(after));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "and now?"));
    try testing.expect(std.mem.indexOf(u8, after, "[summary] we were fixing") != null);

    // And the turn after the compaction keeps appending normally.
    try root.messages.append(try msg(a, "assistant", "linked clean"));
    record(&root, tmp.dir, "c");
    const later = try readTranscript(tmp.dir, gpa, ".graff/sessions/c.transcript.jsonl");
    defer gpa.free(later);
    try testing.expectEqual(@as(usize, 6), countLines(later));
    try testing.expect(std.mem.startsWith(u8, later, after));
}

test "a resumed session does not re-append its restored history (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "r");
    try root.messages.append(try msg(a, "user", "first"));
    try root.messages.append(try msg(a, "assistant", "second"));
    record(&root, tmp.dir, "r");

    // A new process resumes "r": same history, no in-memory state at all. The
    // digests are re-seeded from the file, so nothing is written twice.
    resetForTest();
    record(&root, tmp.dir, "r");
    const data = try readTranscript(tmp.dir, gpa, ".graff/sessions/r.transcript.jsonl");
    defer gpa.free(data);
    try testing.expectEqual(@as(usize, 2), countLines(data));
    try testing.expectEqual(@as(usize, 2), lineCount());
    // The accessor #411 uses answers for the attached session only.
    try testing.expectEqualStrings(".graff/sessions/r.transcript.jsonl", activePath(&root, a).?);
    root.session_name = "somewhere-else";
    try testing.expect(activePath(&root, a) == null);
}

test "a subagent writes no transcript (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "sub-session");
    root.sub = true;
    try root.messages.append(try msg(a, "user", "delegated mandate"));
    record(&root, tmp.dir, "sub-session");
    try testing.expect(tmp.dir.statFile(io, ".graff/sessions/sub-session.transcript.jsonl", .{}) == error.FileNotFound);
    try testing.expect(activePath(&root, a) == null);

    // A name that could escape the sessions dir writes nothing either.
    root.sub = false;
    record(&root, tmp.dir, "../escape");
    try testing.expectEqual(@as(usize, 0), lineCount());
}

test "the size cap rotates the generation instead of rewriting it (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    const saved_cap = cap_bytes;
    defer {
        cap_bytes = saved_cap;
        resetForTest();
    }
    cap_bytes = 400;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = agentFor(gpa, a, io, "rot");
    try root.messages.append(try msg(a, "user", "the oldest thing said, worth keeping"));
    record(&root, tmp.dir, "rot");
    const first = try readTranscript(tmp.dir, gpa, ".graff/sessions/rot.transcript.jsonl");
    defer gpa.free(first);

    // Enough turns to pass the cap.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try root.messages.append(try msg(a, "assistant", "0123456789012345678901234567890123456789"));
        record(&root, tmp.dir, "rot");
    }

    // The previous generation holds the old bytes UNCHANGED — nothing was read,
    // trimmed and written back — and the oldest line is still greppable there.
    const prev = try readTranscript(tmp.dir, gpa, ".graff/sessions/rot.transcript.1.jsonl");
    defer gpa.free(prev);
    try testing.expect(std.mem.startsWith(u8, prev, first));
    try testing.expect(std.mem.indexOf(u8, prev, "the oldest thing said") != null);
    // Both generations respect the cap, so the session is bounded at 2x it.
    try testing.expect(prev.len <= cap_bytes);
    const live = try readTranscript(tmp.dir, gpa, ".graff/sessions/rot.transcript.jsonl");
    defer gpa.free(live);
    try testing.expect(live.len > 0 and live.len <= cap_bytes);
    // Rotation is a file operation, not an identity reset: the messages already
    // written are still not re-appended to the fresh generation.
    const lines_before = lineCount();
    record(&root, tmp.dir, "rot");
    try testing.expectEqual(lines_before, lineCount());
}
