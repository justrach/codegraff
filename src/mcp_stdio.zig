//! MCP stdio child-process shutdown.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const shutdown_grace = std.Io.Duration.fromMilliseconds(100);

fn waitChild(child: *std.process.Child, io: Io) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

fn shutdownDeadline(io: Io) void {
    io.sleep(shutdown_grace, .awake) catch {};
}

/// Signal a normal stdio-server shutdown with EOF, but never let a server's
/// SIGTERM handler stall the CLI. A child that does not exit within the grace
/// window is force-killed and reaped so one-shot/SDK callers do not inherit
/// teardown latency or zombies.
pub fn stopChild(io: Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (child.stdin) |stdin| {
        stdin.close(io);
        child.stdin = null;
    }

    const Done = union(enum) { exited: std.process.Child.WaitError!std.process.Child.Term, deadline: void };
    var done_buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &done_buf);
    sel.concurrent(.exited, waitChild, .{ child, io }) catch {
        child.kill(io);
        return;
    };
    sel.concurrent(.deadline, shutdownDeadline, .{io}) catch {
        _ = sel.await() catch {};
        sel.cancelDiscard();
        return;
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        child.kill(io);
        return;
    };
    sel.cancelDiscard();
    if (first == .exited or child.id == null) return;

    switch (builtin.os.tag) {
        .windows => child.kill(io),
        .wasi => unreachable,
        else => {
            std.posix.kill(child.id.?, .KILL) catch {};
            _ = child.wait(io) catch child.kill(io);
        },
    }
}
