//! Live model catalogs never hold startup or `graff/models` past a budget.
//!
//! A cold DNS lookup or a slow TLS host could hold `initialize` for 10-40s,
//! because boot awaited every live catalog GET (Kimi always, router specs
//! whenever their cache was stale) and the `graff/models` gateway refresh
//! joined its HTTP worker on timeout. ACP clients then gave up on model
//! discovery. Catalog GETs now run on detached threads whose only output is
//! the disk cache; the caller waits at most a budget, then activates whatever
//! cache exists (fresh, stale, or none: the baked rows stay).
//!
//! A worker that misses the budget is abandoned, not cancelled: cancelling
//! still joins a thread parked in getaddrinfo (mcp_teardown.zig has the same
//! finding). It finishes on its own and leaves a fresh cache for the next
//! process. Each worker owns a private Io and allocator, so it never touches
//! the session Io or gpa after the caller moves on, and exit never waits for
//! it or tears down an Io it is still inside.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const provider = @import("provider.zig");

/// Boot waits this long for catalogs with no disk cache at all. A cached
/// catalog, fresh or stale, never waits: it activates now and refreshes behind.
pub const startup_budget: Io.Duration = .fromMilliseconds(800);

pub const Job = union(enum) {
    router: struct { spec: provider.ProviderSpec, source: provider.Keys.CredentialSource },
    kimi,
};

/// Thread-safe and independent of every caller's lifetime: an abandoned task
/// frees itself here, never into a session allocator's leak report.
const alloc = std.heap.smp_allocator;

const running: u8 = 0;
const finished: u8 = 1;
const abandoned: u8 = 2;

const Task = struct {
    state: std.atomic.Value(u8) = .init(running),
    ok: bool = false,
    job: Job,
    home: []u8,
    key: []u8,

    fn destroy(t: *Task) void {
        alloc.free(t.home);
        alloc.free(t.key);
        alloc.destroy(t);
    }

    fn run(t: *Task) void {
        var threaded = privateThreaded();
        defer threaded.deinit();
        const io = threaded.io();
        t.ok = switch (t.job) {
            .router => |r| @import("router_catalog.zig").fetchToCache(io, alloc, t.home, r.spec, t.key, r.source),
            .kimi => @import("kimi_catalog.zig").fetchToCache(io, alloc, t.home, t.key),
        };
        // The waiter gave up: nobody else will free this task.
        if (t.state.cmpxchgStrong(running, finished, .acq_rel, .acquire) != null) t.destroy();
    }
};

/// A worker's own Io. `Threaded.init` installs a process-wide no-op SIGIO and
/// SIGPIPE handler, and `deinit` restores the action it replaced. A worker
/// outlives the Io around it, so its restore can reinstate the default action
/// another Io had replaced, and that Io's next cancellation SIGIO kills the
/// process. The worker leaves the no-op handler installed instead.
fn privateThreaded() Io.Threaded {
    var threaded: Io.Threaded = .init(alloc, .{});
    threaded.have_signal_handler = false;
    return threaded;
}

fn start(job: Job, home: []const u8, key: []const u8) ?*Task {
    if (builtin.single_threaded or home.len == 0 or key.len == 0) return null;
    const t = alloc.create(Task) catch return null;
    const home_d = alloc.dupe(u8, home) catch {
        alloc.destroy(t);
        return null;
    };
    const key_d = alloc.dupe(u8, key) catch {
        alloc.free(home_d);
        alloc.destroy(t);
        return null;
    };
    t.* = .{ .job = job, .home = home_d, .key = key_d };
    const thread = std.Thread.spawn(.{}, Task.run, .{t}) catch {
        t.destroy();
        return null;
    };
    thread.detach();
    return t;
}

/// Refresh a cache behind the caller's back; nothing waits for it.
pub fn detach(job: Job, home: []const u8, key: []const u8) void {
    const t = start(job, home, key) orelse return;
    if (t.state.cmpxchgStrong(running, abandoned, .acq_rel, .acquire) != null) t.destroy();
}

pub const max_tasks = provider.provider_specs.len + 2;

/// Fetches that share one deadline: boot pays the slowest host, capped.
pub const Batch = struct {
    tasks: [max_tasks]?*Task = @splat(null),
    ok: [max_tasks]bool = @splat(false),
    len: usize = 0,

    /// Start a fetch; returns its slot, or null when it could not start (no
    /// home for a cache, no key, no thread). Its result is the cache file.
    pub fn spawn(b: *Batch, job: Job, home: []const u8, key: []const u8) ?usize {
        if (b.len == max_tasks) return null;
        const t = start(job, home, key) orelse return null;
        b.tasks[b.len] = t;
        b.len += 1;
        return b.len - 1;
    }

    /// Wait until every fetch finished or `budget` passed, then settle each:
    /// a finished one is reclaimed and its outcome kept, a late one abandoned.
    pub fn wait(b: *Batch, io: Io, budget: Io.Duration) void {
        const step: Io.Duration = .fromMilliseconds(5);
        var left = budget.nanoseconds;
        while (left > 0 and !b.allFinished()) {
            const nap: Io.Duration = .fromNanoseconds(@min(left, step.nanoseconds));
            io.sleep(nap, .awake) catch break;
            left -= nap.nanoseconds;
        }
        for (b.tasks[0..b.len], 0..) |maybe, i| {
            const t = maybe orelse continue;
            b.tasks[i] = null;
            if (t.state.cmpxchgStrong(running, abandoned, .acq_rel, .acquire) == null) continue;
            b.ok[i] = t.ok; // finished: the worker is done with `t`
            t.destroy();
        }
    }

    fn allFinished(b: *const Batch) bool {
        for (b.tasks[0..b.len]) |maybe| {
            const t = maybe orelse continue;
            if (t.state.load(.acquire) == running) return false;
        }
        return true;
    }

    /// Whether the fetch in `slot` finished in time and wrote its cache.
    pub fn fetched(b: *const Batch, slot: ?usize) bool {
        const i = slot orelse return false;
        return b.ok[i];
    }
};

/// The abandoned worker keeps reading its spec after the test returns.
var test_url_buf: [64]u8 = undefined;

test "a batch that misses its budget returns on time and abandons the fetch" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Accept the connection but never answer: the worker parks in its read.
    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var spec = provider.specFor("codegraff").?;
    spec.models_url = try std.fmt.bufPrint(&test_url_buf, "http://127.0.0.1:{d}/v1/models", .{server.socket.address.getPort()});
    const home = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var batch: Batch = .{};
    const slot = batch.spawn(.{ .router = .{ .spec = spec, .source = .environment } }, home, "test-key");
    try std.testing.expect(slot != null);
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    batch.wait(io, .fromMilliseconds(100));
    try std.testing.expect(Io.Timestamp.now(io, .awake).nanoseconds - started < std.time.ns_per_s);
    try std.testing.expect(!batch.fetched(slot));
}

test "a finished worker never reinstates the default SIGIO action" {
    const posix = std.posix;
    if (builtin.single_threaded or posix.Sigaction == void or !@hasField(posix.SIG, "IO")) return error.SkipZigTest;
    const default: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    var saved: posix.Sigaction = undefined;
    posix.sigaction(.IO, &default, &saved);
    defer posix.sigaction(.IO, &saved, null);
    // The worker starts before any other Io and finishes after one exists.
    var worker = privateThreaded();
    var session: Io.Threaded = .init(std.testing.allocator, .{});
    worker.deinit();
    var now: posix.Sigaction = undefined;
    posix.sigaction(.IO, null, &now);
    session.deinit();
    try std.testing.expect(now.handler.handler != posix.SIG.DFL);
}

test "a batch reports nothing it could not start" {
    var batch: Batch = .{};
    try std.testing.expectEqual(@as(?usize, null), batch.spawn(.kimi, "", "key"));
    try std.testing.expectEqual(@as(?usize, null), batch.spawn(.kimi, "/home", ""));
    batch.wait(std.testing.io, .fromMilliseconds(1));
    try std.testing.expect(!batch.fetched(null));
}
