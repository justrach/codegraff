//! #273: the autosave's *disk write*, moved off the turn's critical path, plus
//! the content fingerprint that lets an unchanged conversation skip the save
//! entirely.
//!
//! Every finished turn rewrote the whole retained history synchronously before
//! the loop could accept the next prompt, so next-prompt readiness scaled with
//! the total session size instead of with the new turn. Two conservative fixes,
//! no format change and no journal:
//!
//!   1. `Fingerprint` hashes exactly the state saveSession serializes (minus
//!      `updated_ms`, which is a clock reading, not conversation state). When it
//!      matches the last SUCCESSFUL write *and the file still holds that write*
//!      (`Mark`), the save is skipped whole — no serialize, no lock, no write.
//!      Hashing the live JSON tree is a pointer walk plus a memcpy-speed digest;
//!      std.json.Stringify allocates, escapes, and formats every byte, so the
//!      skip is far cheaper than the save it replaces. The disk check is what
//!      keeps the skip from becoming a silent data loss when something else
//!      rewrites the session file between our saves.
//!   2. The serialized bytes are handed to ONE background writer thread that
//!      performs the identical `session_lock.writeSession` (parent dirs +
//!      exclusive advisory lock + positional overwrite + truncate, #289). Only
//!      one job is ever queued: a newer save supersedes an older queued one, so
//!      a burst of saves costs one write, always of the newest state.
//!
//! Serialization stays on the CALLER thread on purpose. `root.messages` is live
//! agent state with no lock of its own; serializing it on the writer thread
//! would race the next turn's appends for a real correctness bug, and the
//! alternative (deep-cloning a multi-MB history per turn) costs more than the
//! serialization it moves. Only the file write — the part that touches the disk
//! and cannot touch agent state — runs in the background.
//!
//! Measured (ReleaseFast, macOS/APFS, warm cache; std.json.Stringify vs the
//! locked write vs this fingerprint, per save):
//!
//!     100 KiB history   serialize 0.14 ms   write 0.08 ms   fingerprint 0.01 ms
//!       1 MiB history   serialize 0.94 ms   write 0.24 ms   fingerprint 0.07 ms
//!      10 MiB history   serialize 7.04 ms   write 1.10 ms   fingerprint 0.59 ms
//!
//! So be honest about what moved: the serialize is 62-87% of a save's cost and
//! is STILL on the turn's path when the conversation changed; backgrounding the
//! write buys the remaining 13-38%. The large win is the skip — an unchanged
//! session now costs the fingerprint alone, ~7% of one save at 10 MiB. Taking
//! the serialize off the path too needs either a lock around the history or an
//! incremental/journal format, both out of scope here (#273 asks for the
//! conservative step).
//!
//! Durability is bounded by `drain()`: the interactive loop drains before
//! returning, and every non-turn saver (session.saveSession) drains as part of
//! the save. So the only window in which a queued write can be lost is inside a
//! single turn's tail, and nothing exits the process through it.
//!
//! Failures are reported per save, not per process: `submit` returns a ticket
//! and `errorFor(ticket)` answers for that save alone. A background autosave's
//! failure belongs to the turn that queued it — charging it to whatever save
//! happened to ask next made `/save` report a failure for a file it had just
//! written correctly.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const session_lock = @import("session_lock.zig");

/// A digest of everything the session file records about the conversation.
/// Content-derived, so a skip can never be wrong about "nothing changed" the
/// way a hand-maintained dirty flag can: the history has ~25 production
/// mutation sites (appends, compaction rewrites, in-place repairs), and one
/// missed site would silently drop a turn from disk.
pub const Fingerprint = struct {
    h: std.hash.Wyhash,

    pub fn init() Fingerprint {
        return .{ .h = std.hash.Wyhash.init(0x2735e5510) };
    }

    pub fn num(self: *Fingerprint, v: u64) void {
        var le: [8]u8 = undefined;
        std.mem.writeInt(u64, &le, v, .little);
        self.h.update(&le);
    }

    pub fn signed(self: *Fingerprint, v: i64) void {
        self.num(@bitCast(v));
    }

    pub fn flag(self: *Fingerprint, v: bool) void {
        self.h.update(&[_]u8{@intFromBool(v)});
    }

    /// Length-prefixed: "ab"+"c" must not collide with "a"+"bc".
    pub fn text(self: *Fingerprint, s: []const u8) void {
        self.num(s.len);
        self.h.update(s);
    }

    /// The same tree std.json.Stringify would walk, digested instead of
    /// formatted. Object fields are hashed in insertion order, which is the
    /// order they are serialized in.
    pub fn json(self: *Fingerprint, v: Value) void {
        self.h.update(&[_]u8{@intFromEnum(std.meta.activeTag(v))});
        switch (v) {
            .null => {},
            .bool => |b| self.flag(b),
            .integer => |i| self.signed(i),
            .float => |f| self.num(@bitCast(f)),
            .number_string, .string => |s| self.text(s),
            .array => |a| {
                self.num(a.items.len);
                for (a.items) |item| self.json(item);
            },
            .object => |o| {
                self.num(o.count());
                var it = o.iterator();
                while (it.next()) |e| {
                    self.text(e.key_ptr.*);
                    self.json(e.value_ptr.*);
                }
            },
        }
    }

    pub fn final(self: *Fingerprint) u64 {
        return self.h.final();
    }
};

const Job = struct {
    io: Io,
    dir: Io.Dir,
    path: []u8,
    data: []u8,
    fp: u64,
    /// The `submit` that queued this job — see `errorFor`.
    ticket: u64,

    fn deinit(job: Job, gpa: Allocator) void {
        gpa.free(job.path);
        gpa.free(job.data);
    }
};

/// Evidence that one fingerprint is on disk RIGHT NOW. Not "we wrote it once":
/// the file we wrote it to, plus that file's identity (inode), length and mtime
/// as observed the instant after the write. A fingerprint alone only records
/// what THIS process last serialized, and the session file is shared — a second
/// graff in the same workspace (#289) writes its own snapshot the moment our
/// lock is released, and an `rm`/editor/restore can replace it just as easily.
/// Skipping on the fingerprint alone would then skip forever over a file that
/// no longer holds this conversation, including on the exit save.
const Mark = struct {
    fp: u64,
    path: []const u8, // borrowed until setMark copies it into mark_path_buf
    inode: Io.File.INode,
    size: u64,
    mtime_ns: i96,
};

/// Counters for the tests: how many background writes completed, and how many
/// queued jobs a newer save superseded before they ever reached the disk.
pub const Stats = struct { writes: usize, superseded: usize };

// std.Io owns the synchronization primitives (there is no std.Thread.Mutex),
// so every lock/wait needs an Io. The first submit records the session's, and
// nothing can be queued before that — a caller arriving earlier finds an empty
// queue and returns. The uncancelable variants are deliberate: the writer
// thread is not one of the Io runtime's, and a cancelation point on the
// autosave path would be a way to lose a save.
var writer_io: ?Io = null;
var mutex: Io.Mutex = .init;
var work: Io.Condition = .init; // worker: something to write, or stop
var idle: Io.Condition = .init; // drainers: the queue went quiet
var pending: ?Job = null;
var gpa_of_pending: Allocator = undefined;
var busy = false;
var stopping = false;
var thread: ?std.Thread = null;
var mark: ?Mark = null; // the newest state PROVEN to be on disk
// Owns mark.path's bytes. Static on purpose (#365): a gpa-owned path made the
// FINAL mark of every session leak at exit — production retires the worker
// with drain(), which must not clear skip evidence, so nothing ever freed it.
var mark_path_buf: [1024]u8 = undefined;
var tickets: u64 = 0; // the last ticket handed out by submit
var last_error: ?anyerror = null; // the NEWEST write's failure, if it failed
var error_ticket: u64 = 0; // and whose failure that is
var writes: usize = 0;
var superseded: usize = 0;
/// Test seam: hold the worker before it claims a job, so a test can prove a
/// save really was queued (and really was superseded) rather than racing it.
/// `stop()` clears it — shutdown always wins over a test pause.
var paused = false;

/// True when `dir`/`path` still holds exactly the bytes we last wrote for `fp`,
/// so the caller can skip serializing entirely.
///
/// The check is against the FILE, not against our memory of it: the mark is
/// trusted only while the session file is still the same inode, at the same
/// length, with the same mtime we saw right after writing it. Anything else —
/// another graff's snapshot, a delete, a hand edit — invalidates the mark, and
/// the save goes through and repairs the file instead of silently no-opping.
pub fn alreadySaved(io: Io, dir: Io.Dir, path: []const u8, fp: u64) bool {
    const wio = writer_io orelse return false; // nothing has ever been saved
    mutex.lockUncancelable(wio);
    defer mutex.unlock(wio);
    const m = mark orelse return false;
    if (m.fp != fp or !std.mem.eql(u8, m.path, path)) return false;
    const st = dir.statFile(io, path, .{}) catch {
        clearMark(); // gone or unreadable: never skip over a file we cannot see
        return false;
    };
    if (st.inode != m.inode or st.size != m.size or st.mtime.nanoseconds != m.mtime_ns) {
        clearMark(); // someone else's bytes are in the file now
        return false;
    }
    return true;
}

/// Queue `data` for `dir`/`path`, superseding any still-queued save. Takes
/// ownership of both slices (freed with `gpa` once written or superseded), so
/// it cannot fail and leave the caller unsure who owns them: a write failure is
/// recorded against the returned ticket instead of returned. Falls back to the
/// pre-#273 inline write when no thread can be spawned.
///
/// The returned ticket identifies THIS save. After `drain()`, `errorFor(ticket)`
/// answers for it and for nothing else.
pub fn submit(gpa: Allocator, io: Io, dir: Io.Dir, path: []u8, data: []u8, fp: u64) u64 {
    writer_io = io; // set before anything can be queued; see writer_io
    mutex.lockUncancelable(io);
    if (thread == null and !stopping) thread = std.Thread.spawn(.{}, worker, .{io}) catch null;
    tickets += 1;
    const ticket = tickets;
    if (thread == null) {
        // No worker — threads are unavailable, or one is being retired. Write
        // inline rather than queue behind nobody.
        mutex.unlock(io);
        defer gpa.free(path);
        defer gpa.free(data);
        writeNow(io, dir, path, data, fp, ticket);
        return ticket;
    }
    defer mutex.unlock(io);
    if (pending) |old| {
        old.deinit(gpa_of_pending);
        superseded += 1;
    }
    gpa_of_pending = gpa;
    pending = .{ .io = io, .dir = dir, .path = path, .data = data, .fp = fp, .ticket = ticket };
    work.broadcast(io);
    return ticket;
}

/// The pre-#273 write, used when threads are unavailable.
fn writeNow(io: Io, dir: Io.Dir, path: []const u8, data: []const u8, fp: u64, ticket: u64) void {
    var failed: ?anyerror = null;
    session_lock.writeSession(io, dir, path, data) catch |err| {
        failed = err;
    };
    const evidence: ?Mark = if (failed == null) observe(io, dir, path, fp) else null;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    finish(failed, ticket, evidence);
}

/// What the file looks like immediately after a successful write. Null when
/// that cannot be observed (the stat fails, or the path cannot be kept): no
/// evidence means no skip, which costs a redundant write and never a lost one.
fn observe(io: Io, dir: Io.Dir, path: []const u8, fp: u64) ?Mark {
    const st = dir.statFile(io, path, .{}) catch return null;
    return .{
        .fp = fp,
        .path = path, // borrowed — setMark copies it under the mutex
        .inode = st.inode,
        .size = st.size,
        .mtime_ns = st.mtime.nanoseconds,
    };
}

fn clearMark() void {
    mark = null;
}

fn setMark(m: Mark) void {
    mark = null;
    // An oversized path keeps no evidence — the next save writes again, which
    // costs a redundant write and never a lost one (same rule as observe).
    if (m.path.len > mark_path_buf.len) return;
    @memcpy(mark_path_buf[0..m.path.len], m.path);
    var kept = m;
    kept.path = mark_path_buf[0..m.path.len];
    mark = kept;
}

/// Record one write's outcome; the mutex is held. `last_error` always describes
/// the NEWEST write, so a success wipes an older failure (the disk is current
/// again) and no save is ever blamed for a failure that predates it.
fn finish(failed: ?anyerror, ticket: u64, evidence: ?Mark) void {
    clearMark();
    if (failed) |err| {
        last_error = err;
        error_ticket = ticket;
        // Nothing is on disk for this state: the cleared mark makes the next
        // save write again instead of skipping on a write that never landed.
        return;
    }
    writes += 1;
    last_error = null;
    error_ticket = 0;
    if (evidence) |m| setMark(m);
}

fn worker(io: Io) void {
    while (true) {
        mutex.lockUncancelable(io);
        while (!stopping and (pending == null or paused)) work.waitUncancelable(io, &mutex);
        const job = pending orelse {
            mutex.unlock(io); // stopping with an empty queue: nothing was lost
            return;
        };
        const gpa = gpa_of_pending;
        pending = null;
        busy = true;
        mutex.unlock(io);

        var failed: ?anyerror = null;
        session_lock.writeSession(job.io, job.dir, job.path, job.data) catch |err| {
            failed = err;
        };
        const evidence: ?Mark = if (failed == null) observe(job.io, job.dir, job.path, job.fp) else null;

        mutex.lockUncancelable(io);
        busy = false;
        finish(failed, job.ticket, evidence);
        idle.broadcast(io);
        mutex.unlock(io);
        // evidence.path borrowed job.path until setMark copied it under the
        // mutex above — only now is the job safe to free (#365).
        job.deinit(gpa);
    }
}

/// Block until every queued save has been written. Called before the
/// interactive loop returns and by every synchronous saver.
pub fn drain() void {
    const io = writer_io orelse return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (thread == null) return;
    while (pending != null or busy) idle.waitUncancelable(io, &mutex);
}

/// The failure of the save that `submit` gave `ticket` to, cleared as it is
/// read. Call it after `drain()`.
///
/// Scoped to the ticket on purpose. A background autosave's failure belongs to
/// the turn that queued it, not to the next synchronous save: reporting turn 5's
/// lost flock race as `/save release-notes`'s own failure made the command print
/// "save failed" and skip the rename, for a file it had just written correctly.
/// A ticket is answered by its own write, or by a newer one that superseded or
/// followed it and failed in its place — then this state is not on disk either.
pub fn errorFor(ticket: u64) ?anyerror {
    if (ticket == 0) return null; // this caller queued nothing; nothing to report
    const io = writer_io orelse return null;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const err = last_error orelse return null;
    if (error_ticket < ticket) return null; // an older save's failure, not ours
    last_error = null;
    error_ticket = 0;
    return err;
}

pub fn stats() Stats {
    const io = writer_io orelse return .{ .writes = 0, .superseded = 0 };
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return .{ .writes = writes, .superseded = superseded };
}

/// Drain, then retire the worker thread. Tests use it; production relies on
/// `drain()` (the parked worker owns nothing once the queue is empty).
pub fn stop() void {
    const io = writer_io orelse return;
    mutex.lockUncancelable(io);
    paused = false; // shutdown outranks a test pause
    work.broadcast(io);
    while (pending != null or busy) idle.waitUncancelable(io, &mutex);
    const t = thread;
    if (t != null) {
        stopping = true;
        work.broadcast(io);
    }
    mutex.unlock(io);
    if (t) |joinable| joinable.join();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    thread = null;
    stopping = false;
}

/// Test seam (see `paused`).
pub fn setPausedForTest(io: Io, v: bool) void {
    writer_io = io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    paused = v;
    work.broadcast(io);
}

/// Full reset between tests: the writer is a process global, so a leftover
/// `mark` from another test would silently skip a save under test.
pub fn resetForTest() void {
    stop();
    const io = writer_io orelse return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (pending) |old| old.deinit(gpa_of_pending);
    pending = null;
    clearMark();
    tickets = 0;
    last_error = null;
    error_ticket = 0;
    writes = 0;
    superseded = 0;
    paused = false;
}

test "fingerprint tracks every mutation the session file records (#273)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    var user: std.json.ObjectMap = .empty;
    try user.put(a, "role", .{ .string = "user" });
    try user.put(a, "content", .{ .string = "ship #273" });
    try msgs.append(.{ .object = user });

    const of = struct {
        fn fp(m: std.json.Array, title: []const u8) u64 {
            var f: Fingerprint = .init();
            f.text(title);
            f.json(.{ .array = m });
            return f.final();
        }
    }.fp;

    const base = of(msgs, "t");
    // Unchanged state hashes identically — this is what makes the skip safe.
    try std.testing.expectEqual(base, of(msgs, "t"));
    // A field OUTSIDE the history still counts (title, goal, todos, flags).
    try std.testing.expect(base != of(msgs, "t2"));

    // An appended turn.
    var reply: std.json.ObjectMap = .empty;
    try reply.put(a, "role", .{ .string = "assistant" });
    try reply.put(a, "content", .{ .string = "done" });
    try msgs.append(.{ .object = reply });
    const appended = of(msgs, "t");
    try std.testing.expect(base != appended);

    // An IN-PLACE edit of an existing message (compaction/truncation shape):
    // same message count, different content. A length-only or count-only dirty
    // check would miss exactly this and lose the rewrite.
    try msgs.items[0].object.put(a, "content", .{ .string = "ship #273 now" });
    try std.testing.expect(appended != of(msgs, "t"));
}

fn expectFile(dir: Io.Dir, path: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a queued save reaches disk and drain waits for it (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/a.json"), try gpa.dupe(u8, "{\"m\":1}"), 1);
    drain();
    try expectFile(tmp.dir, "s/a.json", "{\"m\":1}");
    try std.testing.expectEqual(@as(usize, 1), stats().writes);
    // The write landed, so an identical save is now skippable.
    try std.testing.expect(alreadySaved(io, tmp.dir, "s/a.json", 1));
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/a.json", 2)); // other state
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/other.json", 1)); // other file
}

test "the skip needs the bytes to still be on disk, not just to have been written (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/e.json"), try gpa.dupe(u8, "ten turns"), 3);
    drain();
    try std.testing.expect(alreadySaved(io, tmp.dir, "s/e.json", 3));

    // A second graff in the same workspace writes its own snapshot over ours
    // (#289: the lock is only held during the write). The state we would skip
    // on is no longer what the file holds, so the skip must not happen — the
    // exit save has to rewrite and win, as it did before #273.
    try tmp.dir.writeFile(io, .{ .sub_path = "s/e.json", .data = "another graff" });
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/e.json", 3));
    // Invalidated for good: not a one-shot that re-trusts itself next call.
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/e.json", 3));

    // Same for a session file that is deleted out from under us.
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/e.json"), try gpa.dupe(u8, "ten turns"), 3);
    drain();
    try std.testing.expect(alreadySaved(io, tmp.dir, "s/e.json", 3));
    try tmp.dir.deleteFile(io, "s/e.json");
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/e.json", 3));
}

test "a newer save supersedes an older queued one (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    setPausedForTest(io, true);
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/b.json"), try gpa.dupe(u8, "old"), 1);
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/b.json"), try gpa.dupe(u8, "newest"), 2);
    try std.testing.expectEqual(@as(usize, 1), stats().superseded);
    setPausedForTest(io, false);
    drain();
    // One write, of the newest state: a burst never costs a write per save.
    try std.testing.expectEqual(@as(usize, 1), stats().writes);
    try expectFile(tmp.dir, "s/b.json", "newest");
}

test "no queued save is lost at shutdown (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    setPausedForTest(io, true);
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/c.json"), try gpa.dupe(u8, "last turn"), 7);
    // Provably still queued: nothing is on disk yet.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "s/c.json", .{}));
    stop(); // the exit path: drain, then retire the worker
    try expectFile(tmp.dir, "s/c.json", "last turn");
}

test "a failed write clears the skip mark so the next save retries (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A regular file where the session directory would go: createDirPath and
    // the create both fail, so the write cannot land.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "" });
    const ticket = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "blocked/d.json"), try gpa.dupe(u8, "x"), 5);
    drain();
    try std.testing.expectEqual(@as(usize, 0), stats().writes);
    try std.testing.expect(!alreadySaved(io, tmp.dir, "blocked/d.json", 5)); // never skip on a write that failed
    try std.testing.expect(errorFor(ticket) != null);
    try std.testing.expect(errorFor(ticket) == null); // reported once
}

test "a background failure is never charged to a later save (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Turn 5's autosave loses the race and fails in the background.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "" });
    const autosave = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "blocked/f.json"), try gpa.dupe(u8, "turn 5"), 8);
    drain();

    // `/save release-notes` writes its own file, successfully. It must report
    // ITS outcome — reporting the autosave's error made /save print "save
    // failed" and skip the rename for a file it had just written correctly.
    const named = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/release-notes.json"), try gpa.dupe(u8, "everything"), 9);
    drain();
    try std.testing.expect(errorFor(named) == null);
    try expectFile(tmp.dir, "s/release-notes.json", "everything");
    // And the older ticket cannot resurrect it either: the newer write means
    // the failure no longer describes the disk.
    try std.testing.expect(errorFor(autosave) == null);
}
