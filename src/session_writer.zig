//! Session saves own immutable snapshots, never live Agent messages. New or
//! changed messages are serialized on the caller; the worker publishes ordinary
//! JSON with transactional range writes. A newer job may supersede a pending
//! save only for the same destination because every job is independently complete.
//!
//! The last committed snapshot supplies unchanged bytes only while the file's
//! identity, size and mtime still match under its write lock. External changes
//! force a full transaction. A checksummed write-ahead record makes interrupted
//! updates recoverable without treating the recall transcript as storage.
//!
//! drain() bounds asynchronous durability; stop() also frees the committed
//! snapshot and serialization cache before their allocators expire. Failures
//! remain ticket-scoped, and unchanged-state skips still require disk evidence.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const session_store = @import("session_store.zig");
const snapshots = @import("session_snapshot.zig");

pub const Fingerprint = @import("session_fingerprint.zig").Fingerprint;

const Job = struct {
    io: Io,
    dir: Io.Dir,
    path: []u8,
    data: []u8 = &.{},
    snapshot: ?snapshots.Snapshot = null,
    fp: u64,
    home: ?[]u8 = null,
    /// The `submit` that queued this job — see `errorFor`.
    ticket: u64,

    fn deinit(job: Job, gpa: Allocator) void {
        gpa.free(job.path);
        gpa.free(job.data);
        if (job.snapshot) |value| {
            var snapshot = value;
            snapshot.deinit();
        }
        if (job.home) |home| gpa.free(home);
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
pub const Stats = struct {
    writes: usize,
    superseded: usize,
    bytes_written: u64 = 0,
    journal_bytes: u64 = 0,
    delta_writes: u64 = 0,
};

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
var bytes_written: std.atomic.Value(u64) = .init(0);
var journal_bytes: std.atomic.Value(u64) = .init(0);
var delta_writes: std.atomic.Value(u64) = .init(0);
/// Test seam: hold the worker before it claims a job, so a test can prove a
/// save really was queued (and really was superseded) rather than racing it.
/// `stop()` clears it — shutdown always wins over a test pause.
var paused = false;

// Independent of the queue mutex: inline fallbacks and the worker share the
// last committed immutable snapshot, never live Agent messages.
var storage_mutex: Io.Mutex = .init;
const Committed = struct {
    snapshot: snapshots.Snapshot,
    path: []u8,
    capacity: usize,
    mark: session_store.Mark,
    fn deinit(self: Committed) void {
        self.snapshot.gpa.free(self.path);
        var snapshot = self.snapshot;
        snapshot.deinit();
    }
};
var committed: ?Committed = null;

fn clearCommitted() void {
    if (committed) |old| old.deinit();
    committed = null;
}

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
    // Disk evidence is not the future state: a different queued or active
    // snapshot could overwrite it after this caller returns.
    if (pending != null or busy) return false;
    const m = mark orelse return false;
    if (m.fp != fp or !std.mem.eql(u8, m.path, path)) return false;
    var journal_buf: [std.fs.max_path_bytes]u8 = undefined;
    const journal = std.fmt.bufPrint(&journal_buf, "{s}.journal", .{path}) catch return false;
    if (dir.statFile(io, journal, .{})) |_| return false else |err| {
        if (err != error.FileNotFound) return false;
    }
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
    return submitInHome(gpa, io, dir, path, data, fp, "");
}

/// Discovery metadata is optional; session persistence remains authoritative.
pub fn submitInHome(gpa: Allocator, io: Io, dir: Io.Dir, path: []u8, data: []u8, fp: u64, home: []const u8) u64 {
    return enqueue(gpa, .{ .io = io, .dir = dir, .path = path, .data = data, .fp = fp, .ticket = 0, .home = if (home.len > 0) gpa.dupe(u8, home) catch null else null });
}

/// Own a complete immutable snapshot; queued replacements need no prior job.
pub fn submitSnapshot(gpa: Allocator, io: Io, dir: Io.Dir, path: []u8, snapshot: snapshots.Snapshot, fp: u64, home: []const u8) u64 {
    return enqueue(gpa, .{ .io = io, .dir = dir, .path = path, .snapshot = snapshot, .fp = fp, .ticket = 0, .home = if (home.len > 0) gpa.dupe(u8, home) catch null else null });
}

fn enqueue(gpa: Allocator, incoming: Job) u64 {
    var job = incoming;
    const io = job.io;
    writer_io = io; // set before anything can be queued; see writer_io
    mutex.lockUncancelable(io);
    if (thread == null and !stopping) thread = std.Thread.spawn(.{}, worker, .{io}) catch null;
    tickets += 1;
    const ticket = tickets;
    job.ticket = ticket;
    if (thread == null) {
        // No worker — threads are unavailable, or one is being retired. Write
        // inline rather than queue behind nobody.
        mutex.unlock(io);
        defer job.deinit(gpa);
        writeNow(gpa, &job);
        return ticket;
    }
    defer mutex.unlock(io);
    if (pending) |old| {
        if (old.dir.handle != job.dir.handle or !std.mem.eql(u8, old.path, job.path)) {
            while (pending != null or busy) idle.waitUncancelable(io, &mutex);
        } else {
            old.deinit(gpa_of_pending);
            superseded += 1;
        }
    }
    gpa_of_pending = gpa;
    pending = job;
    work.broadcast(io);
    return ticket;
}

fn persist(gpa: Allocator, job: *Job) !Mark {
    storage_mutex.lockUncancelable(job.io);
    defer storage_mutex.unlock(job.io);
    const before = session_store.stats;
    const st = if (job.snapshot) |*snapshot| blk: {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var capacity = std.mem.alignForward(usize, snapshot.header_end, 4096);
        var delta: ?session_store.Delta = null;
        if (committed) |old| {
            if (std.mem.eql(u8, old.path, job.path) and snapshot.header_end <= old.capacity) {
                capacity = old.capacity;
                delta = .{ .old_parts = try old.snapshot.parts(a, capacity), .old_mark = old.mark, .prefix = capacity, .tail = snapshot.tailOffset(snapshot.commonPrefix(old.snapshot), capacity) };
            }
        }
        const st = try session_store.write(job.io, gpa, job.dir, job.path, try snapshot.parts(a, capacity), delta);
        clearCommitted();
        if (snapshot.gpa.dupe(u8, job.path)) |path| {
            committed = .{ .snapshot = snapshot.*, .path = path, .capacity = capacity, .mark = st };
            job.snapshot = null;
        } else |_| {}
        break :blk st;
    } else blk: {
        const st = try session_store.write(job.io, gpa, job.dir, job.path, &.{job.data}, null);
        clearCommitted();
        break :blk st;
    };
    _ = bytes_written.fetchAdd(session_store.stats.bytes_written - before.bytes_written, .monotonic);
    _ = journal_bytes.fetchAdd(session_store.stats.journal_bytes - before.journal_bytes, .monotonic);
    _ = delta_writes.fetchAdd(session_store.stats.delta_writes - before.delta_writes, .monotonic);
    return .{ .fp = job.fp, .path = job.path, .inode = st.inode, .size = st.size, .mtime_ns = st.mtime_ns };
}

/// The same transaction path is used when a worker cannot be started.
fn writeNow(gpa: Allocator, job: *Job) void {
    var failed: ?anyerror = null;
    const evidence = persist(gpa, job) catch |err| blk: {
        failed = err;
        break :blk null;
    };
    if (failed == null) if (job.home) |h| @import("workspace_history.zig").record(job.io, job.dir, h) catch {};
    mutex.lockUncancelable(job.io);
    defer mutex.unlock(job.io);
    finish(failed, job.ticket, evidence);
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
        var job = pending orelse {
            mutex.unlock(io); // stopping with an empty queue: nothing was lost
            return;
        };
        const gpa = gpa_of_pending;
        pending = null;
        busy = true;
        mutex.unlock(io);

        var failed: ?anyerror = null;
        const evidence = persist(gpa, &job) catch |err| blk: {
            failed = err;
            break :blk null;
        };
        if (failed == null) if (job.home) |h| @import("workspace_history.zig").record(job.io, job.dir, h) catch {};

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
    return .{ .writes = writes, .superseded = superseded, .bytes_written = bytes_written.load(.monotonic), .journal_bytes = journal_bytes.load(.monotonic), .delta_writes = delta_writes.load(.monotonic) };
}

/// Drain, retire the worker, and release retained immutable snapshot state.
/// Main calls this before its allocator expires; tests use it between cases.
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
    storage_mutex.lockUncancelable(io);
    clearCommitted();
    storage_mutex.unlock(io);
    snapshots.reset();
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
    bytes_written.store(0, .monotonic);
    journal_bytes.store(0, .monotonic);
    delta_writes.store(0, .monotonic);
    paused = false;
}

test {
    _ = @import("session_writer_tests.zig");
}
