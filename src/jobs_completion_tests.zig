//! Deterministic pump/consumer interleaving: paused immediately after done
//! becomes visible, before frontend publication. No timing-based race test.
const std = @import("std");
const jobs = @import("jobs.zig");
const notify = @import("job_notify.zig");
const cancel = @import("cancel_source.zig");
const Agent = @import("agent.zig").Agent;
var hook_failed: bool = false;

fn consumeBeforePublish(io: std.Io, id: u32) void {
    const result = jobs.jobOutput(std.testing.allocator, io, id, 0) catch {
        hook_failed = true;
        return;
    };
    defer std.testing.allocator.free(result.text);
    if (std.mem.indexOf(u8, result.text, "exited with code 7") == null or
        std.mem.indexOf(u8, result.text, "finished") == null) hook_failed = true;
    // The old pump queues only AFTER this hook. More than 16 intervening
    // consumed exits evict its bounded dismissed-id credit, resurrecting it.
    for (0..32) |i| notify.dismiss(io, id + 1000 + @as(u32, @intCast(i)));
}

test "#728 completion consumed before frontend publish cannot resurrect a wake after cache churn" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    jobs.g_jobs = .{};
    cancel.clear();
    defer cancel.clear();
    var buf: [4096]u8 = undefined;
    while (notify.takeWake(io, &buf) != null) {}
    // Reaping leaves a valid empty pool for the next foreground command.
    jobs.jobsReap(a, io);
    hook_failed = false;
    jobs.completion_test_hook = consumeBeforePublish;
    defer jobs.completion_test_hook = null;
    const job = try jobs.spawnJob(a, io, "printf finished; exit 7");
    defer jobs.jobsReap(a, io);
    job.future.await(io); // joins the hook as well as the complete pump path
    try std.testing.expect(!hook_failed);
    try std.testing.expect(notify.takeIdleWake(io, &buf) == null);
    try std.testing.expect(notify.takeWake(io, &buf) == null);
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
    try std.testing.expectEqual(cancel.Source.none, cancel.take(null));
}

test "#728 already-finished bash_kill consumes its notice without changing cancel source" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    jobs.g_jobs = .{};
    cancel.clear();
    defer cancel.clear();
    var buf: [4096]u8 = undefined;
    while (notify.takeWake(io, &buf) != null) {}
    const job = try jobs.spawnJob(a, io, "exit 0");
    defer jobs.jobsReap(a, io);
    job.future.await(io);
    cancel.cancel(.json_cancel);
    const result = try jobs.jobKill(a, io, job.id);
    defer a.free(result.text);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "already finished") != null);
    try std.testing.expect(notify.takeWake(io, &buf) == null);
    try std.testing.expect(Agent.esc_cancel.load(.acquire));
    try std.testing.expectEqual(cancel.Source.json_cancel, cancel.take(null));
}
