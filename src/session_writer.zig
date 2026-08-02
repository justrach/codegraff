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
//!      matches the last SUCCESSFUL write, the save is skipped whole — no
//!      serialize, no lock, no write. Hashing the live JSON tree is a pointer
//!      walk plus a memcpy-speed digest; std.json.Stringify allocates, escapes,
//!      and formats every byte, so the skip is far cheaper than the save it
//!      replaces.
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

    fn deinit(job: Job, gpa: Allocator) void {
        gpa.free(job.path);
        gpa.free(job.data);
    }
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
var mark: ?u64 = null; // fingerprint of the newest state written or queued
var last_error: ?anyerror = null;
var writes: usize = 0;
var superseded: usize = 0;
/// Test seam: hold the worker before it claims a job, so a test can prove a
/// save really was queued (and really was superseded) rather than racing it.
/// `stop()` clears it — shutdown always wins over a test pause.
var paused = false;

/// True when `fp` is already on disk (or queued to be, and nothing has failed
/// since). The caller then skips serializing entirely.
pub fn alreadySaved(fp: u64) bool {
    const io = writer_io orelse return false; // nothing has ever been saved
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return if (mark) |m| m == fp else false;
}

/// Queue `data` for `dir`/`path`, superseding any still-queued save. Takes
/// ownership of both slices (freed with `gpa` once written or superseded), so
/// it cannot fail and leave the caller unsure who owns them: a write failure is
/// recorded for `takeError` instead of returned. Falls back to the pre-#273
/// inline write when no thread can be spawned.
pub fn submit(gpa: Allocator, io: Io, dir: Io.Dir, path: []u8, data: []u8, fp: u64) void {
    writer_io = io; // set before anything can be queued; see writer_io
    mutex.lockUncancelable(io);
    if (thread == null and !stopping) thread = std.Thread.spawn(.{}, worker, .{io}) catch null;
    if (thread == null) {
        // No worker — threads are unavailable, or one is being retired. Write
        // inline rather than queue behind nobody.
        mutex.unlock(io);
        defer gpa.free(path);
        defer gpa.free(data);
        writeNow(io, dir, path, data, fp);
        return;
    }
    defer mutex.unlock(io);
    if (pending) |old| {
        old.deinit(gpa_of_pending);
        superseded += 1;
    }
    gpa_of_pending = gpa;
    pending = .{ .io = io, .dir = dir, .path = path, .data = data };
    mark = fp;
    work.broadcast(io);
}

/// The pre-#273 write, used when threads are unavailable.
fn writeNow(io: Io, dir: Io.Dir, path: []const u8, data: []const u8, fp: u64) void {
    var failed: ?anyerror = null;
    session_lock.writeSession(io, dir, path, data) catch |err| {
        failed = err;
    };
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (failed) |err| {
        last_error = err;
        mark = null;
    } else {
        mark = fp;
        writes += 1;
    }
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
        job.deinit(gpa);

        mutex.lockUncancelable(io);
        busy = false;
        if (failed) |err| {
            last_error = err;
            // Nothing is on disk for this state: make the next save write
            // again instead of skipping on a fingerprint that never landed.
            mark = null;
        } else writes += 1;
        idle.broadcast(io);
        mutex.unlock(io);
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

/// The last write failure, cleared as it is read. Background failures cannot
/// be returned to the caller that queued them, so the next synchronous save
/// reports them instead — /save and the exit save still print a real error.
pub fn takeError() ?anyerror {
    const io = writer_io orelse return null;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    defer last_error = null;
    return last_error;
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
    mark = null;
    last_error = null;
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

    submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/a.json"), try gpa.dupe(u8, "{\"m\":1}"), 1);
    drain();
    try expectFile(tmp.dir, "s/a.json", "{\"m\":1}");
    try std.testing.expectEqual(@as(usize, 1), stats().writes);
    // The write landed, so an identical save is now skippable.
    try std.testing.expect(alreadySaved(1));
    try std.testing.expect(!alreadySaved(2));
}

test "a newer save supersedes an older queued one (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    setPausedForTest(io, true);
    submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/b.json"), try gpa.dupe(u8, "old"), 1);
    submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/b.json"), try gpa.dupe(u8, "newest"), 2);
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
    submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/c.json"), try gpa.dupe(u8, "last turn"), 7);
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
    submit(gpa, io, tmp.dir, try gpa.dupe(u8, "blocked/d.json"), try gpa.dupe(u8, "x"), 5);
    drain();
    try std.testing.expectEqual(@as(usize, 0), stats().writes);
    try std.testing.expect(!alreadySaved(5)); // never skip on a write that failed
    try std.testing.expect(takeError() != null);
    try std.testing.expect(takeError() == null); // reported once
}
