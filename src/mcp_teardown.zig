//! Bounded, abandonable teardown for network-backed MCP transports (#305).
//!
//! `Registry.deinit` runs while the process is on its way out, after all
//! useful work is done, so it must never wait on a remote peer. stdio
//! children are already bounded (mcp_stdio.stopChild kills a slow child);
//! the Streamable HTTP transport had no such bound, and a stalled TLS
//! connection could hold session exit for over a minute on a slow or
//! restricted network. Teardown here runs on a detached thread under a hard
//! deadline: a transport that outlives the deadline is *abandoned* — its
//! state is deliberately leaked and the exiting process moves on. Nothing
//! useful is lost; the process is exiting.
//!
//! Two consequences of abandoning, both deliberate and both bounded to the
//! stalled-peer path:
//!   - The detached thread still holds the `Io` it was given, and it can
//!     outlive the caller's teardown of that Io. It is parked in the syscall
//!     that made it miss the deadline, so in practice it never returns to touch
//!     Io state before the process dies - but that is a race, not a proof, and
//!     it is why Registry.deinit belongs as late in the exit path as possible.
//!     Nothing here may be reused for mid-session teardown on a live Io.
//!   - The client's pool memory is never freed, so a leak-checking allocator
//!     reports it at exit. That is the trade #305 asks for: a leak line in a
//!     debug build beats a minute of hanging in a user's terminal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Hard bound on one transport's teardown. Generous next to a healthy
/// teardown (freeing a connection pool is a handful of syscalls), nothing
/// next to the minute-plus a dead peer can cost (#305).
pub const teardown_grace = Io.Duration.fromSeconds(1);

const poll_step = Io.Duration.fromMilliseconds(5);

/// Set when runBounded gives up on a task. That thread is detached, still holds
/// the `Io` it was handed, and is parked in the syscall that made it miss the
/// deadline. It almost certainly never returns to touch Io state - but "almost
/// certainly" is a race, not a proof, and the header above says so (#325).
pub var abandoned: std.atomic.Value(bool) = .init(false);

/// Exit NOW if any teardown was abandoned. For the EXIT path only: by this
/// point nothing useful is left to do, and the alternative is letting a later
/// defer tear down an Io that a live thread is still inside a syscall on.
/// Exiting is what makes the header's race unreachable instead of unlikely.
pub fn exitIfAbandoned() void {
    if (abandoned.load(.acquire)) std.process.exit(0);
}

/// One window shared by every transport in a teardown, rather than one window
/// each. Registry.deinit tears servers down sequentially, so a per-transport
/// grace made N stalled peers cost N graces: exit stayed bounded but grew with
/// the config. The whole exit path now fits inside a single deadline (#305).
pub const Budget = struct {
    started: Io.Timestamp,
    grace: Io.Duration,

    pub fn init(io: Io, grace: Io.Duration) Budget {
        return .{ .started = Io.Timestamp.now(io, .awake), .grace = grace };
    }

    /// What is left of the shared window, never negative. Zero means "do not
    /// wait at all": best-effort teardown still starts, nothing waits for it.
    pub fn remaining(self: Budget, io: Io) Io.Duration {
        const elapsed = Io.Timestamp.now(io, .awake).nanoseconds - self.started.nanoseconds;
        const left = @as(i128, self.grace.nanoseconds) - @as(i128, elapsed);
        if (left <= 0) return .fromNanoseconds(0);
        return .fromNanoseconds(@intCast(left));
    }
};

/// Run `func(args)` on a detached thread and wait at most `grace` for it.
/// Returns true when the task finished within the window. When it does not,
/// the task is abandoned rather than cancelled: cancelling through Io.Select
/// still blocks on a task stuck in an uncancelable syscall, so the only way
/// to keep the exit path prompt is to leak the task's heap state and let the
/// exiting process reclaim it.
pub fn runBounded(allocator: Allocator, io: Io, grace: Io.Duration, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) bool {
    const Task = struct {
        done: std.atomic.Value(bool) = .init(false),
        args: @TypeOf(args),
        fn run(task: *@This()) void {
            @call(.auto, func, task.args);
            task.done.store(true, .release);
        }
    };
    // Heap state, never stack: on the abandon path the detached thread
    // outlives the caller's frame, so everything it touches must stay valid.
    const task = allocator.create(Task) catch {
        @call(.auto, func, args);
        return true;
    };
    task.* = .{ .args = args };
    const thread = std.Thread.spawn(.{}, Task.run, .{task}) catch {
        allocator.destroy(task);
        @call(.auto, func, args);
        return true;
    };
    thread.detach();

    var remaining = grace;
    while (remaining.nanoseconds > 0) {
        // The thread stores `done` after its last touch of `task`, so once
        // observed it is safe to reclaim the state.
        if (task.done.load(.acquire)) {
            allocator.destroy(task);
            return true;
        }
        const nap: Io.Duration = .fromNanoseconds(@min(remaining.nanoseconds, poll_step.nanoseconds));
        io.sleep(nap, .awake) catch break;
        remaining.nanoseconds -= nap.nanoseconds;
    }
    if (task.done.load(.acquire)) {
        allocator.destroy(task);
        return true;
    }
    // Abandoned: `task` is leaked on purpose so the detached thread never
    // writes into freed memory, and the exit path is told not to tear down the
    // Io that thread is still holding (#325).
    abandoned.store(true, .release);
    return false;
}

fn clientDeinit(client: *std.http.Client) void {
    client.deinit();
}

/// Tear down an MCP HTTP client inside what is left of the shared teardown
/// window (#305). The client is heap-copied first: if teardown is abandoned,
/// the detached thread may outlive the arena that owns `client`, so it must
/// only ever touch memory that is deliberately leaked alongside it.
///
/// The wrapper state comes from the page allocator, NOT from client.allocator
/// (the session gpa): on the abandon path it is leaked on purpose, and leaking
/// it out of the gpa put harness-owned bytes into that allocator's leak report
/// at exit, where they read as a harness bug. The client's own pool memory is
/// still gpa-owned and still intentionally leaked when a peer stalls - that is
/// the trade the issue asks for, and it is the only leak left to explain.
pub fn deinitHttpClient(client: *std.http.Client, io: Io, budget: Budget) void {
    const wrapper = std.heap.page_allocator;
    const heap_client = wrapper.create(std.http.Client) catch {
        client.deinit();
        return;
    };
    heap_client.* = client.*;
    if (runBounded(wrapper, io, budget.remaining(io), clientDeinit, .{heap_client}))
        wrapper.destroy(heap_client);
}

test "runBounded completes a prompt task and reports completion" {
    var ran: std.atomic.Value(bool) = .init(false);
    const setFlag = struct {
        fn set(flag: *std.atomic.Value(bool)) void {
            flag.store(true, .release);
        }
    }.set;
    try std.testing.expect(runBounded(std.testing.allocator, std.testing.io, .fromSeconds(5), setFlag, .{&ran}));
    try std.testing.expect(ran.load(.acquire));
}

test "runBounded abandons teardown that outlives the grace window (#305)" {
    // A peer that never answers: without the bound this stalls the exit path
    // for the full minute; with it, exit proceeds after `grace`.
    var finished: std.atomic.Value(bool) = .init(false);
    const stall = struct {
        fn run(io: Io, flag: *std.atomic.Value(bool)) void {
            io.sleep(.fromSeconds(60), .awake) catch {};
            flag.store(true, .release);
        }
    }.run;
    // page_allocator: the abandoned task's state leaks by design, and a
    // leak-detecting allocator would misreport that as a test failure.
    const start = Io.Timestamp.now(std.testing.io, .awake);
    const done = runBounded(std.heap.page_allocator, std.testing.io, .fromMilliseconds(50), stall, .{ std.testing.io, &finished });
    const elapsed = Io.Timestamp.now(std.testing.io, .awake).nanoseconds - start.nanoseconds;
    try std.testing.expect(!done);
    try std.testing.expect(!finished.load(.acquire));
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}

test "runBounded flags an abandon so the exit path can skip Io teardown (#325)" {
    const io = std.testing.io;
    const saved = abandoned.load(.acquire);
    defer abandoned.store(saved, .release); // a global: never leak this test's state
    abandoned.store(false, .release);

    // A prompt task must NOT arm the escalation - the common case still runs
    // every remaining defer normally.
    const noop = struct {
        fn run() void {}
    }.run;
    try std.testing.expect(runBounded(std.testing.allocator, io, .fromSeconds(5), noop, .{}));
    try std.testing.expect(!abandoned.load(.acquire));

    // A stalled peer arms it. exitIfAbandoned is deliberately NOT called here:
    // it exits the process, so main's exit path is the only legal caller.
    const stall = struct {
        fn run(inner: Io) void {
            inner.sleep(.fromSeconds(60), .awake) catch {};
        }
    }.run;
    try std.testing.expect(!runBounded(std.heap.page_allocator, io, .fromMilliseconds(50), stall, .{io}));
    try std.testing.expect(abandoned.load(.acquire));
}

test "deinitHttpClient tears down a pooled client within the grace window" {
    // Mirrors the smolify on-demand transport: an HTTP client that was
    // connected (handshake done or not) must not hold session exit.
    var registry_client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    deinitHttpClient(&registry_client, std.testing.io, .init(std.testing.io, teardown_grace));
}

test "one Budget bounds the WHOLE teardown, not each transport (#305)" {
    const io = std.testing.io;
    const budget: Budget = .init(io, .fromMilliseconds(60));
    // Three stalled peers in a row, the shape a multi-server .mcp.json makes.
    // Per-transport graces would cost 3 x 60ms here; the shared window means
    // the third transport already finds zero left and waits for nothing.
    const stall = struct {
        fn run(inner: Io) void {
            inner.sleep(.fromSeconds(60), .awake) catch {};
        }
    }.run;
    const start = Io.Timestamp.now(io, .awake);
    var abandoned_count: usize = 0;
    for (0..3) |_| {
        if (!runBounded(std.heap.page_allocator, io, budget.remaining(io), stall, .{io})) abandoned_count += 1;
    }
    const elapsed = Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;
    try std.testing.expectEqual(@as(usize, 3), abandoned_count);
    // The sharing itself is asserted on STATE, not on the clock: the first
    // abandon spends the window, so every later transport is handed a zero
    // grace and waits for nothing. An earlier version compared elapsed against
    // 3x the grace, which is thread-spawn overhead on a slow runner - it failed
    // on the Windows CI job and deserved to.
    try std.testing.expectEqual(@as(u64, 0), budget.remaining(io).nanoseconds);
    // The clock is only asked the question it can answer reliably: we did not
    // sit through the stalls (3 x 60s) that the old inline teardown waited on.
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}
