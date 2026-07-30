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

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Hard bound on one transport's teardown. Generous next to a healthy
/// teardown (freeing a connection pool is a handful of syscalls), nothing
/// next to the minute-plus a dead peer can cost (#305).
pub const teardown_grace = Io.Duration.fromSeconds(1);

const poll_step = Io.Duration.fromMilliseconds(5);

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
    // writes into freed memory.
    return false;
}

fn clientDeinit(client: *std.http.Client) void {
    client.deinit();
}

/// Tear down an MCP HTTP client under `teardown_grace` (#305). The client is
/// heap-copied first: if teardown is abandoned, the detached thread may
/// outlive the arena that owns `client`, so it must only ever touch memory
/// that is deliberately leaked alongside it.
pub fn deinitHttpClient(client: *std.http.Client, io: Io) void {
    const heap_client = client.allocator.create(std.http.Client) catch {
        client.deinit();
        return;
    };
    heap_client.* = client.*;
    if (runBounded(client.allocator, io, teardown_grace, clientDeinit, .{heap_client}))
        client.allocator.destroy(heap_client);
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

test "deinitHttpClient tears down a pooled client within the grace window" {
    // Mirrors the smolify on-demand transport: an HTTP client that was
    // connected (handshake done or not) must not hold session exit.
    var registry_client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    deinitHttpClient(&registry_client, std.testing.io);
}
